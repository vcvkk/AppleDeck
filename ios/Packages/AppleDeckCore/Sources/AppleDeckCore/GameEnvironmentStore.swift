// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Reads and writes the game environment, atomically and with validation.
///
/// Two properties matter more than the format. First, a read that finds
/// something invalid throws instead of returning half of it: an environment file
/// with a name the guest would never read, or a scope that is not an app id, is
/// a file something else wrote badly, and quietly dropping the bad entries turns
/// that into "my setting does nothing" with nothing in the log. Second, a write
/// is atomic: the guest reads this file while a session is starting, and a
/// truncated file at that moment is a session that starts with no environment at
/// all.
public final class GameEnvironmentStore {
    /// The file's format version. The reader insists on it, like DroidDeck's.
    public static let version = 1

    /// Where it lives, inside the app container next to the runtime's version
    /// stamp - not in the guest, because the launcher owns it and the guest only
    /// reads what the launcher passes down.
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard(container: URL) -> GameEnvironmentStore {
        GameEnvironmentStore(url: container
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("game-environment.json"))
    }

    public func read() throws -> GameEnvironment.Config {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return GameEnvironment.Config()
        }
        return try Self.decode(data)
    }

    public func write(_ config: GameEnvironment.Config) throws {
        let data = try Self.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // .atomic writes a temporary file and renames it, so a reader either sees
        // the old file or the new one and never half of either.
        try data.write(to: url, options: .atomic)
    }

    /// Removes the file, which is what "reset to defaults" means: there is no
    /// value stored anywhere else, and an empty environment is the same thing.
    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Coding

    /// The on-disk shape, with `null` meaning "set to nothing" - which is why the
    /// values are `[String: String?]`: an absent key is "never set", and that is
    /// different, and the editor shows the difference.
    struct File: Codable, Equatable {
        var version: Int
        var shared: [String: String?]?
        var games: [String: [String: String?]]?
    }

    public static func encode(_ config: GameEnvironment.Config) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(version: version,
                                       shared: config.shared,
                                       games: config.games.isEmpty ? nil : config.games))
    }

    public static func decode(_ data: Data) throws -> GameEnvironment.Config {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == version else {
            throw StoreError.unsupportedVersion(file.version)
        }
        var config = GameEnvironment.Config()
        for (name, value) in file.shared ?? [:] {
            try validate(name: name, value: value)
            config.shared[name] = value
        }
        for (scope, entries) in file.games ?? [:] {
            guard GameEnvironment.isValidScope(scope) else {
                throw StoreError.invalidScope(scope)
            }
            var checked: [String: String?] = [:]
            for (name, value) in entries {
                try validate(name: name, value: value)
                checked[name] = value
            }
            config.games[scope] = checked
        }
        return config
    }

    private static func validate(name: String, value: String?) throws {
        guard GameEnvironment.isValidName(name) else {
            throw StoreError.invalidName(name)
        }
        guard GameEnvironment.isSupported(name) else {
            // Not an error to shrug at: this is a name the runtime owns, so
            // writing it would break the shim it belongs to.
            throw StoreError.runtimeManagedName(name)
        }
        if let value, !GameEnvironment.isValidValue(value) {
            throw StoreError.invalidValue(name)
        }
    }

    public enum StoreError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidName(String)
        case invalidScope(String)
        case invalidValue(String)
        case runtimeManagedName(String)

        public var message: String {
            switch self {
            case .unsupportedVersion(let version):
                return "game-environment.json is version \(version); this build reads version \(GameEnvironmentStore.version)"
            case .invalidName(let name):
                return "'\(name)' is not a variable name the guest would read"
            case .invalidScope(let scope):
                return "'\(scope)' is not a Steam app id"
            case .invalidValue(let name):
                return "the value for \(name) is empty, longer than 8 KiB, or contains a NUL"
            case .runtimeManagedName(let name):
                return "\(name) belongs to the runtime's own shims and cannot be set here"
            }
        }
    }
}