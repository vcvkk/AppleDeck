// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
// URLSession lives in FoundationNetworking on Linux and in Foundation on Apple
// platforms, which is the whole reason this package is worth testing on a runner
// that has no iOS in it.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Valve's KeyValues text format, as far as the Steam client writes it.
///
/// `libraryfolders.vdf`, `appmanifest_*.acf` and the non-Steam shortcut files
/// are all this format, and DroidDeck reads the same ones (see
/// `docs/development/steam-game-imports.md`). The parser is deliberately
/// partial: quoted strings, unquoted tokens, `//` comments, brace nesting, and
/// nothing else. KeyValues has no other syntax that matters here, and a full
/// implementation would be more code than the five fields each file carries.
public enum KeyValues {
    public indirect enum Value: Equatable {
        case string(String)
        case list([Entry])

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var listValue: [Entry]? {
            if case .list(let entries) = self { return entries }
            return nil
        }

        public subscript(key: String) -> Value? {
            listValue?.first { $0.key == key }?.value
        }

        public func string(_ key: String) -> String? { self[key]?.stringValue }
        public func list(_ key: String) -> [Entry]? { self[key]?.listValue }
    }

    public struct Entry: Equatable {
        public var key: String
        public var value: Value

        public init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// Parses a document into its top-level list. Returns `nil` for anything
    /// that does not parse, so a caller can treat a corrupt file as absent
    /// instead of as a library with no games.
    public static func parse(_ text: String) -> [Entry]? {
        var scanner = Scanner(Array(text.utf8))
        var out: [Entry] = []
        guard scanner.entries(into: &out, depth: 0) else { return nil }
        // A document with no braces in it is not a KeyValues document. Without
        // this, a file of plain words parses into entries with the words as keys
        // and a caller treats garbage as an empty library.
        guard scanner.sawBraces else { return nil }
        return out
    }

    struct Scanner {
        let bytes: [UInt8]
        var index = 0
        /// Whether the document had a block in it at all. See `parse`.
        var sawBraces = false

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipTrivia() {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C {
                    index += 1
                } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                    index = min(index + 2, bytes.count)
                } else {
                    return
                }
            }
        }

        /// Reads entries into `out` until end of input (`depth == 0`) or the
        /// brace that closes this level. Returns false on anything malformed, so
        /// a truncated or binary file parses as absent rather than as empty.
        mutating func entries(into out: inout [Entry], depth: Int) -> Bool {
            while true {
                skipTrivia()
                // A comma between entries is a separator, not part of a key. Every
                // file the Steam client writes uses them, and treating one as a
                // key silently mis-parses everything after the first comma - which
                // is why a library folder's apps block came back empty.
                if !atEnd && bytes[index] == 0x2C {
                    index += 1
                    continue
                }
                if atEnd { return depth == 0 }
                if bytes[index] == 0x7D {
                    index += 1
                    return depth > 0
                }
                if bytes[index] == 0x7B {
                    sawBraces = true
                    return false
                }
                guard let key = token() else { return false }
                skipTrivia()
                guard index < bytes.count else { return false }
                switch bytes[index] {
                case 0x7B:
                    sawBraces = true
                    index += 1
                    var child: [Entry] = []
                    guard entries(into: &child, depth: depth + 1) else { return false }
                    out.append(Entry(key: key, value: .list(child)))
                case 0x22:
                    index += 1
                    guard let value = quoted() else { return false }
                    out.append(Entry(key: key, value: .string(value)))
                default:
                    guard let value = token() else { return false }
                    out.append(Entry(key: key, value: .string(value)))
                }
            }
        }

        mutating func quoted() -> String? {
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x5C, index + 1 < bytes.count {
                    index += 1
                    out.append(bytes[index])
                    index += 1
                    continue
                }
                if byte == 0x22 {
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                out.append(byte)
                index += 1
            }
            return nil
        }

        mutating func token() -> String? {
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    // A quoted token: callers that expect a quoted value read
                    // it themselves, so a key in quotes is legal.
                    index += 1
                    guard let value = quoted() else { return nil }
                    return value
                }
                if byte == 0x7B || byte == 0x7D || byte == 0x2C || byte == 0x20
                    || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    break
                }
                out.append(byte)
                index += 1
            }
            return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
        }
    }
}

/// One game in the launcher's library.
public struct GameEntry: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var appID: String?
    /// Where the game runs from, in guest paths.
    public var installPath: String?
    public var artworkPath: String?
    public var shortcutExe: String?
    public var kind: Kind
    /// Set for a game the user added by hand (a `.desktop` entry, an AppImage,
    /// a ROM) rather than one the client knows.
    public var added: Bool

    public enum Kind: String, Codable, Sendable {
        case steam
        case shortcut
        case added
        case flatpak
        case appImage = "appimage"
        case rom
    }

    public init(id: String,
                name: String,
                appID: String? = nil,
                installPath: String? = nil,
                artworkPath: String? = nil,
                shortcutExe: String? = nil,
                kind: Kind = .steam,
                added: Bool = false) {
        self.id = id
        self.name = name
        self.appID = appID
        self.installPath = installPath
        self.artworkPath = artworkPath
        self.shortcutExe = shortcutExe
        self.kind = kind
        self.added = added
    }
}

/// Reads a Steam library off the guest filesystem.
///
/// The files are the ones DroidDeck reads, in the paths the runtime's overlay
/// creates: `steamapps/libraryfolders.vdf`, then `appmanifest_*.acf` in each
/// library, then `steam/shortcuts.vdf` for the non-Steam entries. Filesystem
/// access is injected, so the whole scan is testable and the same code reads a
/// mounted guest volume or a directory staged on the Mac.
public struct SteamLibraryReader {
    /// The slice of filesystem the reader needs. Deliberately this small: the
    /// guest is reached through a mount, and that mount is the only thing that
    /// should have to change when it moves.
    public protocol FileSource {
        func contents(of path: String) -> Data?
        func exists(_ path: String) -> Bool
        func entries(in path: String) -> [String]?
    }

    public let root: String
    public let files: FileSource

    public init(root: String, files: FileSource) {
        self.root = root
        self.files = files
    }

    /// The library directories from `libraryfolders.vdf`, newest format first:
    /// `"0" { "path" "..." }`, falling back to the old `"1" { "0" "..." }`.
    public func libraryPaths() -> [String] {
        guard let data = files.contents(of: "\(root)/steamapps/libraryfolders.vdf"),
              let text = String(data: data, encoding: .utf8),
              let entries = KeyValues.parse(text) else { return [] }
        guard let rootList = entries.first?.value.listValue else { return [] }

        var out: [String] = []
        // Modern: "path" keys.
        for entry in rootList where entry.value.stringValue == nil {
            if let path = entry.value.string("path") { out.append(path) }
        }
        if out.isEmpty {
            // Legacy: one level of indices holding paths.
            for entry in rootList {
                guard let nested = entry.value.listValue else { continue }
                for child in nested {
                    if let path = child.value.stringValue, path.hasPrefix("/") {
                        out.append(path)
                    }
                }
            }
        }
        return out
    }

    /// Every Steam game in every library directory.
    public func games() -> [GameEntry] {
        var out: [GameEntry] = []
        for library in libraryPaths() {
            out += games(inLibrary: library)
        }
        if out.isEmpty {
            out = games(inLibrary: root)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func games(inLibrary library: String) -> [GameEntry] {
        guard let names = files.entries(in: "\(library)/steamapps") else { return [] }
        var out: [GameEntry] = []
        for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            guard let data = files.contents(of: "\(library)/steamapps/\(name)"),
                  let text = String(data: data, encoding: .utf8),
                  let entries = KeyValues.parse(text),
                  let state = entries.first?.value,
                  let appID = state.string("appid"),
                  let name = state.string("name") else { continue }
            out.append(GameEntry(id: "app-\(appID)",
                                 name: name,
                                 appID: appID,
                                 installPath: state.string("installdir").map { "\(library)/steamapps/common/\($0)" },
                                 artworkPath: "\(library)/steamapps/library_assets/\(appID).jpg",
                                 kind: .steam))
        }
        return out
    }

    /// The non-Steam shortcuts, which is where a ROM or an AppImage the user
    /// dropped in ends up.
    public func shortcuts() -> [GameEntry] {
        guard let data = files.contents(of: "\(root)/shortcuts.vdf"),
              let text = String(data: data, encoding: .utf8),
              let entries = KeyValues.parse(text),
              let list = entries.first?.value.listValue else { return [] }
        var out: [GameEntry] = []
        for entry in list {
            let appID = entry.value.string("appid") ?? ""
            let name = entry.value.string("AppName") ?? "Shortcut"
            let exe = entry.value.string("Exe")
            let icon = entry.value.string("Icon")
            out.append(GameEntry(id: "sc-\(appID.isEmpty ? UUID().uuidString : appID)",
                                 name: name,
                                 appID: appID.isEmpty ? nil : appID,
                                 artworkPath: icon,
                                 shortcutExe: exe,
                                 kind: .shortcut))
        }
        return out
    }
}

/// The Flathub store, as the Store screen consumes it.
public struct FlathubClient {
    public struct App: Decodable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var summary: String?
        public var icon: String?
        public var installs: Int?
        public var isVerified: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, summary, icon
            case installs
            case isVerified = "verified"
        }
    }

    public struct SearchResponse: Decodable, Sendable {
        public var hits: [Hit]

        public struct Hit: Decodable, Sendable {
            public var appId: String
            public var name: String
            public var summary: String?
            public var icon: String?
            public var installs: Int?
            public var verified: Bool

            public var app: App {
                App(id: appId, name: name, summary: summary, icon: icon,
                    installs: installs, isVerified: verified)
            }
        }
    }

    public struct FeaturedResponse: Decodable, Sendable {
        public var featuredApps: [String]?
        public var popularApps: [String]?
        public var games: [String]?
    }

    public let endpoint: String
    public let session: URLSession

    public init(endpoint: String = "https://flathub.org/api/v2", session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: endpoint + path) else { throw AgentError.transport("bad store url") }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentError.transport("store returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public func search(_ query: String) async throws -> [App] {
        guard !query.isEmpty else { return [] }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let response: SearchResponse = try await get("/search?\(components.percentEncodedQuery ?? "")", as: SearchResponse.self)
        return response.hits.map { $0.app }
    }

    public func app(id: String) async throws -> App {
        try await get("/appstream/\(id)", as: App.self)
    }

    /// The three shelves the Store page shows, in DroidDeck's order.
    public func featured() async throws -> (featured: [String], popular: [String], games: [String]) {
        let response: FeaturedResponse = try await get("/featured", as: FeaturedResponse.self)
        return (response.featuredApps ?? [], response.popularApps ?? [], response.games ?? [])
    }
}