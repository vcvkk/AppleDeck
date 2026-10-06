// SPDX-License-Identifier: GPL-2.0-or-later
import GameController
import UIKit

/// Everything the user touches, keys and presses, on its way to the guest.
///
/// DroidDeck has two of these, because Android has two input stacks: the
/// framework's, and a fake evdev ring inside the guest. iOS has one stack and
/// the guest has one input device, so there is one router with one job - turn
/// UIKit and GameController events into `GuestInput`, honouring the preferences
/// in `SessionPrefs`. The touch modes are the part users notice first, so they
/// are spelled out below rather than left to a reader.
final class InputRouter {
    /// Where events go. The session view points this at the runtime.
    var sink: ((GuestInput) -> Void)?

    private let prefs: Prefs
    private var mode: SessionMode = .steam
    private var touchAnchor: CGPoint?
    private var touchMoved = false
    private var leftDown = false

    init(prefs: Prefs) {
        self.prefs = prefs
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(controllerConnected),
                           name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(controllerDisconnected),
                           name: .GCControllerDidDisconnect, object: nil)
        if let first = GCController.controllers().first {
            adopt(first)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func beginSession(mode: SessionMode) {
        self.mode = mode
        touchAnchor = nil
        touchMoved = false
    }

    // MARK: - Touch

    /// One touch, in guest coordinates (the presenter has already scaled them to
    /// virtio-tablet's 0...32767 range).
    ///
    /// * `direct` is what a phone user expects: the pointer jumps under the
    ///   finger and the button is down for as long as it is touching.
    /// * `touchpad` is what a desktop user expects: dragging moves the pointer
    ///   from where it already is, and only a tap - short, and without moving -
    ///   clicks. A drag must never click, or every scroll of a Steam library
    ///   opens a game.
    func touch(at guestPoint: CGPoint, phase: UIGestureRecognizer.State) {
        guard let sink else { return }
        switch prefs.effectiveTouchMode(for: mode) {
        case .direct:
            sink(.pointer(x: Int(guestPoint.x), y: Int(guestPoint.y)))
            switch phase {
            case .began:
                sink(.button(linuxButton: Key.btnLeft, down: true))
                leftDown = true
            case .ended, .cancelled:
                if leftDown {
                    sink(.button(linuxButton: Key.btnLeft, down: false))
                    leftDown = false
                }
            default:
                break
            }

        case .touchpad, .auto:
            switch phase {
            case .began:
                touchAnchor = guestPoint
                touchMoved = false
            case .changed:
                guard let anchor = touchAnchor else { return }
                // Movement is measured, not sent: a pixel of jitter is a
                // "moved" tap, and a "moved" tap is not a tap.
                if hypot(guestPoint.x - anchor.x, guestPoint.y - anchor.y) > 4 {
                    touchMoved = true
                }
                sink(.pointer(x: Int(guestPoint.x), y: Int(guestPoint.y)))
            case .ended:
                if !touchMoved {
                    sink(.pointer(x: Int(guestPoint.x), y: Int(guestPoint.y)))
                    sink(.button(linuxButton: Key.btnLeft, down: true))
                    sink(.button(linuxButton: Key.btnLeft, down: false))
                }
                touchAnchor = nil
                touchMoved = false
            case .cancelled:
                touchAnchor = nil
                touchMoved = false
            default:
                break
            }
        }
    }

    /// Two-finger tap: the phone's Back gesture. Returns true when the guest
    /// should not also see the touch, which is always: Back belongs to the
    /// launcher, or to Steam's QAM, not to whatever has the pointer.
    @discardableResult
    func handleBackGesture() -> Bool {
        press(Key.escape)
        return true
    }

    /// Three-finger tap: the Steam Deck's View button, which is how a phone user
    /// opens the Steam menu.
    @discardableResult
    func handleMenuGesture() -> Bool {
        press(Key.mode)
        return true
    }

    /// A press-and-hold over the on-screen controls, which is a right click in
    /// Steam's own terms.
    func longPress(at guestPoint: CGPoint) {
        guard let sink else { return }
        sink(.pointer(x: Int(guestPoint.x), y: Int(guestPoint.y)))
        sink(.button(linuxButton: Key.btnLeft, down: false))
        sink(.button(linuxButton: Key.btnRight, down: true))
        sink(.button(linuxButton: Key.btnRight, down: false))
    }

    private func press(_ code: Int) {
        sink?(.key(code: code, down: true))
        sink?(.key(code: code, down: false))
    }

    // MARK: - Keyboard

    /// The hardware keyboard, as `UIKeyCommand`s on the session view. The
    /// mapping is to evdev codes because that is what virtio-keyboard speaks and
    /// what the guest's input stack is expecting.
    static let keyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        let simple: [(input: String, flags: UIKeyModifierFlags)] = [
            ("UIKeyInputUpArrow", []), ("UIKeyInputDownArrow", []),
            ("UIKeyInputLeftArrow", []), ("UIKeyInputRightArrow", []),
            ("UIKeyInputEscape", []), ("UIKeyInputEnter", []),
            (" ", []), ("\t", []), ("\u{8}", [])
        ]
        for entry in simple {
            commands.append(UIKeyCommand(input: entry.input, modifierFlags: entry.flags,
                                        action: #selector(Self.handleKeyCommand(_:))))
        }
        return commands
    }()

    /// Read back in `handleKeyCommand`. `UIKeyCommand` carries no key code, so
    /// the input string is the key; a mapping table is smaller and far less
    /// error-prone than a selector per key.
    private static let codes: [String: Int] = [
        "UIKeyInputUpArrow": Key.up, "UIKeyInputDownArrow": Key.down,
        "UIKeyInputLeftArrow": Key.left, "UIKeyInputRightArrow": Key.right,
        "UIKeyInputEscape": Key.escape, "UIKeyInputEnter": Key.enter,
        " ": Key.space, "\t": Key.tab, "\u{8}": Key.backspace
    ]

    @objc func handleKeyCommand(_ command: UIKeyCommand) {
        guard let code = Self.codes[command.input] else { return }
        press(code)
    }

    // MARK: - Game controllers

    @objc private func controllerConnected(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        adopt(controller)
    }

    @objc private func controllerDisconnected(_ note: Notification) {
        _ = note.object as? GCController
    }

    /// `ControllerProfile.deck` presents the pad as a Steam Deck controller,
    /// which is what makes the QAM, the virtual trackpad and the Steam button
    /// work; `xbox360` presents it as an XInput pad, which is what Proton games
    /// want. The choice is DroidDeck's and the mapping follows from it.
    private func adopt(_ controller: GCController) {
        let deck = prefs.controllerProfile == .deck
        controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, element in
            guard let self else { return }
            switch element {
            case .buttonA:
                self.set(pad.buttonA, deck ? Key.btnSouth : Key.btnSouth)
            case .buttonB:
                // On a Steam Deck pad B is East; an Xbox layout wants the
                // client's A, and the client's own mapping handles the rest.
                self.set(pad.buttonB, deck ? Key.btnEast : Key.btnSouth)
            case .buttonX:
                self.set(pad.buttonX, deck ? Key.btnNorth : Key.btnWest)
            case .buttonY:
                self.set(pad.buttonY, deck ? Key.btnWest : Key.btnNorth)
            case .leftShoulder: self.set(pad.leftShoulder, Key.shoulderL)
            case .rightShoulder: self.set(pad.rightShoulder, Key.shoulderR)
            case .leftTrigger: self.trigger(pad.leftTrigger.value, Key.triggerL)
            case .rightTrigger: self.trigger(pad.rightTrigger.value, Key.triggerR)
            case .dpad: self.dpad(pad.dpad)
            case .leftThumbstickButton: self.set(pad.leftThumbstickButton, Key.thumbL)
            case .rightThumbstickButton: self.set(pad.rightThumbstickButton, Key.thumbR)
            default: break
            }
        }
        if deck {
            controller.valueChangedHandler = { [weak self] _, element in
                guard let self else { return }
                switch element {
                case .buttonMenu: self.set(true, Key.menu)
                case .buttonHome: self.set(true, Key.mode)
                case .buttonOptions: self.set(true, Key.select)
                case .buttonShare: self.set(true, Key.system)
                default: break
                }
            }
        }
    }

    private func set(_ pressed: Bool, _ code: Int) {
        sink?(.button(linuxButton: code, down: pressed))
    }

    private func trigger(_ value: Float, _ code: Int) {
        // Digital, on purpose: a Steam Input profile maps the trigger axis from
        // the digital bit, and a half-pressed trigger read as an axis stutters
        // in every menu.
        sink?(.button(linuxButton: code, down: value > 0.5))
    }

    private func dpad(_ dpad: GCControllerDirectionPad) {
        set(dpad.up, Key.dpadUp)
        set(dpad.down, Key.dpadDown)
        set(dpad.left, Key.dpadLeft)
        set(dpad.right, Key.dpadRight)
    }
}

/// Linux evdev codes, which is what virtio-keyboard and virtio-input speak.
enum Key {
    static let escape = 1
    static let enter = 28
    static let left = 105
    static let right = 106
    static let up = 103
    static let down = 108
    static let tab = 15
    static let backspace = 14
    static let space = 57
    static let mode = 0x2c6
    static let btnLeft = 0x110
    static let btnRight = 0x111
    static let btnSouth = 0x130
    static let btnEast = 0x131
    static let btnNorth = 0x133
    static let btnWest = 0x134
    static let dpadUp = 0x220
    static let dpadDown = 0x221
    static let dpadLeft = 0x222
    static let dpadRight = 0x223
    static let thumbL = 0x22e
    static let thumbR = 0x22f
    static let shoulderL = 0x2b1
    static let shoulderR = 0x2b2
    static let triggerL = 0x2c0
    static let triggerR = 0x2c1
    static let select = 0x2c2
    static let start = 0x2c3
    static let menu = 0x2c7
    static let system = 0x2c4
}