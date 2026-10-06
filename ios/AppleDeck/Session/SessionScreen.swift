// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import AppleDeckCore

/// The session screen: the guest's frames, the overlay, and the gestures.
///
/// The overlay is DroidDeck's `SessionOverlay` with its on-screen controls,
/// HUD, menu and QAM handling, in the shape a phone wants: reachable thumbs,
/// no physical Back button to rely on (so Back is a gesture and a hardware
/// Escape), and a game controller when one is paired.
struct SessionScreen: View {
    @ObservedObject var session: SessionController
    @EnvironmentObject private var launcher: LauncherModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var presenter = MetalPresenter()
    @State private var router: InputRouter?
    @State private var overlayVisible = true
    @State private var steamQAMOpen = false
    @State private var keyboardVisible = false

    var body: some View {
        ZStack {
            presenter
                .ignoresSafeArea()
                .onAppear(perform: attach)
                .onDisappear(perform: detach)

            if session.phase.isPreparing {
                preparing
            }

            if overlayVisible && session.phase.isLive && session.prefs.hud {
                SessionOverlay(session: session,
                               router: router,
                               steamQAMOpen: $steamQAMOpen,
                               showKeyboard: $keyboardVisible)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: session.sceneDidEnterBackground()
            case .active: session.sceneWillEnterForeground()
            default: break
            }
        }
    }

    private var preparing: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(session.phase.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.footnote.monospaced())
            if let failure = session.failureMessage {
                Text(failure).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Close") { session.stop() }
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(32)
    }

    private func attach() {
        let prefs = launcher.prefs
        let router = InputRouter(prefs: prefs)
        router.beginSession(mode: session.request?.mode ?? .steam)
        router.sink = { input in
            sessionRuntimeSend(input)
        }
        presenter.inputSink = nil
        presenter.onFirstFrame = { session.noteFrame() }
        self.router = router

        // Frames go straight to the presenter, which hops to the main thread.
        AppleDeckFrameBridge.install { pixels, width, height, stride in
            let buffer = UnsafeRawBufferPointer(start: pixels, count: height * stride)
            DispatchQueue.main.async { [weak presenter] in
                presenter?.present(frame: GuestFrame(width: width, height: height,
                                                    stride: stride, pixels: buffer))
            }
        }
    }

    private func detach() {
        AppleDeckFrameBridge.install { _, _, _, _ in }
        router = nil
    }

    private func sessionRuntimeSend(_ input: GuestInput) {
        // The session controller owns the runtime; the router does not know
        // about it, which is what lets the launcher and the session share one
        // input router in tests.
        session.send(input)
    }
}

/// The overlay: HUD, menu, the on-screen controls, and the QAM toggle.
///
/// The controls are the same set DroidDeck shows (stick, d-pad, ABXY, the four
/// face buttons, shoulders, triggers, Steam and View) driven by
/// `SessionPrefs.oscMode`, and they are laid out for thumbs rather than for
/// Android's bottom bar.
struct SessionOverlay: View {
    @ObservedObject var session: SessionController
    let router: InputRouter?
    @Binding var steamQAMOpen: Bool
    @Binding var showKeyboard: Bool

    @EnvironmentObject private var launcher: LauncherModel

    var body: some View {
        VStack {
            hud
            Spacer()
            if controlsVisible {
                controls
            }
        }
        .transition(.opacity)
    }

    private var hud: some View {
        HStack(spacing: 12) {
            Text(session.phase.rawValue)
                .font(.caption2.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
            if session.suspended {
                Text("suspended").font(.caption2).foregroundStyle(.yellow)
            }
            if session.droppedInputEvents > 0 {
                // See AppleDeckQemuDroppedEvents: input going nowhere is the
                // failure a user reports as "the game is frozen".
                Text("\(session.droppedInputEvents) inputs dropped")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
            Button {
                showKeyboard = true
            } label: {
                Image(systemName: "keyboard").font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            Button {
                session.stop()
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var controlsVisible: Bool {
        launcher.prefs.onScreenControlsVisible(for: session.request?.mode ?? .steam,
                                               steamQAMOpen: steamQAMOpen)
    }

    private var controls: some View {
        VStack {
            HStack {
                DeckPad(router: router, size: 140)
                Spacer()
                FaceButtons(router: router, size: 132)
            }
            .padding(.horizontal)
            HStack(spacing: 10) {
                ShoulderButton(router: router, code: Key.shoulderL, title: "L1")
                ShoulderButton(router: router, code: Key.triggerL, title: "L2")
                Button { steamQAMOpen.toggle() } label: {
                    Text("QAM").font(.caption2.monospaced())
                }
                .buttonStyle(.bordered)
                ShoulderButton(router: router, code: Key.shoulderR, title: "R1")
                ShoulderButton(router: router, code: Key.triggerR, title: "R2")
                Button { showKeyboard = true } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// A thumb stick that behaves like a real one: the guest gets relative motion,
/// implemented here as the difference between successive positions, because the
/// guest's pad device is absolute.
struct DeckPad: View {
    let router: InputRouter?
    let size: CGFloat
    @State private var last: CGPoint?

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.5), lineWidth: 2)
                .frame(width: size, height: size)
            Circle()
                .fill(.white.opacity(0.25))
                .frame(width: size * 0.36, height: size * 0.36)
                .offset(x: offset.x, y: offset.y)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let router else { return }
                    if let last {
                        // Relative, scaled to the guest's stick range.
                        let dx = Int((value.location.x - last.x) * 512)
                        let dy = Int((value.location.y - last.y) * 512)
                        router.sink?(.wheel(axis: 0, delta: dx))
                        router.sink?(.wheel(axis: 1, delta: dy))
                    }
                    last = value.location
                }
                .onEnded { _ in last = nil }
        )
    }

    private var offset: CGSize {
        guard let last else { return .zero }
        let radius = size / 2 - size * 0.18
        let dx = last.x - size / 2
        let dy = last.y - size / 2
        let length = max(hypot(dx, dy), 1)
        let scale = min(radius / length, 1)
        return CGSize(width: dx * scale, height: dy * scale)
    }
}

struct FaceButtons: View {
    let router: InputRouter?
    let size: CGFloat

    var body: some View {
        // The Deck's diamond: Y north, X west, B east, A south.
        ZStack {
            button("Y", code: Key.btnWest).offset(y: -size * 0.22)
            button("X", code: Key.btnNorth).offset(x: -size * 0.22)
            button("B", code: Key.btnEast).offset(x: size * 0.22)
            button("A", code: Key.btnSouth).offset(y: size * 0.22)
        }
        .frame(width: size, height: size)
    }

    private func button(_ title: String, code: Int) -> some View {
        Button {
            router?.sink?(.button(linuxButton: code, down: true))
            router?.sink?(.button(linuxButton: code, down: false))
        } label: {
            Circle()
                .fill(.white.opacity(0.18))
                .overlay(Text(title).font(.caption.weight(.semibold)))
                .frame(width: size * 0.34, height: size * 0.34)
        }
        .buttonStyle(.plain)
    }
}

struct ShoulderButton: View {
    let router: InputRouter?
    let code: Int
    let title: String

    var body: some View {
        Button {
            router?.sink?(.button(linuxButton: code, down: true))
            router?.sink?(.button(linuxButton: code, down: false))
        } label: {
            Text(title).font(.caption2.monospaced())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}