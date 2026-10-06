// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AppleDeckCore

final class GameEnvironmentTests: XCTestCase {
    func testScopeIsTheSteamAppIdRange() {
        XCTAssertTrue(GameEnvironment.isValidScope(""))
        XCTAssertTrue(GameEnvironment.isValidScope("10"))
        XCTAssertTrue(GameEnvironment.isValidScope("4294967295"))
        XCTAssertFalse(GameEnvironment.isValidScope("0"))
        XCTAssertFalse(GameEnvironment.isValidScope("01"), "a leading zero is not an app id")
        XCTAssertFalse(GameEnvironment.isValidScope("4294967296"))
        XCTAssertFalse(GameEnvironment.isValidScope("-1"))
        XCTAssertFalse(GameEnvironment.isValidScope("abc"))
    }

    func testVariableNamesAreShellNames() {
        XCTAssertTrue(GameEnvironment.isValidName("DXVK_HUD"))
        XCTAssertTrue(GameEnvironment.isValidName("_private"))
        XCTAssertTrue(GameEnvironment.isValidName("A1"))
        XCTAssertFalse(GameEnvironment.isValidName(""))
        XCTAssertFalse(GameEnvironment.isValidName("1LEADING"))
        XCTAssertFalse(GameEnvironment.isValidName("HAS SPACE"))
        XCTAssertFalse(GameEnvironment.isValidName("HAS=EQUALS"))
        XCTAssertFalse(GameEnvironment.isValidName("PATH="))
    }

    func testValuesMayNotCarryANulOrRunPastEightKibibytes() {
        XCTAssertTrue(GameEnvironment.isValidValue(""))
        XCTAssertTrue(GameEnvironment.isValidValue("fps,devinfo"))
        XCTAssertFalse(GameEnvironment.isValidValue(String(repeating: "a", count: 8193)))
        XCTAssertTrue(GameEnvironment.isValidValue(String(repeating: "a", count: 8192)))
        XCTAssertFalse(GameEnvironment.isValidValue("a\u{0}b"))
    }

    func testRuntimeManagedNamesAreNotUserSettable() {
        XCTAssertFalse(GameEnvironment.isSupported("WINEESYNC"))
        XCTAssertFalse(GameEnvironment.isSupported("DXVK_GPLASYNCCACHE"))
        XCTAssertFalse(GameEnvironment.isSupported("BOX64_LD_PRELOAD"))
        XCTAssertFalse(GameEnvironment.isSupported("BOX86_LD_PRELOAD"))
        XCTAssertTrue(GameEnvironment.isSupported("DXVK_HUD"))
    }

    func testSharedEntriesAreNotAGameKeyedByEmptyString() {
        var config = GameEnvironment.Config()
        config = config.withEntries(scope: "", entries: ["DXVK_HUD": "fps"])
        XCTAssertEqual(config.entries(scope: ""), ["DXVK_HUD": "fps"])
        XCTAssertTrue(config.games.isEmpty, "the shared set is not stored as a game")
    }

    func testClearingAGamesEntriesRemovesTheScope() {
        var config = GameEnvironment.Config()
        config = config.withEntries(scope: "10", entries: ["DXVK_HUD": "fps"])
        XCTAssertNotNil(config.games["10"])
        config = config.withEntries(scope: "10", entries: [:])
        XCTAssertNil(config.games["10"])
    }

    func testEffectiveIsDefaultsThenSharedThenTheGame() {
        let config = GameEnvironment.Config(shared: ["DXVK_HUD": "devinfo",
                                                     "PROTON_LOG": "1"],
                                           games: ["10": ["DXVK_HUD": "fps"]])
        let effective = GameEnvironment.effective(config: config,
                                                  preset: "",
                                                  scope: "10")
        XCTAssertEqual(effective["DXVK_HUD"] ?? nil, "fps", "the game's own value wins")
        XCTAssertEqual(effective["PROTON_LOG"] ?? nil, "1")
        XCTAssertEqual(effective["VKD3D_FEATURE_LEVEL"] ?? nil, "12_2", "a default nobody set")
    }

    func testASharedEntryAppliesToAGameWithNothingOfItsOwn() {
        let config = GameEnvironment.Config(shared: ["DXVK_HUD": "devinfo"])
        let effective = GameEnvironment.effective(config: config, preset: "", scope: "570")
        XCTAssertEqual(effective["DXVK_HUD"] ?? nil, "devinfo")
    }

    func testAPresetContributesToTheDefaults() {
        let effective = GameEnvironment.effective(config: .init(),
                                                  preset: "PERFORMANCE",
                                                  scope: "10")
        XCTAssertEqual(effective["FEX_TSOENABLED"] ?? nil, "0")
        XCTAssertEqual(effective["FEX_MULTIBLOCK"] ?? nil, "1")
    }

    func testAStabilityPresetTurnsTheOptimisationsBackOn() {
        let effective = GameEnvironment.effective(config: .init(), preset: "STABILITY", scope: "")
        XCTAssertEqual(effective["FEX_TSOENABLED"] ?? nil, "1")
        XCTAssertEqual(effective["FEX_MULTIBLOCK"] ?? nil, "0")
    }

    func testAnUnknownPresetFallsBackToTheDefaultOne() {
        XCTAssertEqual(FexPreset.byId("NOPE").id, "")
        XCTAssertTrue(FexPreset.env(id: "NOPE").isEmpty)
    }

    func testConfigRoundTripsThroughJSON() throws {
        let config = GameEnvironment.Config(shared: ["DXVK_HUD": "fps"],
                                            games: ["10": ["PROTON_LOG": nil]])
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(GameEnvironment.Config.self, from: data), config)
    }
}

final class GameEnvironmentOptionsTests: XCTestCase {
    func testTheEditorOffersTheOptionsItShould() {
        XCTAssertEqual(GameEnvironmentOptions.find("DXVK_HUD")?.kind, .multiple)
        XCTAssertEqual(GameEnvironmentOptions.find("VKD3D_FRAME_RATE")?.kind, .number)
        XCTAssertEqual(GameEnvironmentOptions.find("DXVK_CONFIG")?.kind, .text)
        XCTAssertEqual(GameEnvironmentOptions.find("PROTON_LOG")?.kind, .toggle)
        XCTAssertNil(GameEnvironmentOptions.find("NOT_AN_OPTION"))
    }

    func testEveryOptionIsANameTheGuestWouldAccept() {
        for option in GameEnvironmentOptions.all {
            XCTAssertTrue(GameEnvironment.isValidName(option.name), option.name)
            XCTAssertTrue(GameEnvironment.isSupported(option.name),
                          "\(option.name) is managed by the runtime and cannot be offered")
            XCTAssertTrue(GameEnvironment.isValidValue(option.defaultValue), option.name)
        }
    }

    func testEveryChoiceIsOneTheGuestWouldAccept() {
        for option in GameEnvironmentOptions.all {
            for choice in option.choices {
                XCTAssertTrue(GameEnvironment.isValidValue(choice), "\(option.name): \(choice)")
            }
            if !option.choices.isEmpty {
                XCTAssertTrue(option.choices.contains(option.defaultValue),
                              "\(option.name) defaults to \(option.defaultValue), which is not among its choices")
            }
        }
    }

    func testTogglingAMultipleOptionIsOrderIndependent() throws {
        let option = try XCTUnwrap(GameEnvironmentOptions.find("DXVK_HUD"))
        let first = GameEnvironmentOptions.toggle(value: "", choice: "devinfo", in: option)
        let second = GameEnvironmentOptions.toggle(value: first, choice: "fps", in: option)
        let otherWay = GameEnvironmentOptions.toggle(value: "fps", choice: "devinfo", in: option)
        XCTAssertEqual(second, otherWay,
                       "the order the choices were picked in must not change the result")
    }

    func testTogglingTwiceRemovesTheChoice() throws {
        let option = try XCTUnwrap(GameEnvironmentOptions.find("GALLIUM_HUD"))
        let on = GameEnvironmentOptions.toggle(value: "simple", choice: "fps", in: option)
        // In the table's order, not the order they were tapped: that is what the
        // order-independence test above checks.
        XCTAssertEqual(on, "simple,fps")
        let off = GameEnvironmentOptions.toggle(value: on, choice: "fps", in: option)
        XCTAssertEqual(off, "simple")
    }

    func testAValueTheTableDoesNotKnowIsKept() throws {
        let option = try XCTUnwrap(GameEnvironmentOptions.find("DXVK_HUD"))
        let result = GameEnvironmentOptions.toggle(value: "somethingelse", choice: "fps", in: option)
        XCTAssertTrue(result.contains("somethingelse"),
                      "another version wrote it; dropping it would lose it silently")
        XCTAssertTrue(result.contains("fps"))
    }

    func testAnExplicitNullIsNotTheSameAsUnset() throws {
        let option = try XCTUnwrap(GameEnvironmentOptions.find("DXVK_CONFIG"))
        let fallbacks = ["DXVK_CONFIG": "dxvk.maxFrameRate = 60"]
        XCTAssertEqual(GameEnvironmentOptions.effectiveValue(for: option, in: [:], fallbacks: fallbacks),
                       "dxvk.maxFrameRate = 60")
        XCTAssertEqual(GameEnvironmentOptions.effectiveValue(for: option,
                                                             in: ["DXVK_CONFIG": nil],
                                                             fallbacks: fallbacks),
                       "", "set to nothing is not the same as never set")
    }
}