// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppleDeckCore

/// What the session needs, and whether it is there.
///
/// DroidDeck's components page is a list of switches that install, enable and
/// check the pieces a session is made of: the runtime, the audio path, the input
/// relay, the battery and rumble bridges. On iOS most of them are either the
/// guest's job now or impossible, and this screen says which and why - a list of
/// switches that quietly do nothing is worse than a list of facts.
struct ComponentsManager: View {
    @EnvironmentObject private var launcher: LauncherModel

    var body: some View {
        List {
            Section {
                ComponentRow(name: "Linux runtime",
                             detail: runtimeDetail,
                             state: launcher.session.isRuntimeInstalled ? .present : .missing)
                ComponentRow(name: "Emulator",
                             detail: launcher.runtimeStatus,
                             state: runtimeAvailable ? .present : .missing)
                ComponentRow(name: "Guest image",
                             detail: guestDetail,
                             state: launcher.session.runtimeVersion == nil ? .missing : .present)
            } header: {
                Text("Session")
            } footer: {
                Text("The guest is DroidDeck's own runtime - Steam, gamescope, the desktop - in an arm64 Linux machine under TCG. A session is that runtime; the iOS app is the window it is shown in.")
            }

            Section {
                ComponentRow(name: "DirectAudio relay",
                             detail: relayDetail,
                             state: .planned)
                ComponentRow(name: "PulseAudio",
                             detail: "Runs inside the guest, as on Android. Its sink is the relay above.",
                             state: .present)
                ComponentRow(name: "Game controller",
                             detail: controllerDetail,
                             state: controllerConnected ? .present : .absent)
                ComponentRow(name: "Touch",
                             detail: "Absolute pointer through virtio-tablet; \(launcher.prefs.touchMode.rawValue).",
                             state: .present)
            } header: {
                Text("Input and audio")
            }

            Section {
                ComponentRow(name: "Battery bridge",
                             detail: "Not needed: the guest has its own power supply and no Android host to lie to.",
                             state: .notApplicable)
                ComponentRow(name: "Rumble",
                             detail: "Not wired: virtio-input rumble needs the host's haptics engine, which iOS does not expose to a sideloaded app.",
                             state: .notApplicable)
                ComponentRow(name: "Agent bridge",
                             detail: agentDetail,
                             state: .present)
            } header: {
                Text("Host bridges")
            }

            Section {
                ComponentRow(name: "Turnip (Adreno Vulkan)",
                             detail: "Gone as a host driver: the guest draws with the Vulkan driver in its own image, on a virtio GPU.",
                             state: .notApplicable)
                ComponentRow(name: "Wayland compositor",
                             detail: "Runs in the guest - gamescope for Steam, labwc for the desktop, MangoApp to present it.",
                             state: .present)
                ComponentRow(name: "Metal presenter",
                             detail: "Blits the guest's scanout. The only host-side graphics, and it composites nothing.",
                             state: .present)
            } header: {
                Text("Graphics")
            }
        }
    }

    private var runtimeAvailable: Bool { launcher.session.sessionRuntimeAvailable }

    private var runtimeDetail: String {
        launcher.session.isRuntimeInstalled
            ? "Installed, version \(launcher.session.runtimeVersion ?? "unknown")"
            : "Not unpacked yet"
    }

    private var guestDetail: String {
        if let version = launcher.session.runtimeVersion {
            return "DroidDeck runtime \(version)"
        }
        return "No runtime image; ios/scripts/build_guest_image.sh fetches it"
    }

    private var relayDetail: String {
        #if canImport(AVFoundation)
        return "The guest's PulseAudio talks over a socket; the host half is an AudioUnit sink that is not written yet."
        #else
        return "Host half not written"
        #endif
    }

    private var controllerDetail: String {
        let profile = launcher.prefs.controllerProfile
        return profile == .deck
            ? "Presented to the guest as a Steam Deck controller"
            : "Presented as an Xbox controller, which is what Proton wants"
    }

    private var controllerConnected: Bool { InputRouter.connectedControllerCount > 0 }

    private var agentDetail: String {
        "Loopback only, on 127.0.0.1:\(AgentBridgeServer.port); anything else is dropped before a byte is read"
    }
}

/// One row: a name, what it says, and a state that means something.
struct ComponentRow: View {
    enum State {
        case present
        case missing
        case absent
        case planned
        case notApplicable

        var label: String {
            switch self {
            case .present: return "ready"
            case .missing: return "missing"
            case .absent: return "none yet"
            case .planned: return "planned"
            case .notApplicable: return "not needed"
            }
        }

        var symbol: String {
            switch self {
            case .present: return "checkmark.circle.fill"
            case .missing: return "xmark.octagon.fill"
            case .absent: return "circle.dashed"
            case .planned: return "clock.badge.questionmark"
            case .notApplicable: return "minus.circle"
            }
        }

        var tint: Color {
            switch self {
            case .present: return .green
            case .missing: return .red
            case .absent, .planned: return .orange
            case .notApplicable: return .secondary
            }
        }
    }

    let name: String
    let detail: String
    let state: State

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(state.label, systemImage: state.symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(state.tint)
        }
    }
}