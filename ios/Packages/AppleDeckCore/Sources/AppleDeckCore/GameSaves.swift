// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AppleDeckCore

/// A game's saves, and what can be done with them.
///
/// The shape is DroidDeck's: saves live under the Proton prefix the client
/// assigned to that app, the interesting directories are the ones a game actually
/// writes (`users/<user>/AppData`, `users/<user>/Documents`, `Saved Games`), and
/// everything the launcher offers to do happens as a zip under
/// `Documents/DroidDeck/Saves`.
///
/// What changed on iOS is where that directory is: an app cannot write to the
/// shared Downloads folder, so it is inside the container and visible through the
/// Files app, which `UIFileSharingEnabled` already makes true.
public enum GameSaves {
    /// One directory a game writes saves into.
    public struct SaveDir: Equatable, Identifiable, Sendable {
        public var path: String
        /// Bytes, recursively - a save directory is a tree, not a file.
        public var bytes: Int64
        public var modified: Date?

        public var id: String { path }
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

        public var size: String { FileRules.formattedSize(bytes) }
    }

    public struct Game: Equatable, Sendable {
        public var id: String
        public var name: String
        /// The guest path of the Proton prefix: `.../pfx/<name>`.
        public var protonPrefix: String?
        public var directories: [SaveDir]

        public var totalBytes: Int64 { directories.reduce(0) { $0 + $1.bytes } }
        public var hasSaves: Bool { directories.contains { $0.bytes > 0 } }
    }

    public enum Layout: String, CaseIterable, Sendable {
        case profile = "steamuser"
        case directories = "game-dirs"

        public var title: String {
            switch self {
            case .profile: return "The whole Steam user"
            case .directories: return "Only this game's folders"
            }
        }

        public var detail: String {
            switch self {
            case .profile:
                return "users/steamuser in the Proton prefix: this game and every other one"
            case .directories:
                return "just the folders below, which is what a game with its own profile needs"
            }
        }
    }

    /// The paths worth looking at, in the order they are offered. Each is
    /// relative to the Proton prefix.
    public static let interesting: [String] = [
        "drive_c/users/steamuser/AppData",
        "drive_c/users/steamuser/Documents",
        "drive_c/users/steamuser/Saved Games",
        "drive_c/users/steamuser/LocalLow",
        "drive_c/users/steamuser/savedata"
    ]

    public static func makeGame(id: String, name: String, protonPrefix: String?) -> Game {
        Game(id: id, name: name, protonPrefix: protonPrefix, directories: [])
    }
}

/// Finds a game's saves and exports them, on the host side of the guest
/// filesystem.
///
/// The filesystem is injected because it is the guest's: on iOS that is a
/// directory in the container for now, and a mounted image later. Everything that
/// is a decision - which directories count, what a name is safe to be, how an
/// export is laid out - is here and testable.
public struct SavesReader {
    public protocol FileSystem {
        func exists(_ path: String) -> Bool
        func isDirectory(_ path: String) -> Bool
        func size(ofTreeAt path: String) -> Int64?
        func modified(at path: String) -> Date?
        func entries(in path: String) -> [String]?
        /// Writes a zip of `roots` under `destination`, returning the path and the
        /// number of files it holds.
        func archive(paths roots: [String], to destination: String, layout: GameSaves.Layout) throws -> (path: String, files: Int)
    }

    public let files: FileSystem
    /// Where exports go: the container's Documents/DroidDeck/Saves.
    public let exportsRoot: String

    public init(files: FileSystem, exportsRoot: String) {
        self.files = files
        self.exportsRoot = exportsRoot
    }

    /// The save directories a game has, with their sizes. Directories that do
    /// not exist are simply absent: a game that has never been run has none, and
    /// an empty list says that better than a list of zeroes.
    public func locate(game: GameSaves.Game) -> GameSaves.Game {
        guard let prefix = game.protonPrefix else { return game }
        var found: [GameSaves.SaveDir] = []
        for relative in GameSaves.interesting {
            let path = "\(prefix)/\(relative)"
            guard files.isDirectory(path) else { continue }
            found.append(GameSaves.SaveDir(path: path,
                                            bytes: files.size(ofTreeAt: path) ?? 0,
                                            modified: files.modified(at: path)))
        }
        var updated = game
        updated.directories = found
        return updated
    }

    /// A file name that is safe everywhere: no separators, no characters Windows
    /// will not put in a zip, never empty. The guest is a Windows machine as far
    /// as a Proton game is concerned, and its filesystem is the one that decides.
    public static func safeName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.unicodeScalars
            .map { forbidden.contains($0) ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(80))
    }

    /// The export name: `<game>_<timestamp>.zip`. The timestamp is UTC and the
    /// stamp is fixed-width, so exports sort the way they happened.
    public static func exportName(for game: GameSaves.Game, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // DateFormatter rather than FormatStyle: the stamp has to be fixed width
        // so exports sort by name, and an ISO 8601 chain with separators spelled
        // out is more machinery than that needs.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(safeName(game.name))_\(formatter.string(from: date)).zip"
    }

    /// Exports a game. Returns where the zip went and how many files it holds.
    ///
    /// The Proton prefix is the export root in the `steamuser` layout, because
    /// that is what Proton writes relative to; in the `game-dirs` layout the
    /// directories are exported as they are.
    public func export(game: GameSaves.Game, layout: GameSaves.Layout, at date: Date) throws -> (path: String, files: Int) {
        guard let prefix = game.protonPrefix else {
            throw SavesError.noProtonPrefix(game.name)
        }
        let paths = layout == .profile ? [prefix] : game.directories.map(\.path)
        guard !paths.isEmpty else {
            throw SavesError.nothingToExport(game.name)
        }
        let destination = "\(exportsRoot)/\(Self.exportName(for: game, at: date))"
        do {
            return try files.archive(paths: paths, to: destination, layout: layout)
        } catch let error as SavesError {
            throw error
        } catch {
            throw SavesError.writeFailed(error.localizedDescription)
        }
    }

    public enum SavesError: Error, Equatable {
        case noProtonPrefix(String)
        case nothingToExport(String)
        case writeFailed(String)

        public var message: String {
            switch self {
            case .noProtonPrefix(let name):
                return "\(name) has no Proton prefix yet - it has not been installed by the client"
            case .nothingToExport(let name):
                return "\(name) has no save folders yet"
            case .writeFailed(let text):
                return "the archive could not be written: \(text)"
            }
        }
    }
}