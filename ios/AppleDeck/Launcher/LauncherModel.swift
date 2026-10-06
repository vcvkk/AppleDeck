// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SwiftUI
import AppleDeckCore

/// The launcher's state: what the pages show, and the one thing they all can do,
/// which is start a session.
///
/// Deliberately one object rather than one per page, because DroidDeck's
/// launcher state is process-wide by design (`SessionState`, `Library`,
/// `ComponentsManager`) and splitting it here would mean deciding what to
/// refresh when a session ends - which is exactly the bug class the port should
/// not import.
@MainActor
final class LauncherModel: ObservableObject {
    @Published var page: LauncherPage = .frontEnd
    @Published private(set) var games: [GameEntry] = []
    @Published private(set) var libraryError: String?
    @Published private(set) var files: [FileNode] = []
    @Published private(set) var filesPath: String = "/"
    @Published private(set) var storeShelves: [(String, [String])] = []
    @Published private(set) var storeError: String?
    @Published private(set) var runtimeStatus: String = ""

    let prefs: Prefs
    let session: SessionController
    let store: FlathubClient
    /// The game environment, as the editor's own store: the editor is the only
    /// writer, and the session reads the same file when it builds a command line.
    let environmentStore: GameEnvironmentStore
    private(set) var environment: GameEnvironment.Config

    /// The runtime the launcher will use. TCG today; see docs/ios-port.md for
    /// what a second backend has to satisfy.
    private(set) var runtime: QemuRuntime

    private let paths: GuestPaths
    private let files_ = FileManager.default

    init(container: URL? = nil, documents: URL? = nil) {
        let container = container ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                             in: .userDomainMask)[0]
        let documents = documents ?? FileManager.default.urls(for: .documentDirectory,
                                                             in: .userDomainMask)[0]
        self.paths = GuestPaths.standard(container: container.path,
                                        documents: documents.appendingPathComponent("DroidDeck").path)
        let defaults = UserDefaults(suiteName: Prefs.storeName) ?? .standard
        self.prefs = Prefs(store: UserDefaultsPrefs(defaults))
        self.runtime = QemuRuntime()
        self.session = SessionController(prefs: prefs, runtime: runtime, paths: paths)
        self.store = FlathubClient()
        self.environmentStore = GameEnvironmentStore.standard(container: container)
        // Read once and kept: the editor writes it, and a session reads it when
        // it builds the guest command line. A failed read is an empty
        // environment, which is what a session would have had anyway.
        self.environment = (try? self.environmentStore.read()) ?? GameEnvironment.Config()
        self.session.onFinish = { [weak self] in
            Task { @MainActor in self?.refreshLibrary() }
        }
        // Keep the copy the editor holds honest after a write.
        // Weakly, and assigned last: a closure over self during init captures it
        // as non-optional, and `self?.` on a non-optional is the compiler's way
        // of saying so.
        self.environmentStore.onWrite = { [weak self] config in
            Task { @MainActor in self?.environment = config }
        }
        reloadRuntimeStatus()
    }

    private func reloadRuntimeStatus() {
        if runtime.isAvailable {
            runtimeStatus = runtime.displayName
        } else {
            runtimeStatus = runtime.unavailableReason ?? "no runtime"
        }
    }

    var canStart: Bool {
        session.canStart && runtime.isAvailable
    }

    func beginSession(_ request: SessionRequest) {
        session.start(request)
    }

    func startGame(_ game: GameEntry) {
        if let appID = game.appID, !appID.isEmpty {
            beginSession(.steam(ui: .bigPicture, url: "steam://rungameid/\(appID)"))
        } else if let program = game.shortcutExe {
            beginSession(.run(program: program, arguments: []))
        }
    }

    // MARK: - Library

    func refreshLibrary() {
        let root = "\(paths.rootfs)\(GuestPaths.Guest.steamData)"
        let reader = SteamLibraryReader(root: root, files: GuestFileSource(paths: paths))
        let found = reader.games() + reader.shortcuts()
        games = found
        libraryError = found.isEmpty ? "No games in \(root). Install the runtime, or add one on the Files page." : nil
    }

    // MARK: - Files

    func loadFiles(at path: String) {
        let full = path.hasPrefix("/") ? path : paths.rootfs + path
        filesPath = path
        var found: [FileNode] = []
        do {
            let contents = try files_.contentsOfDirectory(
                at: URL(fileURLWithPath: full),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            for url in contents {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                              .contentModificationDateKey])
                let isDirectory = values?.isDirectory ?? false
                found.append(FileNode(path: full + "/" + url.lastPathComponent,
                                      name: url.lastPathComponent,
                                      isDirectory: isDirectory,
                                      size: Int64(values?.fileSize ?? 0),
                                      modified: values?.contentModificationDate,
                                      isHidden: url.lastPathComponent.hasPrefix(".")))
            }
        } catch {
            files = []
            filesPath = path
            return
        }
        files = FileSort.name.sorted(found, showHidden: true)
    }

    // MARK: - Store

    func loadStore() {
        guard prefs.storeEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let shelves = try await store.featured()
                let names = [("Featured", shelves.featured),
                             ("Popular", shelves.popular),
                             ("Games", shelves.games)]
                let loaded: [(String, [String])] = names.compactMap { name, ids in
                    guard !ids.isEmpty else { return nil }
                    return (name, ids)
                }
                await MainActor.run {
                    self.storeShelves = loaded
                    self.storeError = nil
                }
            } catch {
                await MainActor.run { self.storeError = error.localizedDescription }
            }
        }
    }
}

/// `PrefsStore` over `UserDefaults`, so the preference schema in AppleDeckCore
/// stays testable on a runner that has no iOS in it.
final class UserDefaultsPrefs: PrefsStore {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults) { self.defaults = defaults }

    func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    func setBool(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }

    func string(forKey key: String) -> String? {
        defaults.object(forKey: key) as? String
    }

    func setString(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }

    func double(forKey key: String) -> Double? {
        defaults.object(forKey: key) as? Double
    }

    func setDouble(_ value: Double, forKey key: String) { defaults.set(value, forKey: key) }

    func remove(forKey key: String) { defaults.removeObject(forKey: key) }
}

/// Reads the guest's files as if they were local ones.
///
/// Today the guest's rootfs is a directory in the app container once it is
/// unpacked. When it becomes a mounted disk image, this is the one class that
/// changes: everything above it asks a `FileSource`, not a filesystem.
struct GuestFileSource: SteamLibraryReader.FileSource {
    let paths: GuestPaths
    private let fm = FileManager.default

    func contents(of path: String) -> Data? { fm.contents(atPath: path) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    func entries(in path: String) -> [String]? {
        try? fm.contentsOfDirectory(atPath: path)
    }
}