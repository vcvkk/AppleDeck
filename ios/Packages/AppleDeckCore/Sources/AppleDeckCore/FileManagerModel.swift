// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One entry in the Files screen, which on iOS browses two things at once: the
/// app's own container and whatever the guest has mounted.
public struct FileNode: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    /// True for a dotfile, or anything inside a dot-directory.
    public var isHidden: Bool
    /// A symlink, which the Files screen marks and rename/delete follow.
    public var isSymlink: Bool

    public init(path: String,
                name: String,
                isDirectory: Bool,
                size: Int64,
                modified: Date? = nil,
                isHidden: Bool? = nil,
                isSymlink: Bool = false) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        // Derived rather than defaulted: a node that forgot to say it was hidden
        // was a node the listing showed when it should not have.
        self.isHidden = isHidden ?? (name.hasPrefix(".") || path.contains("/."))
        self.isSymlink = isSymlink
    }

    public var isEmptyDirectory: Bool { isDirectory && size == 0 }
}

/// How the Files screen orders what it lists.
public enum FileSort: String, Codable, CaseIterable, Sendable {
    case name
    case size
    case date

    /// Directories always first, whatever the sort: a listing that mixes a
    /// folder between two files is one nobody can scan.
    public func sorted(_ nodes: [FileNode], showHidden: Bool) -> [FileNode] {
        let visible = showHidden ? nodes : nodes.filter { !$0.isHidden }
        let ordered = visible.enumerated().sorted { lhs, rhs in
            if lhs.element.isDirectory != rhs.element.isDirectory { return lhs.element.isDirectory }
            let result: Bool
            switch self {
            case .name:
                result = lhs.element.name.localizedCaseInsensitiveCompare(rhs.element.name) == .orderedAscending
            case .size:
                result = lhs.element.size == rhs.element.size
                    ? lhs.offset < rhs.offset
                    : lhs.element.size < rhs.element.size
            case .date:
                // Newest first: the reason to sort by date is to find what you
                // just put there.
                switch (lhs.element.modified, rhs.element.modified) {
                case let (l?, r?): result = l == r ? lhs.offset < rhs.offset : r < l
                case (nil, _?): result = false
                case (_?, nil): result = true
                case (nil, nil): result = lhs.offset < rhs.offset
                }
            }
            return result
        }
        return ordered.map { $0.element }
    }
}

/// A change the Files screen asks the guest filesystem to make.
///
/// The screen never touches the guest directly: on iOS the guest is a disk
/// image, and every write goes through the runtime's filesystem service, so
/// operations are values that the service executes and reports on.
public enum FileOperation: Equatable, Sendable {
    case createDirectory(path: String)
    case rename(path: String, to: String)
    case delete(paths: [String])
    case copy(paths: [String], toDirectory: String)
    case move(paths: [String], toDirectory: String)
    case importFile(from: URL, to: String)
    case export(paths: [String], to: URL)
    /// Makes the container visible to the Files app and the share sheet.
    case exposeAsDocument(path: String)

    /// Whether this operation destroys something. The Files screen asks before
    /// any of them; the ask is not optional, and a bulk delete of a mixed
    /// selection is confirmed with the count rather than as one item.
    public var isDestructive: Bool {
        switch self {
        case .delete, .move: return true
        case .createDirectory, .rename, .copy, .importFile, .export, .exposeAsDocument: return false
        }
    }
}

/// The rules the Files screen enforces before it hands an operation over.
public enum FileRules {
    /// A name the guest filesystem will accept: not empty, not `.` or `..`,
    /// no separator, no NUL, and nothing that would be confused with one of the
    /// archive suffixes the runtime writes (`\0` in particular is how a path
    /// ends a C string early in the shims).
    public static func isValidEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\0") else { return false }
        return name.count <= 255
    }

    /// The name a rename should be given when the target exists, so pasting a
    /// file twice does not overwrite the first.
    public static func uniqueName(_ desired: String, existing: Set<String>) -> String {
        guard existing.contains(desired) else { return desired }
        let url = URL(fileURLWithPath: desired)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var n = 2
        while existing.contains("\(base) \(n)\(suffix)") { n += 1 }
        return "\(base) \(n)\(suffix)"
    }

    /// Refuses to delete or move something the runtime owns. Losing
    /// `/usr/local/bin/gamescope` means reinstalling the runtime, and doing that
    /// from a swipe gesture is how a support ticket is born.
    public static func isProtected(_ path: String) -> Bool {
        let protected = [
            "/usr/local/bin/gamescope",
            "/usr/local/bin/steam-startup",
            "/usr/local/bin/droiddeck-desktop",
            "/usr/local/bin/mangoapp",
            "/etc/ld.so.preload",
            "/opt/android-host/proot"
        ]
        return protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Sizes formatted the way the Files screen shows them: exact bytes under
    /// 1 KiB, then one decimal, matching the Android screen's `1.2 GB`.
    public static func formattedSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }
}