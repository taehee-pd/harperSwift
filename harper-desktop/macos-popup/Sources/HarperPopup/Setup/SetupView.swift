// Added in this fork (taehee-pd/harperSwift).

import AppKit
import ApplicationServices
import SwiftUI

/// The first-run setup: welcome, Accessibility access, turning Harper on in TextEdit, a try-out,
/// and done. Accessibility is detected on its own while the step waits.
@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome
        case accessibility
        case textEdit
        case tryIt
        case done
    }

    static let textEdit = "com.apple.TextEdit"

    @Published var step = Step.welcome
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var askedForAccess = false
    @Published private(set) var isTextEditOn = false
    @Published private(set) var isWorking = false
    @Published var failure: String?

    private var pollTimer: Timer?

    init() {
        Task { await loadTextEdit() }
        if isTrusted {
            Task { await startChecking() }
        }
        // Watch for the grant while the user is in System Settings.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    var canContinue: Bool {
        switch step {
        case .welcome, .tryIt, .done: true
        case .accessibility: isTrusted
        case .textEdit: isTextEditOn
        }
    }

    func next() {
        guard canContinue, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted {
            Task { await startChecking() }
        }
    }

    func requestAccess() {
        let alreadyAsked = askedForAccess
        askedForAccess = true
        if AccessibilityAccess.request(alreadyAsked: alreadyAsked), !isTrusted {
            isTrusted = true
            Task { await startChecking() }
        }
    }

    private func startChecking() async {
        do {
            try await NativeBridge.perform("service.start")
        } catch {
            failure = "Harper couldn\u{2019}t start checking: \(error.localizedDescription)"
        }
    }

    private func loadTextEdit() async {
        guard let snapshot = try? await NativeBridge.request("settings.load", as: SettingsSnapshot.self) else { return }
        isTextEditOn = snapshot.apps.contains { $0.bundleId == Self.textEdit && $0.enabled }
    }

    func turnOnTextEdit() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await NativeBridge.perform("apps.add", ["bundleId": Self.textEdit])
                try await NativeBridge.perform("apps.setEnabled", ["bundleId": Self.textEdit, "enabled": true])
                isTextEditOn = true
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    func openTextEdit() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.textEdit) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func finish() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await NativeBridge.perform("onboarding.complete")
                // Open Settings first, so Harper keeps a window and its Dock icon throughout.
                AppWindows.showSettings()
                AppWindows.close(.setup)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct SetupView: View {
    @StateObject private var model: SetupModel

    init(model: SetupModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    stepIcon
                        .padding(.top, 44)
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                        .padding(.top, 8)
                    action
                        .padding(.top, 22)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }

            Divider()
            HStack {
                StepDots(count: SetupModel.Step.allCases.count, current: model.step.rawValue)
                Spacer()
                if model.step != .welcome {
                    Button("Back", action: model.back)
                        .keyboardShortcut(.cancelAction)
                }
                if model.step == .done {
                    Button("Start Writing", action: model.finish)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWorking)
                } else {
                    Button("Continue", action: model.next)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canContinue)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 470)
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch model.step {
        case .welcome, .done:
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
        case .accessibility:
            SymbolTile(symbol: "accessibility", color: .blue, size: 64)
        case .textEdit, .tryIt:
            AppIcon(bundleId: SetupModel.textEdit, size: 72)
        }
    }

    private var title: String {
        switch model.step {
        case .welcome: "Welcome to Harper"
        case .accessibility: "Allow Accessibility Access"
        case .textEdit: "Turn On Harper in TextEdit"
        case .tryIt: "Try It"
        case .done: "You\u{2019}re All Set"
        }
    }

    private var message: String {
        switch model.step {
        case .welcome:
            "Harper checks your spelling and grammar in the apps you already write in. Setup takes about a minute."
        case .accessibility:
            "Harper reads what you type so it can underline mistakes, and writes your fixes back. macOS asks you to allow this in Privacy & Security. Your writing never leaves this Mac."
        case .textEdit:
            "Harper checks only the apps you turn on. Start with TextEdit; you can add more apps later in Settings."
        case .tryIt:
            "Open TextEdit and type \u{201c}This is an test.\u{201d} Harper underlines the mistake. Click the underline, or move the cursor into the word, to see the fix. Press \u{2303}\u{2318}Y to accept it."
        case .done:
            "Harper runs in the menu bar and checks your writing in the apps you turn on. You can change apps, rules, and your dictionary anytime in Settings."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch model.step {
        case .accessibility:
            if model.isTrusted {
                DoneLabel(text: "Harper can read and fix text in the apps you turn on.")
            } else {
                VStack(spacing: 12) {
                    Button(model.askedForAccess ? "Open System Settings Again" : "Open System Settings", action: model.requestAccess)
                        .controlSize(.large)
                    if model.askedForAccess {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Turn on Harper in Privacy & Security \u{203a} Accessibility. This page updates on its own.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .textEdit:
            if model.isTextEditOn {
                DoneLabel(text: "Harper will check your writing in TextEdit.")
            } else {
                Button("Turn On TextEdit", action: model.turnOnTextEdit)
                    .controlSize(.large)
                    .disabled(model.isWorking)
            }
        case .tryIt:
            Button("Open TextEdit", action: model.openTextEdit)
                .controlSize(.large)
        case .welcome, .done:
            EmptyView()
        }
    }
}

private struct DoneLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.callout)
    }
}

/// Where the user is in the setup, as small dots.
private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
