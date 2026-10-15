// Added in this fork (taehee-pd/harperSwift).
//
// Checks sentences for Clarity with Apple's on-device model (Foundation Models, macOS 27 APIs).
// Only `SystemLanguageModel.default` is used, so text never leaves the Mac. Rust decides what to
// check and when (`src-tauri/src/clarity/`); this type runs one request at a time and reports back.

import Foundation
import FoundationModels
import IOKit.ps
import os

/// Whether checks can run, as a code shared with `clarity/apple.rs`.
enum ClarityAvailability: Int32 {
    case available = 0
    case lowPowerMode = 1
    case lowBattery = 2
    case deviceNotEligible = 3
    case appleIntelligenceNotEnabled = 4
    case modelNotReady = 5
    case unsupportedOperatingSystem = 6
}

/// One issue, as sent to Rust in JSON.
struct ClarityIssueWire: Codable, Equatable {
    let original: String
    let replacement: String
    let reason: String
}

@available(macOS 27, *)
@Generable
struct ClarityResult {
    // Generated first: quoting the problem before writing fixes keeps the model from suggesting
    // an edit for every sentence. On a 15-sentence sample this cut false alarms on clear
    // sentences from 5 of 5 to 0 of 5, while catching 6 of 10 wordy ones.
    @Guide(description: "The wordy or awkward phrase in the sentence, quoted exactly, or an empty string when there is none.")
    var problem: String

    @Guide(description: "Fixes for the problem. Empty when problem is empty.", .maximumCount(2))
    var issues: [ClarityIssue]
}

@available(macOS 27, *)
@Generable
struct ClarityIssue {
    @Guide(description: "The exact words to change, copied character for character from the sentence.")
    var original: String

    @Guide(description: "The words that replace original. Change as little as possible.")
    var replacement: String

    @Guide(description: "Why the change reads better, in fewer than 15 words.")
    var reason: String
}

enum ClarityPrompt {
    static let instructions = """
        You review one English sentence at a time for clarity.
        Flag only wordy, unclear, or awkward phrasing: filler phrases, needless repetition, \
        roundabout constructions.
        Leave clear sentences alone. Do not change capitalization, times, word choice that is \
        already clear, spelling, grammar, or punctuation; another tool handles those.
        For each problem, copy the exact words to change into "original" and give the smallest \
        rewrite as "replacement". The sentence must stay grammatical after the change.
        Never change the meaning, facts, names, numbers, or tone.

        Examples:
        "She sent the report to the client before noon." -> no issues.
        "The app crashes when you open a large file." -> no issues.
        "We met in order to plan the trip." -> original "in order to", replacement "to".
        "There are many people who think so." -> original "There are many people who think", \
        replacement "Many people think".
        """

    static func prompt(for sentence: String) -> String {
        "Sentence: \(sentence)"
    }
}

/// Reports Low Power Mode and low battery, which pause checks to save power.
enum PowerState {
    /// Checks pause on battery below this charge.
    static let lowBatteryLevel = 0.2

    static func pauseReason() -> ClarityAvailability? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .lowPowerMode
        }
        if let level = batteryLevelWhenUnplugged(), level < lowBatteryLevel {
            return .lowBattery
        }
        return nil
    }

    /// Internal battery charge from 0 to 1 while running on battery; nil when plugged in or
    /// without a battery.
    static func batteryLevelWhenUnplugged() -> Double? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }

            return Double(current) / Double(maximum)
        }
        return nil
    }
}

/// Runs Clarity requests. Rust sends at most one at a time; each gets a fresh session so no
/// context carries over between sentences.
@MainActor
final class ClarityChecker {
    static let shared = ClarityChecker()

    /// Set once by Rust at startup.
    static var resultHandler: HarperClarityResultHandler?

    /// Room left for the answer when checking that a request fits the context window.
    nonisolated static let maximumResponseTokens = 300

    private nonisolated static let logger = Logger(subsystem: "com.elijahpotter.harper-desktop", category: "Clarity")

    private var tasks: [UInt64: Task<Void, Never>] = [:]
    /// A fresh, prewarmed session for the next request. Typed as `AnyObject` because stored
    /// properties cannot carry availability.
    private var nextSession: AnyObject?

    func availability() -> ClarityAvailability {
        guard #available(macOS 27, *) else { return .unsupportedOperatingSystem }

        switch SystemLanguageModel.default.availability {
        case .available:
            return PowerState.pauseReason() ?? .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable:
            return .modelNotReady
        }
    }

    /// Loads the model before the first request, using the session the next request will take.
    func prewarm() {
        guard #available(macOS 27, *), availability() == .available, nextSession == nil else { return }

        let session = Self.makeSession()
        session.prewarm(promptPrefix: nil)
        nextSession = session
    }

    func submit(id: UInt64, sentence: String) {
        // Checked before every request: Apple Intelligence or power state may have changed.
        guard #available(macOS 27, *), availability() == .available else {
            deliver(id: id, issues: [])
            return
        }

        let session = (nextSession as? LanguageModelSession) ?? Self.makeSession()
        nextSession = nil

        tasks[id] = Task {
            let issues = await Self.check(sentence, in: session)
            guard !Task.isCancelled else { return }

            self.tasks[id] = nil
            self.deliver(id: id, issues: issues)
        }
    }

    func cancel(id: UInt64) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    @available(macOS 27, *)
    nonisolated static func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default, instructions: ClarityPrompt.instructions)
    }

    /// Asks the model about one sentence. Every failure (context window, guardrails, cancellation,
    /// anything else) counts as "no issues", so the sentence is not retried in a loop.
    @available(macOS 27, *)
    nonisolated static func check(_ sentence: String, in session: LanguageModelSession) async -> [ClarityIssueWire] {
        let prompt = ClarityPrompt.prompt(for: sentence)

        do {
            guard try await fitsContextWindow(prompt) else {
                logger.debug("Clarity skipped a sentence too long for the context window")
                return []
            }

            let response = try await session.respond(
                to: prompt,
                generating: ClarityResult.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
            )
            let result = response.content
            guard !result.problem.isEmpty else { return [] }

            return result.issues.map {
                ClarityIssueWire(original: $0.original, replacement: $0.replacement, reason: $0.reason)
            }
        } catch is CancellationError {
            return []
        } catch {
            logger.debug("Clarity check failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Whether instructions, schema, sentence and answer fit the model's context window, which
    /// input and output share.
    @available(macOS 27, *)
    private nonisolated static func fitsContextWindow(_ prompt: String) async throws -> Bool {
        let model = SystemLanguageModel.default
        let used = try await model.tokenCount(for: Instructions(ClarityPrompt.instructions))
            + model.tokenCount(for: ClarityResult.generationSchema)
            + model.tokenCount(for: Prompt(prompt))
        return used + maximumResponseTokens <= model.contextSize
    }

    private func deliver(id: UInt64, issues: [ClarityIssueWire]) {
        guard let handler = Self.resultHandler,
              let json = try? JSONEncoder().encode(issues),
              let string = String(data: json, encoding: .utf8)
        else { return }

        string.withCString { handler(id, $0) }
    }
}
