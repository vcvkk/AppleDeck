// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppleDeckCore

/// The launcher's pages, one view each, in the order the tab bar shows them.
///
/// Each page is the iOS face of a DroidDeck screen with the same name, and the
/// comments say which one, because the interesting part of this port is not the
/// SwiftUI - it is which DroidDeck behaviour each screen had to reproduce.

/// Home: what to play, plus the two buttons a session is started from.
struct FrontEndView: View {
    @ObservedObject var launcher: LauncherModel

    private var recent: [GameEntry] { Array(launcher.games.prefix(8)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let status = launcher.libraryError {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if !recent.isEmpty {
                    section("Recently added") {
                        HStack(spacing: 12) {
                            ForEach(recent) { game in
                                Button { launcher.startGame(game) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(game.name)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(width: 132, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .padding(8)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                section("Start") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            launcher.beginSession(.steam(ui: .bigPicture, url: nil))
                        } label: {
                            Label("Steam Big Picture", systemImage: "play.circle")
                        }
                        .disabled(!launcher.canStart)
                        Button {
                            launcher.beginSession(.desktop)
                        } label: {
                            Label("Desktop", systemImage: "desktopcomputer")
                        }
                        .disabled(!launcher.canStart)
                        Text("Runtime: \(launcher.runtimeStatus)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .onAppear { launcher.refreshLibrary() }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// Library: everything the client knows, searchable.
struct LibraryView: View {
    @ObservedObject var launcher: LauncherModel
    @State private var search = ""

    private var shown: [GameEntry] {
        guard !search.isEmpty else { return launcher.games }
        return launcher.games.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(shown) { game in
            Button { launcher.startGame(game) } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(game.name).lineLimit(1)
                        Text(game.installPath ?? game.kind.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if game.added {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                // The per-game environment, next to the game it is for: setting a
                // variable globally that was meant for one game is invisible
                // until you launch a different one and find it still applied.
                if let appID = game.appID, !appID.isEmpty {
                    NavigationLink {
                        GameEnvironmentEditor(scope: appID, gameName: game.name)
                    } label: {
                        Label("Environment", systemImage: "slider.horizontal.3")
                    }
                    .tint(.indigo)
                }
            }
        }
        .searchable(text: $search, prompt: "Games")
        .overlay {
            if shown.isEmpty {
                ContentUnavailableViewCompat("No games", detail: "Install the runtime, or add a game from the Files page.")
            }
        }
    }
}

/// Store: the Flathub shelves, behind its preference as on Android.
struct StoreView: View {
    @ObservedObject var launcher: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = launcher.storeError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ForEach(launcher.storeShelves, id: \.0) { shelf in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(shelf.0).font(.headline)
                        Text("\(shelf.1.count) apps")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .onAppear { launcher.loadStore() }
    }
}

/// Files: the guest filesystem, and the container around it.
struct FilesView: View {
    @ObservedObject var launcher: LauncherModel

    var body: some View {
        List {
            Section {
                ForEach(launcher.files) { node in
                    if node.isDirectory {
                        Button {
                            launcher.loadFiles(at: node.path)
                        } label: {
                            Label(node.name, systemImage: "folder")
                        }
                    } else {
                        HStack {
                            Label(node.name, systemImage: "doc")
                            Spacer()
                            Text(FileRules.formattedSize(node.size))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(launcher.filesPath)
            } footer: {
                // The same protection DroidDeck has: deleting something the
                // runtime owns means reinstalling it.
                Text("Runtime files cannot be deleted from here.")
            }
        }
        .onAppear { launcher.loadFiles(at: "/") }
    }
}

/// Components: the launcher tab that opens `ComponentsManager`.
struct ComponentsView: View {
    var body: some View { ComponentsManager() }
}

/// Driver: which Vulkan driver the guest draws with. The choice is DroidDeck's;
/// the list of what is installed is read out of the runtime's driver directory.
struct DriverView: View {
    @ObservedObject var launcher: LauncherModel

    var body: some View {
        Form {
            Section("Steam") {
                driverPicker(mode: .steam)
            }
            Section("Desktop") {
                driverPicker(mode: .desktop)
            }
            Section {
                // Turnip is the Adreno driver upstream imports. In the guest
                // the GPU is virtio, so the honest list is what the guest image
                // ships, and the import path is a guest-side package install.
                Text("The guest draws with the driver its image provides. Importing a "
                     + "different one installs it inside the guest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func driverPicker(mode: SessionMode) -> some View {
        Picker("Driver", selection: Binding(
            get: { launcher.prefs.linuxDriver(mode: mode) },
            set: { launcher.prefs.setLinuxDriver($0, mode: mode) })) {
            Text("Runtime default").tag("")
        }
    }
}

/// Settings: the preference schema, one row per key.
struct SettingsView: View {
    @EnvironmentObject private var launcher: LauncherModel

    private func info(_ key: String, _ fallback: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? fallback
    }

    var body: some View {
        Form {
            Section("Session") {
                Picker("Touch", selection: Binding(
                    get: { launcher.prefs.touchMode.rawValue },
                    set: { launcher.prefs.touchMode = TouchMode(rawValue: $0) ?? .auto })) {
                    Text("Auto").tag(TouchMode.auto.rawValue)
                    Text("Touchpad").tag(TouchMode.touchpad.rawValue)
                    Text("Direct").tag(TouchMode.direct.rawValue)
                }
                Picker("On-screen controls", selection: Binding(
                    get: { launcher.prefs.oscMode.rawValue },
                    set: { launcher.prefs.oscMode = OnScreenControlMode(rawValue: $0) ?? .auto })) {
                    Text("Auto").tag(OnScreenControlMode.auto.rawValue)
                    Text("Always").tag(OnScreenControlMode.always.rawValue)
                    Text("Steam QAM").tag(OnScreenControlMode.steamQAM.rawValue)
                    Text("Never").tag(OnScreenControlMode.never.rawValue)
                }
                Picker("Shape", selection: Binding(
                    get: { launcher.prefs.shapeMode.rawValue },
                    set: { launcher.prefs.shapeMode = ShapeMode(rawValue: $0) ?? .wide })) {
                    Text("Auto").tag(ShapeMode.auto.rawValue)
                    Text("Match screen").tag(ShapeMode.exact.rawValue)
                    Text("Always 16:9").tag(ShapeMode.wide.rawValue)
                }
                Picker("Controller", selection: Binding(
                    get: { launcher.prefs.controllerProfile.rawValue },
                    set: { launcher.prefs.controllerProfile = ControllerProfile(rawValue: $0) ?? .deck })) {
                    Text("Steam Deck").tag(ControllerProfile.deck.rawValue)
                    Text("Xbox 360").tag(ControllerProfile.xbox360.rawValue)
                }
                Picker("Suspend when backgrounded", selection: Binding(
                    get: { launcher.prefs.suspendMode.rawValue },
                    set: { launcher.prefs.suspendMode = SuspendMode(rawValue: $0) ?? .auto })) {
                    Text("Auto").tag(SuspendMode.auto.rawValue)
                    Text("Manual").tag(SuspendMode.manual.rawValue)
                    Text("Never").tag(SuspendMode.never.rawValue)
                }
                Toggle("Invert Back actions", isOn: Binding(
                    get: { launcher.prefs.backActionsInverted },
                    set: { launcher.prefs.backActionsInverted = $0 }))
            }
            Section("Beta") {
                Toggle("Flathub Store", isOn: Binding(
                    get: { launcher.prefs.storeEnabled },
                    set: {
                        launcher.prefs.storeEnabled = $0
                        if $0 { launcher.loadStore() }
                    }))
                Toggle("AppImage import", isOn: Binding(
                    get: { launcher.prefs.appImagesEnabled },
                    set: { launcher.prefs.appImagesEnabled = $0 }))
            }
            Section("Every game") {
                NavigationLink {
                    GameEnvironmentEditor(scope: "", gameName: nil)
                } label: {
                    Text("Game environment")
                }
                Picker("FEX preset", selection: Binding(
                    get: { launcher.prefs.text("fexPreset", default: "") },
                    set: { launcher.prefs.text2("fexPreset", $0) })) {
                    ForEach(FexPreset.all) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                }
            }
            Section("Logs") {
                Toggle("Keep session logs", isOn: Binding(
                    get: { launcher.prefs.logsEnabled },
                    set: { launcher.prefs.logsEnabled = $0 }))
                Text("Sessions write device.txt, session.log and events.jsonl into "
                     + "Documents/DroidDeck, which the Files app can reach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Build") {
                // The three numbers that decide whether a report about the app
                // "looking wrong" can be answered without rebuilding: which
                // commit, which SDK, and whether the launch screen made it into
                // the bundle. The last one matters because an app without a
                // launch screen is run by iOS in the old 320x480 mode - black
                // bars and everything scaled up - which looks like a layout bug
                // and is not one.
                LabeledContent("Commit", value: info("AppleDeckBuildCommit", "?"))
                LabeledContent("Built", value: info("AppleDeckBuildDate", "?"))
                LabeledContent("SDK", value: info("AppleDeckSDKVersion", "?"))
                LabeledContent("Launch screen", value: info("AppleDeckLaunchScreen", "?"))
                LabeledContent("Minimum iOS", value: info("MinimumOSVersion", "?"))
            }
            Section("Guest") {
                TextField("Hostname", text: Binding(
                    get: { launcher.prefs.guestHostname },
                    set: { launcher.prefs.guestHostname = $0 }))
                TextField("Steam channel", text: Binding(
                    get: { launcher.prefs.steamChannel },
                    set: { launcher.prefs.steamChannel = $0 }))
            }
        }
    }
}

/// `ContentUnavailableView` is iOS 17 and this app deploys to 16, so the empty
/// state is spelled out. It is the one place the port's floor shows.
struct ContentUnavailableViewCompat: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}