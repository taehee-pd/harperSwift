// Added in this fork (taehee-pd/harperSwift).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dictionary

struct DictionaryPane: View {
    @ObservedObject var model: SettingsModel
    let words: [String]

    @State private var newWord = ""
    @State private var query = ""
    @State private var isConfirmingRemoveAll = false

    private var trimmedWord: String { newWord.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { words.contains(trimmedWord) }
    private var matches: [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? words : words.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("New word", text: $newWord)
                        .labelsHidden()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(trimmedWord.isEmpty || isDuplicate)
                }
                if isDuplicate {
                    Text("\u{201c}\(trimmedWord)\u{201d} is already in your dictionary.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Harper never flags the words in your dictionary. Add names, places, and terms you use often, or choose Add to Dictionary in a suggestion.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if words.isEmpty {
                    Text("No words yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    SearchField(text: $query, prompt: "Search \(words.count) words")
                    if matches.isEmpty {
                        Text("No words match \u{201c}\(query)\u{201d}.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(matches, id: \.self) { word in
                        HStack {
                            Text(word)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                model.removeWords([word])
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove \u{201c}\(word)\u{201d}")
                            .accessibilityLabel("Remove \(word)")
                        }
                        .contextMenu {
                            Button("Remove \u{201c}\(word)\u{201d}") { model.removeWords([word]) }
                        }
                    }
                }
            } header: {
                Text(words.count == 1 ? "1 Word" : "\(words.count) Words")
            }

            Section {
                HStack {
                    Button("Import\u{2026}", action: importWords)
                    Button("Export\u{2026}", action: exportWords)
                        .disabled(words.isEmpty)
                    Spacer()
                    Button("Remove All\u{2026}", role: .destructive) { isConfirmingRemoveAll = true }
                        .disabled(words.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove all \(words.count) words from your dictionary?",
            isPresented: $isConfirmingRemoveAll
        ) {
            Button("Remove All", role: .destructive) { model.setWords([]) }
        } message: {
            Text("Harper will flag these words again. You can\u{2019}t undo this, so export the list first if you might want it back.")
        }
    }

    private func add() {
        guard !trimmedWord.isEmpty, !isDuplicate else { return }
        model.addWord(trimmedWord)
        newWord = ""
    }

    private func importWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a text file with one word per line."
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let imported = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        model.setWords(words + imported)
    }

    private func exportWords() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Harper Dictionary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (words.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.failure = "Unable to export the dictionary: \(error.localizedDescription)"
        }
    }
}

// MARK: - Rules

struct RulesPane: View {
    @ObservedObject var model: SettingsModel

    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var confirmation: Confirmation?

    private enum Confirmation: Identifiable {
        case restoreDefaults
        case turnAllOff
        var id: Self { self }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Groups with the rules that match the search. A group whose title or description matches
    /// shows all its rules.
    private var visibleGroups: [RuleGroup] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.ruleGroups }

        return model.ruleGroups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(query)
                || group.description.localizedCaseInsensitiveContains(query) {
                return group
            }
            var group = group
            group.rules = group.rules.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query)
            }
            return group.rules.isEmpty ? nil : group
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    SearchField(text: $query, prompt: "Search rules")
                    Button("Restore Defaults\u{2026}") { confirmation = .restoreDefaults }
                        .disabled(model.changedRuleCount == 0)
                    Button("Turn All Off\u{2026}") { confirmation = .turnAllOff }
                        .disabled(model.enabledRuleCount == 0)
                }
            } footer: {
                Text(summary).foregroundStyle(.secondary)
            }

            if model.ruleGroups.isEmpty {
                Section {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }

            ForEach(visibleGroups) { group in
                Section {
                    DisclosureGroup(isExpanded: expansion(of: group)) {
                        ForEach(group.rules) { rule in
                            RuleRow(rule: rule) { model.setRules([rule.id], enabled: $0) }
                        }
                    } label: {
                        GroupHeader(group: group, model: model)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .confirmationDialog(
            confirmation == .turnAllOff ? "Turn off every rule?" : "Restore the default rules?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { confirmation in
            switch confirmation {
            case .restoreDefaults:
                Button("Restore Defaults") { model.restoreDefaults() }
            case .turnAllOff:
                Button("Turn All Off", role: .destructive) { model.turnAllRulesOff() }
            }
        } message: { confirmation in
            switch confirmation {
            case .restoreDefaults:
                Text("Your \(model.changedRuleCount) changes will be undone.")
            case .turnAllOff:
                Text("Harper will stop flagging anything until you turn rules back on.")
            }
        }
    }

    private var summary: String {
        guard model.ruleCount > 0 else { return "Choose what Harper checks." }
        let changed = model.changedRuleCount
        return "\(model.enabledRuleCount) of \(model.ruleCount) rules are on"
            + (changed > 0 ? ", \(changed) changed from the defaults." : ".")
    }

    private func expansion(of group: RuleGroup) -> Binding<Bool> {
        Binding(
            get: { searching || expanded.contains(group.id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(group.id) } else { expanded.remove(group.id) }
            }
        )
    }
}

private struct GroupHeader: View {
    let group: RuleGroup
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.title).fontWeight(.semibold)
                    Text("\(group.rules.filter(\.enabled).count) of \(group.rules.count) on")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(group.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Menu {
                let ids = Set(group.rules.map(\.id))
                Button("Turn All On") { model.setRules(ids, enabled: true) }
                Button("Turn All Off") { model.setRules(ids, enabled: false) }
                Divider()
                Button("Restore Defaults") { model.restoreDefaults(ids) }
                    .disabled(!group.rules.contains(where: \.isChanged))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change every rule in \(group.title)")
            .accessibilityLabel("Change every rule in \(group.title)")
        }
    }
}

private struct RuleRow: View {
    let rule: Rule
    let setEnabled: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { rule.enabled }, set: setEnabled)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name)
                    if rule.isChanged {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .help("Changed from the default")
                            .accessibilityLabel("Changed from the default")
                    }
                }
                if !rule.description.isEmpty {
                    Text(rule.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(rule.description)
                }
            }
        }
    }
}

// MARK: - Apps

struct AppsPane: View {
    @ObservedObject var model: SettingsModel
    let snapshot: SettingsSnapshot

    var body: some View {
        Form {
            Section {
                if snapshot.apps.isEmpty {
                    Text("No apps yet. Add an app to have Harper check your writing in it.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(snapshot.apps) { app in
                    HStack(spacing: 10) {
                        AppIcon(bundleId: app.bundleId, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.bundleId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            model.removeApps([app.bundleId])
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove \(app.name) from the list")
                        .accessibilityLabel("Remove \(app.name)")
                        Toggle(app.name, isOn: Binding(get: { app.enabled }, set: { model.setAppEnabled(app, $0) }))
                            .labelsHidden()
                    }
                    .contextMenu {
                        Button("Remove \(app.name)") { model.removeApps([app.bundleId]) }
                    }
                }
                HStack {
                    Button("Add App\u{2026}", action: addApps)
                    Spacer()
                }
            } header: {
                Text("Harper checks your writing only in the apps turned on here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            Section("New Apps") {
                Toggle(isOn: Binding(get: { snapshot.autoEnableNewApps }, set: model.setAutoEnableNewApps)) {
                    RowLabel(
                        title: "Turn on new apps automatically",
                        detail: "When you write in a new app, Harper adds it here and turns it on. Apps you turned off stay off."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    /// Chooses apps the way System Settings does for its app lists: an Open panel on Applications.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the apps Harper should check."
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let bundleId = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            model.addApp(bundleId: bundleId, name: name)
        }
    }
}
