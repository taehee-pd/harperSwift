// Added in this fork (taehee-pd/harperSwift).

import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case dictionary
    case rules
    case apps
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .dictionary: "Dictionary"
        case .rules: "Rules"
        case .apps: "Apps"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .dictionary: "character.book.closed.fill"
        case .rules: "checklist"
        case .apps: "square.grid.2x2.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .dictionary: .pink
        case .rules: .green
        case .apps: .blue
        case .about: .gray
        }
    }
}

/// The Settings window: a sidebar of panes and grouped forms, like System Settings.
struct SettingsView: View {
    @StateObject private var model: SettingsModel
    @State private var pane: SettingsPane?

    init(model: SettingsModel, pane: SettingsPane = .general) {
        _model = StateObject(wrappedValue: model)
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    ForEach([SettingsPane.general, .dictionary, .rules, .apps]) { row($0) }
                }
                Section {
                    row(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if #unavailable(macOS 14) {
                    // macOS 13 cannot put the title in the toolbar; show it above the content.
                    ToolbarTitle(title: (pane ?? .general).title)
                }
                Group {
                    if let snapshot = model.snapshot {
                        content(snapshot)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle((pane ?? .general).title)
            .background(WindowTitle(title: (pane ?? .general).title))
        }
        .removingSidebarToggle()
        .frame(minWidth: 680, minHeight: 460)
        .alert(
            "Harper couldn\u{2019}t make that change",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure)
        }
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            SymbolTile(symbol: pane.symbol, color: pane.tint)
        }
        .tag(pane)
    }

    @ViewBuilder
    private func content(_ snapshot: SettingsSnapshot) -> some View {
        switch pane ?? .general {
        case .general: GeneralPane(model: model, snapshot: snapshot)
        case .dictionary: DictionaryPane(model: model, words: snapshot.dictionary)
        case .rules: RulesPane(model: model)
        case .apps: AppsPane(model: model, snapshot: snapshot)
        case .about: AboutPane(version: snapshot.version)
        }
    }
}

private extension View {
    /// System Settings has no sidebar toggle.
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 14, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    let snapshot: SettingsSnapshot

    var body: some View {
        Form {
            Section("Writing") {
                Picker(selection: Binding(get: { snapshot.dialect }, set: model.setDialect)) {
                    ForEach(Dialect.allCases) { Text($0.title).tag($0) }
                } label: {
                    RowLabel(title: "English dialect", detail: "Harper checks spelling and grammar for this variety of English.")
                }

                LabeledContent {
                    HStack(spacing: 6) {
                        TextField(
                            "Delay",
                            value: Binding(get: { snapshot.debounceMs }, set: model.setDebounceMs),
                            format: .number
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        Stepper(
                            "Delay",
                            value: Binding(get: { snapshot.debounceMs }, set: model.setDebounceMs),
                            in: 0...5000,
                            step: 50
                        )
                        .labelsHidden()
                        Text("ms").foregroundStyle(.secondary)
                    }
                } label: {
                    RowLabel(title: "Wait after typing", detail: "How long Harper waits after you stop typing. Use 0 to check right away.")
                }
            }

            Section("Apple Intelligence") {
                Toggle(isOn: Binding(
                    get: { snapshot.clarity.enabled && snapshot.clarity.available },
                    set: model.setClarityEnabled
                )) {
                    RowLabel(
                        title: "Clarity suggestions",
                        detail: "Suggests clearer, shorter wording for sentences that have no spelling or grammar issues. Suggestions are made on this Mac; your text never leaves it."
                    )
                }
                .disabled(!snapshot.clarity.available)

                LabeledContent("Status") {
                    ClarityStatusLabel(clarity: snapshot.clarity)
                }
            }

            Section("Startup and Updates") {
                Toggle(isOn: Binding(get: { snapshot.launchAtLogin }, set: model.setLaunchAtLogin)) {
                    RowLabel(title: "Open at login", detail: "Harper starts quietly in the menu bar when you log in.")
                }
                Toggle(isOn: Binding(get: { snapshot.autoUpdate }, set: model.setAutoUpdate)) {
                    RowLabel(title: "Check for updates automatically", detail: "Harper looks for a new version once a day.")
                }
                LabeledContent {
                    Button(model.isCheckingForUpdates ? "Checking\u{2026}" : "Check Now", action: model.checkForUpdates)
                        .disabled(model.isCheckingForUpdates)
                } label: {
                    RowLabel(
                        title: "Version \(snapshot.version)",
                        detail: model.updateMessage.isEmpty ? nil : model.updateMessage
                    )
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

/// "Ready: suggestions run on this Mac" as a colored dot and the details.
struct ClarityStatusLabel: View {
    let clarity: SettingsSnapshot.Clarity

    private var state: Substring {
        clarity.status.split(separator: ":", maxSplits: 1).first ?? ""
    }

    private var detail: String {
        let parts = clarity.status.split(separator: ":", maxSplits: 1)
        let text = parts.count == 2 ? String(parts[1]) : clarity.status
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private var color: Color {
        guard clarity.enabled else { return .secondary }
        switch state {
        case "Ready": return .green
        case "Paused": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - About

struct AboutPane: View {
    let version: String

    private static let fork = URL(string: "https://github.com/taehee-pd/harperSwift")!
    private static let upstream = URL(string: "https://github.com/Automattic/harper")!
    private static let issues = URL(string: "https://github.com/Automattic/harper/issues/new/choose")!

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text("Harper")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 8)
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Text("An open-source grammar checker that runs entirely on your Mac. No account, no tracking, no cloud.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .padding(.top, 14)
            HStack(spacing: 10) {
                Button("Release Notes") { open(Self.fork.appendingPathComponent("releases/tag/v\(version)")) }
                Button("Source Code") { open(Self.fork) }
                Button("Report an Issue") { open(Self.issues) }
            }
            .padding(.top, 20)
            Spacer(minLength: 24)
            Text("Based on [Harper](\(Self.upstream.absoluteString)), free software released under the Apache 2.0 license.\nCopyright 2026 The Harper Contributors.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
