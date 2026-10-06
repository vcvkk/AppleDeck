// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AppleDeckCore

final class GameSavesTests: XCTestCase {
    private struct FakeFiles: SavesReader.FileSystem {
        var directories: Set<String> = []
        var sizes: [String: Int64] = [:]
        var archived: (paths: [String], destination: String, layout: GameSaves.Layout)?
        var archiveResult: Result<(path: String, files: Int), Error> = .success(("/out.zip", 3))
        var failWith: Error?

        func exists(_ path: String) -> Bool { directories.contains(path) || sizes[path] != nil }
        func isDirectory(_ path: String) -> Bool { directories.contains(path) }
        func size(ofTreeAt path: String) -> Int64? { sizes[path] }
        func modified(at path: String) -> Date? { Date(timeIntervalSince1970: 1_700_000_000) }
        func entries(in path: String) -> [String]? { [] }

        func archive(paths roots: [String], to destination: String, layout: GameSaves.Layout) throws -> (path: String, files: Int) {
            archived = (roots, destination, layout)
            if let failWith { throw failWith }
            return try archiveResult.get()
        }
    }

    private var files = FakeFiles()
    private var reader: SavesReader { SavesReader(files: files, exportsRoot: "/Documents/DroidDeck/Saves") }

    private let prefix = "/root/.local/share/Steam/steamapps/compatdata/1245620/pfx/drive_c"

    func testFindsOnlyTheDirectoriesThatExist() {
        files.directories = ["\(prefix)/users/steamuser/Documents", "\(prefix)/users/steamuser/AppData"]
        files.sizes = ["\(prefix)/users/steamuser/Documents": 4096,
                       "\(prefix)/users/steamuser/AppData": 1024]
        var game = GameSaves.makeGame(id: "1245620", name: "ELDEN RING", protonPrefix: prefix)
        game = reader.locate(game: game)
        XCTAssertEqual(game.directories.count, 2)
        XCTAssertEqual(game.totalBytes, 5120)
        XCTAssertTrue(game.hasSaves)
    }

    func testAGameThatHasNeverRunHasNoDirectories() {
        var game = GameSaves.makeGame(id: "10", name: "Counter-Strike", protonPrefix: prefix)
        game = reader.locate(game: game)
        XCTAssertTrue(game.directories.isEmpty)
        XCTAssertFalse(game.hasSaves)
    }

    func testAGameWithNoProtonPrefixIsLeftAlone() {
        var game = GameSaves.makeGame(id: "10", name: "Counter-Strike", protonPrefix: nil)
        game = reader.locate(game: game)
        XCTAssertTrue(game.directories.isEmpty)
    }

    func testExportNameIsSafeAndSorts() {
        let game = GameSaves.makeGame(id: "1", name: "Half-Life: Episode / Two?", protonPrefix: prefix)
        let first = SavesReader.exportName(for: game, at: Date(timeIntervalSince1970: 1_700_000_000))
        let second = SavesReader.exportName(for: game, at: Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertTrue(first.hasSuffix(".zip"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains("?"))
        XCTAssertNotEqual(first, second)
        // Fixed width, so a directory listing sorts by time.
        XCTAssertEqual(first.filter { $0.isNumber }.count, second.filter { $0.isNumber }.count)
    }

    func testSafeNameNeverEmptyAndNeverLong() {
        XCTAssertEqual(SavesReader.safeName("///"), "___")
        XCTAssertEqual(SavesReader.safeName("   "), "game")
        XCTAssertEqual(SavesReader.safeName(""), "game")
        XCTAssertLessThanOrEqual(SavesReader.safeName(String(repeating: "x", count: 500)).count, 80)
    }

    func testExportOfTheWholeProfileExportsThePrefix() throws {
        files.directories = ["\(prefix)/users/steamuser/Documents"]
        files.sizes = ["\(prefix)/users/steamuser/Documents": 10]
        var game = GameSaves.makeGame(id: "1", name: "Game", protonPrefix: prefix)
        game = reader.locate(game: game)
        let result = try reader.export(game: game, layout: .profile, at: Date())
        XCTAssertEqual(files.archived?.paths, [prefix])
        XCTAssertEqual(files.archived?.layout, .profile)
        XCTAssertTrue(files.archived?.destination.contains("/Documents/DroidDeck/Saves/") == true)
        XCTAssertEqual(result.files, 3)
    }

    func testExportOfOnlyTheGameFoldersExportsThose() throws {
        files.directories = ["\(prefix)/users/steamuser/Documents"]
        files.sizes = ["\(prefix)/users/steamuser/Documents": 10]
        var game = GameSaves.makeGame(id: "1", name: "Game", protonPrefix: prefix)
        game = reader.locate(game: game)
        _ = try reader.export(game: game, layout: .directories, at: Date())
        XCTAssertEqual(files.archived?.paths, ["\(prefix)/users/steamuser/Documents"])
    }

    func testExportWithoutAProtonPrefixExplainsItself() {
        let game = GameSaves.makeGame(id: "1", name: "Game", protonPrefix: nil)
        XCTAssertThrowsError(try reader.export(game: game, layout: .profile, at: Date())) { error in
            guard let error = error as? SavesReader.SavesError else {
                return XCTFail("wrong error type: \(error)")
            }
            XCTAssertEqual(error, .noProtonPrefix("Game"))
            XCTAssertTrue(error.message.contains("Proton prefix"))
        }
    }

    func testExportOfAGameWithNoSavesExplainsItself() {
        let game = GameSaves.makeGame(id: "1", name: "Game", protonPrefix: prefix)
        XCTAssertThrowsError(try reader.export(game: game, layout: .directories, at: Date())) { error in
            XCTAssertEqual(error as? SavesReader.SavesError, .nothingToExport("Game"))
        }
    }

    func testSizeIsFormattedTheWayTheFilesScreenDoesIt() {
        XCTAssertEqual(GameSaves.SaveDir(path: "/a", bytes: 2048, modified: nil).size, "2.0 KB")
    }
}