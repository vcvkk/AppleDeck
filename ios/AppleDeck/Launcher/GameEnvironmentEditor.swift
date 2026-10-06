// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppleDeckCore

/// The game environment editor, for one scope.
///
/// Two scopes exist and they behave differently: the shared one, which every
/// game is launched with, and a Steam app id, which is that game only. The
/// screen says which one it is editing at the top, because the mistake - setting
/// something globally that was meant for one game - is invisible until you launch
/// a different one and find it still applied.
struct GameEnvironmentEditor: View {
    @EnvironmentObject private var launcher: LauncherModel
    @Environment(\.dismiss) private var dismiss

    /// Empty is the shared scope; otherwise a Steam app id.
    let scope: String
    let gameName: String?

    @State private var entries: [String: String?] = [:]
    @State private var preset = ""
    @State private var filter = ""
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Scope") {
                    Text(scope.isEmpty ? "Every game" : "Game \(scope)")
                }
                if let gameName, !scope.isEmpty {
                    Text(gameName).font(.caption).foregroundStyle(.secondary)
                }
                Picker("FEX preset", selection: $preset) {
                    ForEach(FexPreset.all) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                }
                Text(presetDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Translation")
            }

            Section {
                ForEach(visibleOptions) { option in
                    row(for: option)
                }
            } header: {
                Text("Options")
            } footer: {
                Text("A game is launched with the preset's values, then the shared ones, then its own.")
            }

            Section {
                ForEach(customNames, id: \.self) { name in
                    CustomEntryRow(name: name,
                                   value: binding(for: name),
                                   onRemove: { entries.removeValue(forKey: name) })
                }
                AddEntryField { name, value in
                    guard GameEnvironment.isValidName(name) else {
                        problem = "'\(name)' is not a variable name the guest would read"
                        return false
                    }
                    guard GameEnvironment.isSupported(name) else {
                        problem = "\(name) belongs to the runtime's own shims"
                        return false
                    }
                    guard GameEnvironment.isValidValue(value) else {
                        problem = "that value is empty of meaning: too long, or it has a NUL"
                        return false
                    }
                    entries[name] = value
                    return true
                }
            } header: {
                Text("Your own variables")
            } footer: {
                Text("Names the runtime's shims set are refused rather than ignored - changing one stops the guest's own infrastructure working.")
            }

            if let problem {
                Section {
                    Text(problem).foregroundStyle(.red).font(.caption)
                }
            }

            Section {
                Button(role: .destructive) {
                    entries = [:]
                    try? launcher.environmentStore.write(config)
                } label: {
                    Text("Reset this scope to the preset")
                }
                .disabled(entries.isEmpty)
            }
        }
        .navigationTitle(scope.isEmpty ? "Environment" : "Environment")
        .searchable(text: $filter, prompt: "Options")
        .onAppear(perform: load)
        .onChange(of: entries) { _, _ in save() }
        .onChange(of: preset) { _, _ in save() }
    }

    private var presetDetail: String {
        FexPreset.byId(preset).detail
    }

    private var config: GameEnvironment.Config {
        launcher.environment.withEntries(scope: scope, entries: entries)
    }

    private var visibleOptions: [GameEnvironmentOptions.Option] {
        GameEnvironmentOptions.all.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Names the user set that the table does not know, so nothing is hidden.
    private var customNames: [String] {
        entries.keys.filter { GameEnvironmentOptions.find($0) == nil }.sorted()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        entries = launcher.environment.entries(scope: scope)
        preset = launcher.prefs.string("fexPreset", "")
    }

    private func save() {
        do {
            try launcher.environmentStore.write(config)
            problem = nil
        } catch {
            problem = (error as? GameEnvironmentStore.StoreError)?.message
                ?? error.localizedDescription
        }
    }

    /// What the editor shows: the value in effect, which is the set value, then
    /// the preset's, then the option's own default.
    private func currentValue(_ option: GameEnvironmentOptions.Option) -> String {
        GameEnvironmentOptions.effectiveValue(
            for: option,
            in: entries,
            fallbacks: GameEnvironment.defaults(preset: preset))
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { currentValue(GameEnvironmentOptions.Option(
                name: name, defaultValue: "", title: name, kind: .text)) },
            set: { entries[name] = $0 })
    }

    @ViewBuilder
    private func row(for option: GameEnvironmentOptions.Option) -> some View {
        let value = currentValue(option)
        switch option.kind {
        case .toggle:
            Toggle(option.title, isOn: toggleBinding(option, value: value))
        case .choice:
            Picker(option.title, selection: Binding(
                get: { value },
                set: { entries[option.name] = $0 }))
            {
                ForEach(option.choices, id: \.self) { Text($0).tag($0) }
            }
        case .multiple:
            MultipleChoiceRow(option: option,
                              value: value,
                              onChange: { entries[option.name] = $0 })
        case .number, .text:
            TextField(option.title, text: Binding(
                get: { value },
                set: { entries[option.name] = $0 }))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private func toggleBinding(_ option: GameEnvironmentOptions.Option, value: String) -> Binding<Bool> {
        Binding(
            get: { value == "true" || value == "1" },
            set: { entries[option.name] = $0 ? (option.choices.last ?? "1") : (option.choices.first ?? "0") })
    }
}

/// A MULTIPLE option: any number of its choices, held in the option's own order
/// so the value does not depend on the order they were tapped.
struct MultipleChoiceRow: View {
    let option: GameEnvironmentOptions.Option
    let value: String
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(option.title).font(.subheadline)
            FlowRow(spacing: 6) {
                ForEach(option.choices, id: \.self) { choice in
                    Button {
                        onChange(GameEnvironmentOptions.toggle(value: value, choice: choice, in: option))
                    } label: {
                        Text(choice)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isOn(choice) ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isOn(_ choice: String) -> Bool {
        value.split(separator: ",").contains(Substring(choice))
    }
}

/// A horizontal wrap, because a MULTIPLE option can have twenty choices and a
/// VStack of twenty rows is a screen nobody scrolls past.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A variable the table does not know, so it is editable and removable.
struct CustomEntryRow: View {
    let name: String
    @Binding var value: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text(name).font(.caption.monospaced())
            TextField("value", text: $value)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
    }
}

/// Adds a name and a value, and refuses the names the rules refuse.
struct AddEntryField: View {
    let onAdd: (String, String) -> Bool

    @State private var name = ""
    @State private var value = ""

    var body: some View {
        HStack {
            TextField("NAME", text: $name)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("value", text: $value)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)
            Button("Add", action: submit)
                .disabled(name.isEmpty)
        }
        .font(.caption.monospaced())
    }

    private func submit() {
        if onAdd(name.trimmingCharacters(in: .whitespaces), value) {
            name = ""
            value = ""
        }
    }
}