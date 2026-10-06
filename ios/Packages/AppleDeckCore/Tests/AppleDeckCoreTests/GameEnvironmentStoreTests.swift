// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AppleDeckCore

final class GameEnvironmentStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("game-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> GameEnvironmentStore {
        GameEnvironmentStore(url: directory.appendingPathComponent("files/game-environment.json"))
    }

    func testAMissingFileIsAnEmptyEnvironment() throws {
        XCTAssertEqual(try store().read(), GameEnvironment.Config())
    }

    func testRoundTrip() throws {
        let config = GameEnvironment.Config(shared: ["DXVK_HUD": "fps", "PROTON_LOG": nil],
                                            games: ["10": ["VKD3D_FRAME_RATE": "30"]])
        let store = self.store()
        try store.write(config)
        XCTAssertEqual(try store.read(), config)
    }

    func testTheVersionIsInsistedOn() throws {
        let data = Data(#"{"version":99,"shared":{}}"#.utf8)
        XCTAssertThrowsError(try GameEnvironmentStore.decode(data)) { error in
            XCTAssertEqual(error as? GameEnvironmentStore.StoreError,
                           .unsupportedVersion(99))
        }
    }

    func testAnInvalidNameIsAnErrorRatherThanADroppedEntry() throws {
        let data = Data(#"{"version":1,"shared":{"DXVK HUD":"fps"}}"#.utf8)
        XCTAssertThrowsError(try GameEnvironmentStore.decode(data)) { error in
            XCTAssertEqual(error as? GameEnvironmentStore.StoreError, .invalidName("DXVK HUD"))
        }
    }

    func testARuntimeManagedNameIsRefused() throws {
        let data = Data(#"{"version":1,"shared":{"WINEESYNC":"1"}}"#.utf8)
        XCTAssertThrowsError(try GameEnvironmentStore.decode(data)) { error in
            XCTAssertEqual(error as? GameEnvironmentStore.StoreError,
                           .runtimeManagedName("WINEESYNC"))
        }
    }

    func testAnInvalidScopeIsRefused() throws {
        let data = Data(#"{"version":1,"games":{"zero":{"DXVK_HUD":"fps"}}}"#.utf8)
        XCTAssertThrowsError(try GameEnvironmentStore.decode(data)) { error in
            XCTAssertEqual(error as? GameEnvironmentStore.StoreError, .invalidScope("zero"))
        }
    }

    func testAnOversizedValueIsRefused() throws {
        let big = String(repeating: "a", count: 8193)
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "shared": ["DXVK_CONFIG": big]
        ])
        XCTAssertThrowsError(try GameEnvironmentStore.decode(data))
    }

    func testAnExplicitNullSurvives() throws {
        let data = Data(#"{"version":1,"shared":{"PROTON_LOG":null}}"#.utf8)
        let config = try GameEnvironmentStore.decode(data)
        XCTAssertEqual(config.shared.count, 1)
        XCTAssertNil(config.shared["PROTON_LOG"] ?? "set")
        XCTAssertTrue(config.shared.keys.contains("PROTON_LOG"))
    }

    func testWritingLeavesNoFileBehindWhenCleared() throws {
        let store = self.store()
        try store.write(GameEnvironment.Config(shared: ["DXVK_HUD": "fps"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(try store.read(), GameEnvironment.Config())
    }

    func testTheWrittenFileIsReadableJSONWithItsVersion() throws {
        let store = self.store()
        try store.write(GameEnvironment.Config(shared: ["DXVK_HUD": "fps"]))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url))
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
    }

    func testTheStoreCreatesItsDirectory() throws {
        let store = GameEnvironmentStore(url: directory
            .appendingPathComponent("deep/deeper/game-environment.json"))
        try store.write(GameEnvironment.Config(shared: ["A": "1"]))
        XCTAssertEqual(try store.read().shared, ["A": "1"])
    }
}