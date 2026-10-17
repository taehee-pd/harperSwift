// Added in this fork (taehee-pd/harperSwift).

import AppKit
import Foundation

/// What Settings shows, as Rust sends it (`native_ui/settings.rs`).
struct SettingsSnapshot: Decodable, Equatable {
    struct Clarity: Decodable, Equatable {
        var enabled: Bool
        var available: Bool
        /// "State: details", such as "Paused: Low Power Mode is on".
        var status: String
    }

    struct App: Decodable, Equatable, Identifiable, Hashable {
        var bundleId: String
        var name: String
        var enabled: Bool
        var id: String { bundleId }
    }

    var dialect: Dialect
    var debounceMs: Int
    var launchAtLogin: Bool
    var autoUpdate: Bool
    var version: String
    var clarity: Clarity
    var dictionary: [String]
    var apps: [App]
    var autoEnableNewApps: Bool
    var onboardingCompleted: Bool
}

enum Dialect: String, Decodable, CaseIterable, Identifiable {
    case american = "American"
    case british = "British"
    case canadian = "Canadian"
    case australian = "Australian"
    case indian = "Indian"

    var id: String { rawValue }
    var title: String { "\(rawValue) English" }
}

struct RuleGroup: Decodable, Equatable, Identifiable {
    var title: String
    var description: String
    var rules: [Rule]
    var id: String { title }
}

struct Rule: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var enabled: Bool
    var enabledByDefault: Bool

    var isChanged: Bool { enabled != enabledByDefault }
}

struct UpdateResult: Decodable {
    var status: String
    var message: String
    var latestVersion: String?
}

struct AppSearchResult: Decodable, Identifiable, Hashable {
    var name: String
    var bundleId: String
    var id: String { bundleId }
}

/// Settings state and every change, applied at once on screen and then saved by Rust. A change
/// that fails to save is rolled back and reported.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var snapshot: SettingsSnapshot?
    @Published private(set) var ruleGroups: [RuleGroup] = []
    @Published var failure: String?
    @Published private(set) var updateMessage = ""
    @Published private(set) var isCheckingForUpdates = false

    private var statusTimer: Timer?
    private var keyObserver: NSObjectProtocol?
    /// Bumped by every change. A reload that overlapped a change may have read the old value, so
    /// its result is dropped; the next reload picks the change up.
    private var editGeneration = 0
    private var editsInFlight = 0

    init() {
        Task { await reload() }
        // Pick up changes made elsewhere (the suggestion popup adds words and turns rules off).
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        // The highlighter reports the Clarity status about once a second.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reloadSnapshot() }
        }
    }

    deinit {
        statusTimer?.invalidate()
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }

    func reload() async {
        await reloadSnapshot()
        await reloadRules()
    }

    private func reloadSnapshot() async {
        let generation = quietGeneration
        do {
            let next = try await NativeBridge.request("settings.load", as: SettingsSnapshot.self)
            if generation == editGeneration {
                snapshot = next
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func reloadRules() async {
        let generation = quietGeneration
        if let groups = try? await NativeBridge.request("rules.load", as: [RuleGroup].self), generation == editGeneration {
            ruleGroups = groups
        }
    }

    /// The current generation when no change is on its way to Rust, or `nil`.
    private var quietGeneration: Int? {
        editsInFlight == 0 ? editGeneration : nil
    }

    /// Sends a change to Rust and runs `onFailure` if it cannot be saved.
    private func sendEdit(_ method: String, _ params: [String: Any], onFailure: @escaping () async -> Void) {
        editGeneration += 1
        editsInFlight += 1
        Task {
            do {
                try await NativeBridge.perform(method, params)
                editsInFlight -= 1
            } catch {
                // Settled before rolling back, so a reload in `onFailure` is not dropped.
                editsInFlight -= 1
                failure = error.localizedDescription
                await onFailure()
            }
        }
    }

    /// Shows `edit` at once, sends `method`, and rolls back if Rust cannot save it.
    private func change(
        _ method: String,
        _ params: [String: Any] = [:],
        edit: (inout SettingsSnapshot) -> Void
    ) {
        guard var next = snapshot else { return }
        let previous = next
        edit(&next)
        snapshot = next
        sendEdit(method, params) { [weak self] in self?.snapshot = previous }
    }

    // MARK: General

    func setDialect(_ dialect: Dialect) {
        change("settings.setDialect", ["dialect": dialect.rawValue]) { $0.dialect = dialect }
    }

    func setDebounceMs(_ value: Int) {
        let value = max(0, value)
        change("settings.setDebounceMs", ["value": value]) { $0.debounceMs = value }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        change("settings.setLaunchAtLogin", ["enabled": enabled]) { $0.launchAtLogin = enabled }
    }

    func setAutoUpdate(_ enabled: Bool) {
        change("settings.setAutoUpdate", ["enabled": enabled]) { $0.autoUpdate = enabled }
    }

    func setClarityEnabled(_ enabled: Bool) {
        change("clarity.setEnabled", ["enabled": enabled]) { $0.clarity.enabled = enabled }
    }

    func checkForUpdates() {
        isCheckingForUpdates = true
        updateMessage = ""
        Task {
            defer { isCheckingForUpdates = false }
            do {
                let result = try await NativeBridge.request("updates.check", as: UpdateResult.self)
                updateMessage = result.message
            } catch {
                failure = "Unable to check for updates: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Dictionary

    func addWord(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, snapshot?.dictionary.contains(word) == false else { return }
        change("dictionary.add", ["word": word]) {
            $0.dictionary.append(word)
            $0.dictionary.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    func setWords(_ words: [String]) {
        let words = Array(Set(words)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        change("dictionary.set", ["words": words]) { $0.dictionary = words }
    }

    func removeWords(_ words: Set<String>) {
        guard let dictionary = snapshot?.dictionary else { return }
        setWords(dictionary.filter { !words.contains($0) })
    }

    // MARK: Apps

    func setAppEnabled(_ app: SettingsSnapshot.App, _ enabled: Bool) {
        change("apps.setEnabled", ["bundleId": app.bundleId, "enabled": enabled]) { snapshot in
            if let index = snapshot.apps.firstIndex(of: app) {
                snapshot.apps[index].enabled = enabled
            }
        }
    }

    func addApp(bundleId: String, name: String) {
        guard snapshot?.apps.contains(where: { $0.bundleId == bundleId }) == false else { return }
        change("apps.add", ["bundleId": bundleId]) {
            $0.apps.append(.init(bundleId: bundleId, name: name, enabled: true))
        }
    }

    func removeApps(_ bundleIds: Set<String>) {
        for bundleId in bundleIds {
            change("apps.remove", ["bundleId": bundleId]) { snapshot in
                snapshot.apps.removeAll { $0.bundleId == bundleId }
            }
        }
    }

    func setAutoEnableNewApps(_ enabled: Bool) {
        change("apps.setAutoEnable", ["enabled": enabled]) { $0.autoEnableNewApps = enabled }
    }

    // MARK: Rules

    var enabledRuleCount: Int { ruleGroups.reduce(0) { $0 + $1.rules.filter(\.enabled).count } }
    var ruleCount: Int { ruleGroups.reduce(0) { $0 + $1.rules.count } }
    var changedRuleCount: Int { ruleGroups.reduce(0) { $0 + $1.rules.filter(\.isChanged).count } }

    func setRules(_ ids: Set<String>, enabled: Bool) {
        editRules(ids) { $0.enabled = enabled }
        send("rules.setEnabled", ["ids": Array(ids), "enabled": enabled])
    }

    func restoreDefaults(_ ids: Set<String>? = nil) {
        editRules(ids) { $0.enabled = $0.enabledByDefault }
        send("rules.restoreDefaults", ids.map { ["ids": Array($0)] } ?? [:])
    }

    func turnAllRulesOff() {
        editRules(nil) { $0.enabled = false }
        send("rules.turnAllOff")
    }

    private func editRules(_ ids: Set<String>?, _ edit: (inout Rule) -> Void) {
        for group in ruleGroups.indices {
            for rule in ruleGroups[group].rules.indices where ids?.contains(ruleGroups[group].rules[rule].id) ?? true {
                edit(&ruleGroups[group].rules[rule])
            }
        }
    }

    private func send(_ method: String, _ params: [String: Any] = [:]) {
        sendEdit(method, params) { [weak self] in await self?.reloadRules() }
    }
}
