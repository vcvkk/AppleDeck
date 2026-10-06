// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The game environment: the variables a game is launched with, and the rules
/// for which ones may be set.
///
/// The environment is per-scope - shared for every game, or one Steam app id -
/// and what a game actually sees is defaults, then shared, then its own. Getting
/// that order wrong is the kind of thing that shows up as "my setting does
/// nothing", so it is here as a function with tests rather than as a spread
/// across a launcher.
///
/// Reimplemented from DroidDeck's behaviour rather than copied: `ios/` is
/// GPL-2.0-or-later because it links QEMU, and upstream is GPL-3.0. See
/// docs/ios-port.md, "Why nothing is copied".
public enum GameEnvironment {
    /// What the user has set: shared entries, and entries per Steam app id.
    public struct Config: Codable, Equatable, Sendable {
        public var shared: [String: String?]
        public var games: [String: [String: String?]]

        public init(shared: [String: String?] = [:], games: [String: [String: String?]] = [:]) {
            self.shared = shared
            self.games = games
        }

        /// The entries for a scope. An empty scope is the shared set, which is
        /// why it is not just a key: `""` means "everything", and looking it up
        /// like any other app id would silently hide every shared entry.
        public func entries(scope: String) -> [String: String?] {
            scope.isEmpty ? shared : (games[scope] ?? [:])
        }

        public func withEntries(scope: String, entries: [String: String?]) -> Config {
            if scope.isEmpty {
                return Config(shared: entries, games: games)
            }
            var games = self.games
            if entries.isEmpty {
                games.removeValue(forKey: scope)
            } else {
                games[scope] = entries
            }
            return Config(shared: shared, games: games)
        }
    }

    // MARK: - Validation

    /// A shell-style variable name: a letter or underscore, then letters, digits
    /// and underscores. The guest's start scripts read these out of an
    /// environment, so anything else would be a variable nothing looks at.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.utf8.first else { return false }
        guard first == UInt8(ascii: "_") || (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        return name.utf8.dropFirst().allSatisfy { byte in
            byte == UInt8(ascii: "_") || (48...57).contains(byte)
                || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    /// Names the runtime sets for itself and that a user must not override.
    ///
    /// Every one of these belongs to the shims `tools/linuxfs/preload` installs;
    /// changing them does not tune anything, it stops the guest's own
    /// infrastructure from working, and the symptom is a session that starts and
    /// then does nothing.
    public static let managedByTheRuntime: Set<String> = [
        "WINEESYNC", "WINENTSYNC", "WINE_FAST_YIELD", "WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER",
        "WINE_NEW_MEDIASOURCE", "WRAPPER_MAX_IMAGE_COUNT", "WRAPPER_DMAHEAP_CACHED",
        "ALSA_LATENCY_MS", "ALSA_VOLUME", "ALSA_BASS_BOOST", "ALSA_PERFORMANCE_MODE",
        "DXVK_ASYNC", "DXVK_GPLASYNCCACHE"
    ]

    public static func isSupported(_ name: String) -> Bool {
        !managedByTheRuntime.contains(name)
            && !name.hasPrefix("BOX64_") && !name.hasPrefix("BOX86_")
    }

    /// Values reach the guest as one environment entry, so a NUL would end the
    /// string early in the shims rather than in the guest, and 8 KiB is the
    /// ceiling Linux itself imposes.
    public static func isValidValue(_ value: String) -> Bool {
        // range(of:) rather than utf8.contains: the byte view's `contains` does
        // not resolve the same way in swift-corelibs as it does in Apple's SDK,
        // and a value check that only compiles on one of them is a value check
        // that only runs on one of them.
        value.range(of: "\0") == nil && value.utf8.count <= 8192
    }

    /// A scope is a Steam app id: 1 through 4294967295, no leading zero. The
    /// range is not decoration - it is the width of the id the client stores.
    public static func isValidScope(_ scope: String) -> Bool {
        if scope.isEmpty { return true }
        // unicodeScalars, not Characters: the range is over bytes, and a range of
        // UInt8 asked about a Character does not compile.
        let scalars = scope.unicodeScalars
        guard let first = scalars.first, (49...57).contains(first.value) else { return false }
        guard scalars.allSatisfy({ (48...57).contains($0.value) }) else { return false }
        guard let value = UInt64(scope) else { return false }
        return value >= 1 && value <= 4_294_967_295
    }

    // MARK: - Defaults

    /// The values a session starts from before anything the user has set.
    ///
    /// Three Mesa/VKD3D values and whatever the FEX preset adds. They are here
    /// rather than in the runtime because they are what the runtime's own start
    /// script sets when the environment is empty: a session that gets its
    /// defaults from the preset alone would run the guest's defaults, not these.
    public static func defaults(preset: String) -> [String: String?] {
        var out: [String: String?] = [
            "MESA_SHADER_CACHE_DISABLE": "false",
            "VKD3D_FEATURE_LEVEL": "12_2",
            "VKD3D_SHADER_MODEL": "6_9"
        ]
        for entry in FexPreset.env(id: preset) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            out[String(entry[entry.startIndex..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return out
    }

    /// What a game in `scope` is launched with: defaults, then the shared set,
    /// then the game's own. Later wins, which is what makes a per-game setting
    /// override a shared one without having to unset it first.
    public static func effective(config: Config, preset: String, scope: String) -> [String: String?] {
        var out = defaults(preset: preset)
        for (name, value) in config.shared { out[name] = value }
        if !scope.isEmpty {
            for (name, value) in config.games[scope] ?? [:] { out[name] = value }
        }
        return out
    }
}

/// FEX presets, for the translation layer the guest's Proton run uses.
///
/// The variables are facts about FEX, not design: what differs between the
/// presets is which one turns its optimisations off.
public enum FexPreset {
    public struct Preset: Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String
        public var env: [String]

        public init(id: String, label: String, detail: String, env: [String]) {
            self.id = id
            self.label = label
            self.detail = detail
            self.env = env
        }
    }

    private static func tso(_ main: Int, _ vector: Int, _ memcpy: Int, _ barrier: Int) -> [String] {
        ["FEX_TSOENABLED=\(main)", "FEX_VECTORTSOENABLED=\(vector)",
         "FEX_MEMCPYSETTSOENABLED=\(memcpy)", "FEX_HALFBARRIERTSOENABLED=\(barrier)"]
    }

    public static let all: [Preset] = [
        Preset(id: "", label: "Default", detail: "The runtime's own settings",
               env: []),
        Preset(id: "STABILITY", label: "Stability", detail: "Everything on, nothing speculative",
               env: tso(1, 1, 1, 1) + ["FEX_X87REDUCEDPRECISION=0", "FEX_MULTIBLOCK=0"]),
        Preset(id: "COMPATIBILITY", label: "Compatibility", detail: "Conservative, multiblock on",
               env: tso(1, 1, 1, 1) + ["FEX_X87REDUCEDPRECISION=0", "FEX_MULTIBLOCK=1"]),
        Preset(id: "INTERMEDIATE", label: "Intermediate", detail: "Some optimisations off",
               env: tso(1, 0, 0, 1) + ["FEX_X87REDUCEDPRECISION=1", "FEX_MULTIBLOCK=1"]),
        Preset(id: "PERFORMANCE", label: "Performance", detail: "Optimisations on",
               env: tso(0, 0, 0, 0) + ["FEX_X87REDUCEDPRECISION=1", "FEX_MULTIBLOCK=1"]),
        Preset(id: "PERFORMANCE_TSO", label: "Performance (TSO)", detail: "TSO on, the rest off",
               env: tso(1, 0, 0, 0) + ["FEX_X87REDUCEDPRECISION=1", "FEX_MULTIBLOCK=1"]),
        Preset(id: "EXTREME", label: "Extreme", detail: "Caches off, checks off",
               env: tso(0, 0, 0, 0) + ["FEX_X87REDUCEDPRECISION=1", "FEX_MULTIBLOCK=1",
                                        "FEX_SMCCHECKS=none", "FEX_DISABLEL2CACHE=1",
                                        "FEX_DYNAMICL1CACHE=1",
                                        "FEX_DYNAMICL1CACHEINCREASECOUNTHEURISTIC=250",
                                        "FEX_DYNAMICL1CACHEDECREASECOUNTHEURISTIC=50"]),
        Preset(id: "EXTREME_TSO", label: "Extreme (TSO)", detail: "As extreme, with TSO on",
               env: tso(1, 0, 0, 0) + ["FEX_X87REDUCEDPRECISION=1", "FEX_MULTIBLOCK=1",
                                        "FEX_SMCCHECKS=none", "FEX_DISABLEL2CACHE=1",
                                        "FEX_DYNAMICL1CACHE=1",
                                        "FEX_DYNAMICL1CACHEINCREASECOUNTHEURISTIC=250",
                                        "FEX_DYNAMICL1CACHEDECREASECOUNTHEURISTIC=50"]),
        Preset(id: "EXTREME_GN", label: "Extreme (guest notices)", detail: "For guests that read the CPU",
               env: tso(0, 0, 0, 0) + ["FEX_X87REDUCEDPRECISION=1", "FEX_MULTIBLOCK=1",
                                        "FEX_SMALLTSCSCALE=1", "FEX_VOLATILEMETADATA=1"]),
        Preset(id: "DENUVO", label: "Anti-DRM", detail: "Stops the guest hiding behind a hypervisor bit",
               env: tso(0, 0, 0, 0) + ["FEX_X87REDUCEDPRECISION=1", "FEX_MULTIBLOCK=1",
                                        "FEX_SMCCHECKS=full", "FEX_HIDEHYPERVISORBIT=1"])
    ]

    public static func byId(_ id: String) -> Preset {
        all.first { $0.id == id } ?? all[0]
    }

    /// The preset's variables in `KEY=VALUE` form, the way the guest's start
    /// script expects them.
    public static func env(id: String) -> [String] {
        byId(id).env
    }
}