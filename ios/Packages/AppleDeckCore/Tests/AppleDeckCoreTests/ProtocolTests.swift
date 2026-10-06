// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AppleDeckCore

final class AgentProtocolTests: XCTestCase {
    func testStateStopResume() throws {
        XCTAssertEqual(try AgentCommand.parse(["state"]), .state)
        XCTAssertEqual(try AgentCommand.parse(["stop"]), .stop)
        XCTAssertEqual(try AgentCommand.parse(["resume"]), .resume)
    }

    func testStartSteamDefaultsToBigPicture() throws {
        guard case .start(let start) = try AgentCommand.parse(["start", "steam"]) else {
            return XCTFail("expected start")
        }
        XCTAssertEqual(start.mode, .steam)
        XCTAssertEqual(start.ui, .bigPicture)
        XCTAssertNil(start.url)
        XCTAssertFalse(start.wait)
    }

    func testStartWithUiUrlAndWait() throws {
        let argv = ["start", "steam", "--ui", "desktop", "--url", "steam://friends", "--wait", "--timeout", "90"]
        guard case .start(let start) = try AgentCommand.parse(argv) else {
            return XCTFail("expected start")
        }
        XCTAssertEqual(start.ui, .desktop)
        XCTAssertEqual(start.url, "steam://friends")
        XCTAssertTrue(start.wait)
        XCTAssertEqual(start.timeout, 90)
    }

    func testStartDesktopHasNoSteamFields() throws {
        guard case .start(let start) = try AgentCommand.parse(["start", "desktop", "--wait"]) else {
            return XCTFail("expected start")
        }
        XCTAssertEqual(start.mode, .desktop)
        XCTAssertNil(start.ui)
        XCTAssertTrue(start.wait)
    }

    func testRunTakesAPathAndArguments() throws {
        XCTAssertEqual(try AgentCommand.parse(["run", "/usr/bin/foo", "--", "arg1", "arg2"]),
                       .run(program: "/usr/bin/foo", arguments: ["arg1", "arg2"]))
    }

    func testRunWithoutSeparatorStillKeepsArguments() throws {
        XCTAssertEqual(try AgentCommand.parse(["run", "/usr/bin/foo", "arg1"]),
                       .run(program: "/usr/bin/foo", arguments: ["arg1"]))
    }

    func testRunRejectsARelativePath() {
        XCTAssertThrowsError(try AgentCommand.parse(["run", "foo"])) { error in
            XCTAssertEqual((error as? AgentError)?.exitCode, 2)
        }
    }

    func testSerialFlagIsAcceptedAndIgnored() throws {
        // Upstream's CLI takes --serial to pick a device; there is one device.
        XCTAssertEqual(try AgentCommand.parse(["--serial", "ABC123", "state"]), .state)
    }

    func testUnknownVerbIsAUsageError() {
        XCTAssertThrowsError(try AgentCommand.parse(["frobnicate"])) { error in
            XCTAssertEqual(error as? AgentError, .usage("unknown command 'frobnicate'"))
        }
    }

    func testExitCodesMatchTheCliDocument() {
        XCTAssertEqual(AgentError.usage("x").exitCode, 2)
        XCTAssertEqual(AgentError.transport("x").exitCode, 3)
        XCTAssertEqual(AgentError.sessionFailed("x").exitCode, 4)
        XCTAssertEqual(AgentError.timeout("x").exitCode, 5)
    }
}

final class KeyValuesTests: XCTestCase {
    func testLibraryFolders() throws {
        let text = """
        "libraryfolders"
        {
            "0"
            {
                "path"      "/root/.local/share/Steam"
                "label"     ""
                "contentid" "123"
                "totalsize" "0"
                "update_clean_bytes_tally" "0"
                "time_last_update_verified" "0"
                "apps"
                {
                    "10"  "12000000"
                }
            }
            "1"
            {
                "path" "/mnt/sd/SteamLibrary"
            }
        }
        """
        let entries = try XCTUnwrap(KeyValues.parse(text))
        let root = entries.first?.value
        // Through `list(_:)`, not `string(_:)`: the value under an index key is a
        // list, and optional-chaining off the String? that `string(_:)` returns is
        // not a thing.
        // The parsed structure is in the failure message on purpose: a parser bug
        // should say what it saw, not only what it did not find.
        let seen = "parsed: \(entries)"
        XCTAssertEqual(root?.list("0").flatMap { KeyValues.value(in: $0, "path") }?.stringValue,
                       "/root/.local/share/Steam", seen)
        XCTAssertEqual(root?.list("1").flatMap { KeyValues.value(in: $0, "path") }?.stringValue,
                       "/mnt/sd/SteamLibrary", seen)
        // The apps block maps an app id to its size on disk. The subscript
        // reaches into a list value, which is the operation here - going through
        // list(_:) asks for the app's children instead.
        let apps = root?.list("0").flatMap { KeyValues.value(in: $0, "apps") }
        XCTAssertEqual(apps?["10"]?.stringValue, "12000000", seen)
    }

    func testAppManifest() throws {
        let text = """
        "AppState"
        {
            "appid"      "1245620"
            "name"       "ELDEN RING"
            "installdir" "ELDEN RING"
            "StateFlags" "4"
        }
        """
        let state = try XCTUnwrap(KeyValues.parse(text)).first?.value
        XCTAssertEqual(state?.string("appid"), "1245620")
        XCTAssertEqual(state?.string("name"), "ELDEN RING")
        XCTAssertEqual(state?.string("installdir"), "ELDEN RING")
    }

    func testCommentsAndEscapes() throws {
        let text = """
        // leading comment
        "Shortcuts"
        {
            "0"
            {
                "appid"  "1"
                "AppName"  "Quote \\\" inside"   // trailing comment
                "Exe"     "/usr/bin/games/x.sh"
            }
        }
        """
        let shortcut = try XCTUnwrap(KeyValues.parse(text))
            .first?.value.list("0")
        let seen = "shortcut: \(String(describing: shortcut))"
        XCTAssertEqual(shortcut.flatMap { KeyValues.value(in: $0, "AppName") }?.stringValue,
                       "Quote \" inside", seen)
        XCTAssertEqual(shortcut.flatMap { KeyValues.value(in: $0, "Exe") }?.stringValue,
                       "/usr/bin/games/x.sh", seen)
    }

    func testTruncatedFileParsesAsAbsent() {
        XCTAssertNil(KeyValues.parse("\"Shortcuts\"\n{\n  \"0\"\n"))
    }

    func testSomethingThatIsNotKeyValuesParsesAsAbsent() {
        XCTAssertNil(KeyValues.parse("not keyvalues at all"))
    }

    func testCommasSeparateEntries() throws {
        // Every file the Steam client writes separates entries with commas, and
        // treating one as part of the next key mis-parses everything after the
        // first one.
        let text = "\"libraryfolders\" { \"0\" { \"path\" \"/a\", \"label\" \"\", } }"
        let entries = try XCTUnwrap(KeyValues.parse(text))
        let root = entries.first?.value
        let seen = "parsed: \(entries)"
        XCTAssertEqual(root?.list("0").flatMap { KeyValues.value(in: $0, "path") }?.stringValue,
                       "/a", seen)
        XCTAssertEqual(root?.list("0").flatMap { KeyValues.value(in: $0, "label") }?.stringValue,
                       "", seen)
    }
}

final class SteamLibraryTests: XCTestCase {
    private struct StubFiles: SteamLibraryReader.FileSource {
        var files: [String: String] = [:]
        var directories: [String: [String]] = [:]

        func contents(of path: String) -> Data? { files[path]?.data(using: .utf8) }
        func exists(_ path: String) -> Bool { files[path] != nil || directories[path] != nil }
        func entries(in path: String) -> [String]? { directories[path] }
    }

    private var files: StubFiles!

    override func setUp() {
        super.setUp()
        let root = "/root/.local/share/Steam"
        files = StubFiles()
        files.files["\(root)/steamapps/libraryfolders.vdf"] = """
        "libraryfolders" { "0" { "path" "\(root)" } }
        """
        files.directories["\(root)/steamapps"] = ["appmanifest_10.acf", "appmanifest_570.acf", "common"]
        files.files["\(root)/steamapps/appmanifest_10.acf"] = """
        "AppState" { "appid" "10" "name" "Counter-Strike" "installdir" "cs" }
        """
        files.files["\(root)/steamapps/appmanifest_570.acf"] = """
        "AppState" { "appid" "570" "name" "Dota 2" "installdir" "dota2beta" }
        """
        files.files["\(root)/shortcuts.vdf"] = """
        "Shortcuts"
        {
            "0" { "appid" "9001" "AppName" "Retro Arch" "Exe" "/usr/bin/retroarch" }
        }
        """
    }

    func testLibraryPath() {
        let reader = SteamLibraryReader(root: "/root/.local/share/Steam", files: files)
        XCTAssertEqual(reader.libraryPaths(), ["/root/.local/share/Steam"])
    }

    func testGamesAreSortedByNameAndCarryTheirInstallPath() {
        let reader = SteamLibraryReader(root: "/root/.local/share/Steam", files: files)
        let games = reader.games()
        XCTAssertEqual(games.map(\.name), ["Counter-Strike", "Dota 2"])
        XCTAssertEqual(games.first?.installPath, "/root/.local/share/Steam/steamapps/common/cs")
        XCTAssertEqual(games.first?.appID, "10")
        XCTAssertTrue(games.first?.artworkPath?.hasSuffix("library_assets/10.jpg") == true)
    }

    func testNonSteamManifestsAreIgnored() {
        let reader = SteamLibraryReader(root: "/root/.local/share/Steam", files: files)
        XCTAssertFalse(reader.games().contains { $0.name == "common" })
    }

    func testShortcuts() {
        let reader = SteamLibraryReader(root: "/root/.local/share/Steam", files: files)
        let shortcuts = reader.shortcuts()
        XCTAssertEqual(shortcuts.count, 1)
        XCTAssertEqual(shortcuts.first?.name, "Retro Arch")
        XCTAssertEqual(shortcuts.first?.shortcutExe, "/usr/bin/retroarch")
    }

    func testAnEmptyLibraryIsEmptyNotBroken() {
        let reader = SteamLibraryReader(root: "/nope", files: StubFiles())
        XCTAssertEqual(reader.games(), [])
        XCTAssertEqual(reader.libraryPaths(), [])
    }
}

final class FileManagerTests: XCTestCase {
    private func node(_ name: String, dir: Bool = false, size: Int64 = 0, at: Date? = nil, hidden: Bool? = nil) -> FileNode {
        // hidden defaults to nil so the model derives it from the name, which is
        // what production does.
        FileNode(path: "/dir/\(name)", name: name, isDirectory: dir, size: size,
                 modified: at, isHidden: hidden)
    }

    func testDirectoriesSortFirstAndNamesCaseInsensitively() {
        let sorted = FileSort.name.sorted([
            node("b.txt", size: 10), node("Alpha", dir: true), node("a.txt", size: 5)
        ], showHidden: false)
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "a.txt", "b.txt"])
    }

    func testHiddenEntriesAreHiddenUnlessAsked() {
        let entries = [node(".config", dir: true), node("visible.txt")]
        XCTAssertEqual(FileSort.name.sorted(entries, showHidden: false).map(\.name), ["visible.txt"])
        XCTAssertEqual(FileSort.name.sorted(entries, showHidden: true).count, 2)
    }

    func testDateSortPutsNewestFirstAmongFiles() {
        let sorted = FileSort.date.sorted([
            node("old", at: Date(timeIntervalSince1970: 0)),
            node("new", at: Date(timeIntervalSince1970: 1000))
        ], showHidden: true)
        XCTAssertEqual(sorted.map(\.name), ["new", "old"])
    }

    func testSizeSortIsStableForEqualSizes() {
        let sorted = FileSort.size.sorted([node("a", size: 5), node("b", size: 5)], showHidden: true)
        XCTAssertEqual(sorted.map(\.name), ["a", "b"])
    }

    func testEntryNameValidation() {
        XCTAssertTrue(FileRules.isValidEntryName("My Game.sh"))
        XCTAssertFalse(FileRules.isValidEntryName(""))
        XCTAssertFalse(FileRules.isValidEntryName(".."))
        XCTAssertFalse(FileRules.isValidEntryName("a/b"))
        XCTAssertFalse(FileRules.isValidEntryName("a\0b"))
        XCTAssertFalse(FileRules.isValidEntryName(String(repeating: "x", count: 256)))
    }

    func testUniqueNameDoesNotOverwrite() {
        XCTAssertEqual(FileRules.uniqueName("game.sh", existing: ["other.sh"]), "game.sh")
        XCTAssertEqual(FileRules.uniqueName("game.sh", existing: ["game.sh"]), "game 2.sh")
        XCTAssertEqual(FileRules.uniqueName("game.sh", existing: ["game.sh", "game 2.sh"]), "game 3.sh")
    }

    func testRuntimeFilesAreProtected() {
        XCTAssertTrue(FileRules.isProtected("/usr/local/bin/gamescope"))
        XCTAssertTrue(FileRules.isProtected("/usr/local/bin/gamescope/real"))
        XCTAssertFalse(FileRules.isProtected("/usr/local/bin/other"))
    }

    func testDeleteIsDestructiveAndRenameIsNot() {
        XCTAssertTrue(FileOperation.delete(paths: ["/a"]).isDestructive)
        XCTAssertTrue(FileOperation.move(paths: ["/a"], toDirectory: "/b").isDestructive)
        XCTAssertFalse(FileOperation.rename(path: "/a", to: "/b").isDestructive)
        XCTAssertFalse(FileOperation.createDirectory(path: "/a").isDestructive)
    }

    func testFormattedSize() {
        XCTAssertEqual(FileRules.formattedSize(512), "512 B")
        XCTAssertEqual(FileRules.formattedSize(2048), "2.0 KB")
        XCTAssertEqual(FileRules.formattedSize(3 * 1024 * 1024 * 1024), "3.0 GB")
    }
}