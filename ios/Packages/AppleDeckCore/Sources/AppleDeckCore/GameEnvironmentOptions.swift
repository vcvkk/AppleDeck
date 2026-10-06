// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The options the game environment editor offers, and how each is edited.
///
/// A table rather than a screen: what each option is (its name, its default, its
/// choices, whether it takes several) is data the editor renders and the tests
/// check, and it is the same data on every platform the runtime runs on.
public enum GameEnvironmentOptions {
    public enum Kind: String, Sendable {
        /// One of two values.
        case toggle
        /// Exactly one of the choices.
        case choice
        /// Any number of the choices, comma separated.
        case multiple
        /// A number.
        case number
        /// Free text.
        case text
    }

    public struct Option: Equatable, Sendable, Identifiable {
        public var name: String
        public var defaultValue: String
        public var title: String
        public var detail: String
        public var kind: Kind
        public var choices: [String]

        public var id: String { name }

        public init(name: String,
                    defaultValue: String,
                    title: String,
                    detail: String = "",
                    kind: Kind,
                    choices: [String] = []) {
            self.name = name
            self.defaultValue = defaultValue
            self.title = title
            self.detail = detail
            self.kind = kind
            self.choices = choices
        }
    }

    public static let all: [Option] = [
        Option(name: "MESA_SHADER_CACHE_DISABLE", defaultValue: "false",
               title: "Shader cache", detail: "Turn it off when a game draws the wrong shaders",
               kind: .toggle, choices: ["false", "true"]),
        Option(name: "VKD3D_FEATURE_LEVEL", defaultValue: "12_2",
               title: "Feature level", kind: .choice,
               choices: ["12_2", "12_1", "12_0", "11_1", "11_0"]),
        Option(name: "VKD3D_SHADER_MODEL", defaultValue: "6_9",
               title: "Shader model", kind: .choice,
               choices: ["6_9", "6_8", "6_7", "6_6", "6_5", "6_4", "6_3", "6_2", "6_1", "6_0", "5_1"]),
        Option(name: "VKD3D_CONFIG", defaultValue: "nodxr",
               title: "VKD3D configuration", kind: .multiple,
               choices: ["nodxr", "single_queue", "no_upload_hvv"]),
        Option(name: "MESA_SHADER_CACHE_MAX_SIZE", defaultValue: "1G",
               title: "Shader cache size", kind: .choice,
               choices: ["512M", "1G", "2G", "4G"]),
        Option(name: "PROTON_LOG", defaultValue: "1",
               title: "Proton log", detail: "Writes the client's log where the session can find it",
               kind: .toggle, choices: ["0", "1"]),
        Option(name: "PROTON_USE_WINED3D", defaultValue: "1",
               title: "WineD3D", detail: "Wined3D instead of vkd3d-proton",
               kind: .toggle, choices: ["0", "1"]),
        Option(name: "PROTON_USE_XALIA", defaultValue: "0",
               title: "Xalia overlay", detail: "Wine's own overlay; usually in the way",
               kind: .toggle, choices: ["0", "1"]),
        Option(name: "DXVK_HUD", defaultValue: "fps",
               title: "DXVK HUD", kind: .multiple,
               choices: ["scale=0.5", "scale=0.7", "opacity=0.5", "opacity=0.7", "devinfo",
                         "fps", "frametimes", "submissions", "drawcalls", "pipelines",
                         "descriptors", "memory", "gpuload", "version", "api", "cs",
                         "compiler", "samplers"]),
        Option(name: "DXVK_CONFIG", defaultValue: "dxvk.maxFrameRate = 60",
               title: "DXVK configuration", detail: "Free text, in dxvk.conf syntax",
               kind: .text),
        Option(name: "VKD3D_FRAME_RATE", defaultValue: "60",
               title: "Frame rate limit", kind: .number),
        Option(name: "mesa_glthread", defaultValue: "true",
               title: "Mesa glthread", kind: .toggle, choices: ["false", "true"]),
        Option(name: "ZINK_DESCRIPTORS", defaultValue: "auto",
               title: "Zink descriptors", kind: .choice,
               choices: ["auto", "lazy", "cached", "notemplates"]),
        Option(name: "ZINK_DEBUG", defaultValue: "nir",
               title: "Zink debug", kind: .multiple,
               choices: ["nir", "spirv", "tgsi", "validation", "sync", "compact", "noreorder"]),
        Option(name: "SteamDeck", defaultValue: "0",
               title: "Present as a Steam Deck", kind: .toggle, choices: ["0", "1"]),
        Option(name: "FD_DEV_FEATURES", defaultValue: "enable_tp_ubwc_flag_hint=1",
               title: "Frenzy driver features", kind: .multiple,
               choices: ["enable_tp_ubwc_flag_hint=1", "storage_8bit=1"]),
        Option(name: "TU_DEBUG", defaultValue: "forcecb",
               title: "Frenzy driver debug", kind: .multiple,
               choices: ["forcecb", "nocb", "startup", "deck_emu", "nir", "nobin", "sysmem",
                         "gmem", "forcebin", "layout", "noubwc", "nomultipos", "nolrz",
                         "nolrzfc", "perf", "perfc", "flushall", "syncdraw",
                         "push_consts_per_stage", "rast_order", "unaligned_store",
                         "log_skip_gmem_ops", "dynamic", "bos", "3d_load", "fdm",
                         "noconform", "rd"]),
        Option(name: "IR3_SHADER_DEBUG", defaultValue: "nouboopt",
               title: "Shader debug", kind: .multiple,
               choices: ["nouboopt", "nopreamble", "noearlypreamble"]),
        Option(name: "MESA_EXTENSION_MAX_YEAR", defaultValue: "",
               title: "Extension year ceiling", kind: .text),
        Option(name: "MESA_GL_VERSION_OVERRIDE", defaultValue: "",
               title: "GL version override", kind: .text),
        Option(name: "PULSE_LATENCY_MSEC", defaultValue: "",
               title: "Audio latency (ms)", kind: .number),
        Option(name: "WINE_LARGE_ADDRESS_AWARE", defaultValue: "0",
               title: "Large address aware", kind: .toggle, choices: ["0", "1"]),
        Option(name: "WINEDLLOVERRIDES", defaultValue: "",
               title: "DLL overrides", detail: "Comma separated, as Wine reads it",
               kind: .text),
        Option(name: "GALLIUM_HUD", defaultValue: "simple",
               title: "Gallium HUD", kind: .multiple,
               choices: ["simple", "fps", "frametime"])
    ]

    public static func find(_ name: String) -> Option? {
        all.first { $0.name == name }
    }

    /// Adds or removes one choice from a multiple option's value.
    ///
    /// Order is kept in the order the options list its choices, not the order
    /// they were picked in, so `DXVK_HUD=fps,devinfo` does not depend on which
    /// order the user tapped them. A set of strings does not have that property.
    public static func toggle(value: String, choice: String, in option: Option) -> String {
        let selected = Set(value.split(separator: ",").map(String.init))
        var result = selected
        if result.contains(choice) {
            result.remove(choice)
        } else {
            result.insert(choice)
        }
        let ordered = option.choices.filter { result.contains($0) }
        // A value the table does not know about is kept: the editor is not the
        // only thing that can write this file, and dropping an entry another
        // version wrote would lose it silently.
        let unknown = result.subtracting(option.choices).sorted()
        return (ordered + unknown).joined(separator: ",")
    }

    /// The value the editor shows for an option that has never been set.
    public static func effectiveValue(for option: Option,
                                     in entries: [String: String?],
                                     fallbacks: [String: String?]) -> String {
        if let value = entries[option.name] {
            // An explicit null means "no value", which is different from unset.
            guard let value else { return "" }
            return value
        }
        // `defaults` holds [String: String?] because "set to nothing" is a value
        // the editor distinguishes, so the lookup is String?? and ?? flattens only
        // one level of it.
        if let stored = fallbacks[option.name] {
            return stored ?? ""
        }
        return option.defaultValue
    }
}