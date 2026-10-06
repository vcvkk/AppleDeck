// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Everything the settings UI can change, with the key names and defaults
/// DroidDeck uses.
///
/// The keys are the contract, not the labels: a DroidDeck user who migrates
/// brings a config file (or a support request quoting a key), and the values
/// mean the same thing on both platforms because the *guest* is the same
/// runtime. A key added here that does not exist upstream is a deliberate
/// AppleDeck addition and says so in its comment; anything ported keeps the
/// upstream spelling exactly, including the ones that are only a prefix
/// (`linuxDriver.<mode>`).
///
/// Storage is a protocol rather than `UserDefaults` so the whole schema can be
/// exercised by `swift test` on a runner that has no iOS in it.
public protocol PrefsStore: AnyObject {
    func bool(forKey key: String) -> Bool?
    func setBool(_ value: Bool, forKey key: String)
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func double(forKey key: String) -> Double?
    func setDouble(_ value: Double, forKey key: String)
    func remove(forKey key: String)
}

/// An in-memory store, used by tests and by the guest-image inspector.
public final class MemoryPrefsStore: PrefsStore {
    private var values: [String: Any] = [:]

    public init(_ initial: [String: Any] = [:]) { values = initial }

    public func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    public func setBool(_ value: Bool, forKey key: String) { values[key] = value }
    public func string(forKey key: String) -> String? { values[key] as? String }
    public func setString(_ value: String, forKey key: String) { values[key] = value }
    public func double(forKey key: String) -> Double? { values[key] as? Double }
    public func setDouble(_ value: Double, forKey key: String) { values[key] = value }
    public func remove(forKey key: String) { values.removeValue(forKey: key) }
}

/// `session/SessionPrefs.kt`, in Swift. One property per key, so that a typo is
/// a compile error rather than a preference that silently never applies.
public final class Prefs: @unchecked Sendable {
    /// Upstream's SharedPreferences file name. AppleDeck keeps it so a
    /// preferences dump taken from an Android device can be replayed here.
    public static let storeName = "session"

    private let store: PrefsStore

    public init(store: PrefsStore) { self.store = store }

    // MARK: - Launcher

    /// Whether the launcher hides the status and navigation bars. On iOS the
    /// equivalent is whether the session view covers the safe area, which is
    /// always true: there is no status bar to hide.
    public var launcherFullscreen: Bool { get { bool("launcherFullscreen", true) } set { set(newValue, "launcherFullscreen") } }

    /// The Flathub Store (beta), its rail item and the Store's apps on the
    /// Desktop page.
    public var storeEnabled: Bool { get { bool("storeEnabled", false) } set { set(newValue, "storeEnabled") } }

    /// AppImage import (beta): the AppImages section on the Desktop page.
    public var appImagesEnabled: Bool { get { bool("appImagesEnabled", false) } set { set(newValue, "appImagesEnabled") } }

    /// Whether session logs are kept after the session ends. Upstream writes
    /// them to `Download/DroidDeck/`; on iOS there is no shared Downloads
    /// directory an app may write, so they go in Documents and are exposed
    /// through the Files screen and the iOS share sheet.
    public var logsEnabled: Bool { get { bool("logs", true) } set { set(newValue, "logs") } }

    /// Graphite by default, matching upstream. iOS enforces dark mode itself, so
    /// this only picks the launcher's own palette.
    public var theme: String { get { string("theme", "graphite") } set { set(newValue, "theme") } }

    /// The microphone switch for the Steam client's voice chat. iOS needs the
    /// permission granted as well, which is why `micAsked` exists upstream and
    /// exists here.
    public var microphoneEnabled: Bool { get { bool("mic", false) } set { set(newValue, "mic") } }
    public var microphoneAsked: Bool { get { bool("micAsked", false) } set { set(newValue, "micAsked") } }

    // MARK: - Session

    /// The in-session HUD.
    public var hud: Bool { get { bool("hud", true) } set { set(newValue, "hud") } }

    /// When on, a single Back opens Steam QAM and a double Back opens the
    /// session menu. AppleDeck keeps the preference and inverts it onto the
    /// hardware Back gesture and the Game Controller's B button, which is what
    /// a phone user reaches for.
    public var backActionsInverted: Bool { get { bool("backActionsInverted", false) } set { set(newValue, "backActionsInverted") } }

    /// How touch drives the pointer: a touchpad (drag moves it from where it is)
    /// or direct (it jumps under the finger). `auto` is a touchpad on the
    /// desktop and direct in Steam.
    public var touchMode: TouchMode { get { TouchMode(rawValue: string("touch", TouchMode.auto.rawValue)) ?? .auto }
                                     set { set(newValue.rawValue, "touch") } }

    /// The shape of the display the session presents. Upstream's three choices
    /// map onto iOS as: the panel's own shape (Auto), the panel's shape with no
    /// letterbox (`exact`), and a fixed 16:9 (`wide`). iPhone screens are
    /// portrait, so `wide` is the one that behaves like a Steam Deck's 16:9 and
    /// is what a session starts in unless the user says otherwise.
    public var shapeMode: ShapeMode { get { ShapeMode(rawValue: string("shape", ShapeMode.wide.rawValue)) ?? .wide }
                                      set { set(newValue.rawValue, "shape") } }

    /// When the on-screen controls appear.
    public var oscMode: OnScreenControlMode { get { OnScreenControlMode(rawValue: string("osc", OnScreenControlMode.auto.rawValue)) ?? .auto }
                                               set { set(newValue.rawValue, "osc") } }

    /// Which controller profile the session presents.
    public var controllerProfile: ControllerProfile { get { ControllerProfile(rawValue: string("steamController", ControllerProfile.deck.rawValue)) ?? .deck }
                                                     set { set(newValue.rawValue, "steamController") } }

    /// Steam only: gamescope makes every game window the size of the screen.
    public var forceFullscreen: Bool { get { bool("forceFullscreen", true) } set { set(newValue, "forceFullscreen") } }

    /// The Steam client's own sound through the DirectAudio relay instead of
    /// the classic sink. On iOS the relay is the only sink that can reach the
    /// device, so this defaults on here and off upstream — see
    /// `Docs/Audio.md` for why the classic sink cannot work at all on iOS.
    public var clientDirectAudio: Bool { get { bool("clientDirectAudio", true) } set { set(newValue, "clientDirectAudio") } }

    /// The audio sink in general. Always true on iOS: there is no AAudio.
    public var directAudio: Bool { get { bool("directAudio", true) } set { set(newValue, "directAudio") } }

    /// Suspending when the app leaves the foreground: `auto` (only while the
    /// session is in front), `manual` (never), `never` (never, and the session
    /// keeps running).
    public var suspendMode: SuspendMode { get { SuspendMode(rawValue: string("suspend", SuspendMode.auto.rawValue)) ?? .auto }
                                         set { set(newValue.rawValue, "suspend") } }

    /// The guest's hostname. On iOS this is `AppleDeck` by default: Linux 6.x
    /// refuses to start without one and upstream sets it from the Android build
    /// so Steam sees a stable machine name.
    public var guestHostname: String { get { string("guestHostname", "AppleDeck") } set { set(newValue, "guestHostname") } }

    /// Which Steam channel the client runs: `steam`, `steamdeck` or `beta`.
    public var steamChannel: String { get { string("steamChannel", "steam") } set { set(newValue, "steamChannel") } }

    /// The desktop renderer: `vulkan` or `gl` (labwc with the software or the
    /// llvmpipe path). Mirrors `desktopRenderer`.
    public var desktopRenderer: String { get { string("desktopRenderer", "vulkan") } set { set(newValue, "desktopRenderer") } }

    /// The imported glibc Turnip for a mode, keyed `linuxDriver.<mode>`, `""`
    /// being the driver built into the runtime.
    public func linuxDriver(mode: SessionMode) -> String {
        string("linuxDriver.\(mode.rawValue)", "")
    }

    public func setLinuxDriver(_ id: String, mode: SessionMode) {
        set(id, "linuxDriver.\(mode.rawValue)")
    }

    /// The Android driver import (upstream only, on Android). Present so a
    /// settings dump round-trips; it has no effect on iOS.
    public var androidDriver: String { get { string("androidDriver", "") } set { set(newValue, "androidDriver") } }

    // MARK: - CPU and memory

    public var clientCores: String { get { string("clientCpus", "") } set { set(newValue, "clientCpus") } }
    public var gameCores: String { get { string("gameCpus", "") } set { set(newValue, "gameCpus") } }
    public var clientCoresOverride: String { get { string("clientCpusOverride", "") } set { set(newValue, "clientCpusOverride") } }

    /// Android's per-process heap cap, upstream. iOS has no equivalent knob:
    /// the guest is given what it asks for and the jetsam limit is the only
    /// ceiling, so this is stored and never read.
    public var tuSysmem: Bool { get { bool("tuSysmem", true) } set { set(newValue, "tuSysmem") } }
    public var noXalia: Bool { get { bool("noXalia", true) } set { set(newValue, "noXalia") } }
    public var glThread: Bool { get { bool("glThread", true) } set { set(newValue, "glThread") } }
    public var noGlError: Bool { get { bool("noGlError", true) } set { set(newValue, "noGlError") } }
    public var zinkLazy: Bool { get { bool("zinkLazy", true) } set { set(newValue, "zinkLazy") } }
    public var gamescopeRealtime: Bool { get { bool("gamescopeRealtime", false) } set { set(newValue, "gamescopeRealtime") } }
    public var prootNoSeccomp: Bool { get { bool("prootNoSeccomp", false) } set { set(newValue, "prootNoSeccomp") } }
    public var steamDeckMode: Bool { get { bool("steamDeckMode", false) } set { set(newValue, "steamDeckMode") } }

    // MARK: - Library

    /// Where imported games and artwork live. Upstream defaults to empty and
    /// resolves it against external storage; on iOS the default is the
    /// app's Documents directory, set at first launch.
    public var addedGamesDir: String { get { string("addedGamesDir", "") } set { set(newValue, "addedGamesDir") } }
    public var addedGamesArt: Bool { get { bool("addedGamesArt", true) } set { set(newValue, "addedGamesArt") } }
    public var romsDir: String { get { string("romsDir", "") } set { set(newValue, "romsDir") } }
    public var gameStorage: String { get { string("gameStorage", "") } set { set(newValue, "gameStorage") } }
    public var gameStorageLabel: String { get { string("gameStorageLabel", "On My iPhone") } set { set(newValue, "gameStorageLabel") } }

    // MARK: - Computed

    /// The order Back and its double-tap act in, as upstream's settings
    /// screens spell it: "1: menu 2: QAM" or "1: QAM 2: menu".
    public var backActionsOrder: String {
        backActionsInverted ? ControllerProfile.backQAMThenMenu : ControllerProfile.backMenuThenQAM
    }

    /// The pointer mode for a session that is running `mode`, applying `auto`.
    public func effectiveTouchMode(for mode: SessionMode) -> TouchMode {
        switch touchMode {
        case .auto: return mode == .desktop ? .touchpad : .direct
        case .touchpad, .direct: return touchMode
        }
    }

    /// Whether the on-screen controls belong on screen for a session running
    /// `mode`, applying `auto` and the Steam QAM case.
    public func onScreenControlsVisible(for mode: SessionMode, steamQAMOpen: Bool) -> Bool {
        switch oscMode {
        case .always: return true
        case .never: return false
        case .auto: return mode == .desktop || steamQAMOpen
        case .steamQAM: return steamQAMOpen
        }
    }

    // MARK: - Primitives

    /// A raw string value, for the keys the port added: the FEX preset and
    /// anything else that is not a typed setting on the screen.
    public func text(_ key: String, default fallback: String) -> String {
        string(key, fallback)
    }

    public func text2(_ key: String, _ value: String) {
        set(value, key)
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        store.bool(forKey: key) ?? fallback
    }

    private func string(_ key: String, _ fallback: String) -> String {
        store.string(forKey: key) ?? fallback
    }

    private func set(_ value: Bool, _ key: String) { store.setBool(value, forKey: key) }
    private func set(_ value: String, _ key: String) { store.setString(value, forKey: key) }
    private func set(_ value: Double, _ key: String) { store.setDouble(value, forKey: key) }
}

// MARK: - Enumerations

public enum TouchMode: String, Codable, CaseIterable, Sendable {
    case auto
    case touchpad
    case direct
}

public enum ShapeMode: String, Codable, CaseIterable, Sendable {
    case auto
    /// Match the screen exactly, with no letterbox.
    case exact
    case wide = "16:9"
}

public enum OnScreenControlMode: String, Codable, CaseIterable, Sendable {
    case auto
    case always
    case steamQAM = "steam-qam"
    case never
}

public enum ControllerProfile: String, Codable, CaseIterable, Sendable {
    case deck
    case xbox360

    public static let backMenuThenQAM = "1: menu 2: QAM"
    public static let backQAMThenMenu = "1: QAM 2: menu"
}

public enum SuspendMode: String, Codable, CaseIterable, Sendable {
    case auto
    case manual
    case never
}