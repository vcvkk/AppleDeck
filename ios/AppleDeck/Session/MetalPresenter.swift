// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import MetalKit
import UIKit

/// Presents guest frames, and takes touch.
///
/// This is the whole of DroidDeck's `WaylandCompositor` + `SessionActivity`
/// view layer on iOS: QEMU hands over a BGRA scanout, it goes into a texture
/// and on to a `CAMetalLayer`. No compositing of the guest's own surfaces
/// happens here - that is the guest's job, and it is the same code it runs on
/// Android (MangoApp, gamescope, labwc). AppleDeck's compositor is a blitter
/// plus the input router, which is the smallest thing that can be correct.
final class MetalPresenter: UIView {
    /// Called on the main thread for every frame the guest produced.
    var onFirstFrame: (() -> Void)?
    /// Set by the session view; receives every touch the guest should see.
    var inputSink: ((GuestInput) -> Void)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var layer: CAMetalLayer?
    private var texture: MTLTexture?
    private var textureSize = CGSize(width: 0, height: 0)
    private var textureStride = 0
    private var sawFirstFrame = false

    /// Frames the guest produced while nothing was on screen. Dropped rather
    /// than queued: TCG produces them faster than the display can show them,
    /// and a queue would turn a fast guest into a laggy one.
    private var droppedFrames: UInt64 = 0

    override init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("AppleDeck needs Metal; UIRequiredDeviceCapabilities says so, so this is a bug report")
        }
        self.device = device
        self.queue = queue
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func configureLayer() {
        let metal = CAMetalLayer()
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = true
        // The guest's scanout size drives the drawable size, and the view is
        // scaled to fit: gamescope is told an output size, the guest renders at
        // that size, and this layer presents it edge to edge either way.
        metal.contentsGravity = .resizeAspect
        layer.addSublayer(metal)
        layer.metal = metal
        layer.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer?.metal?.frame = bounds
    }

    var droppedFrameCount: UInt64 { droppedFrames }

    /// Called from QEMU's display thread. Copies into a texture immediately,
    /// because the pixels belong to the emulator and are gone by the time this
    /// returns.
    func present(frame: GuestFrame) {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else { return }
        let wanted = CGSize(width: frame.width, height: frame.height)
        let needsTexture = texture == nil || textureSize != wanted || textureStride != frame.stride
        if needsTexture {
            let descriptor = MTKTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: frame.width,
                height: frame.height,
                mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let made = device.makeTexture(descriptor: descriptor) else {
                droppedFrames += 1
                return
            }
            texture = made
            textureSize = wanted
            textureStride = frame.stride
        }
        guard let texture else { return }

        // BGRA in, BGRA out: no conversion, so the copy is a memcpy of the
        // bytes QEMU already produced.
        frame.pixels.withMemoryRebound(to: UInt8.self, capacity: frame.pixels.count) { bytes in
            let bytesPerRow = min(textureStride, frame.width * 4)
            bytes.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { source in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                    mipmapLevel: 0,
                    withBytes: source,
                    bytesPerRow: bytesPerRow)
            }
        }

        if Thread.isMainThread {
            draw(texture)
        } else {
            DispatchQueue.main.async { [weak self] in self?.draw(texture) }
        }
    }

    private func draw(_ texture: MTLTexture) {
        guard let metal = layer?.metal, let drawable = metal.nextDrawable() else { return }
        guard let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, to: drawable.texture, sliceCount: 1, levelCount: 1)
        command.present(drawable)
        command.commit()

        if !sawFirstFrame {
            sawFirstFrame = true
            onFirstFrame?()
        }
    }

    // MARK: - Input

    /// Normalises a touch into the guest's absolute coordinate space and hands
    /// it to the sink. The `touchpad` mode is not implemented here: it is a
    /// relative-pointer emulation over the same absolute device, and it belongs
    /// in the router where the preference lives.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: .down)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: .moved)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: .up)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: .up)
    }

    private enum TouchPhase { case down, moved, up }

    private func send(_ touches: Set<UITouch>, phase: TouchPhase) {
        guard let sink = inputSink, let metal = layer?.metal else { return }
        // virtio-tablet's absolute range is 0..32767 on both axes, and QEMU maps
        // that onto the display size the guest was told about. Not the view's
        // bounds: the guest does not know the view exists.
        let scaleX = Double(32767) / Double(max(metal.drawableSize.width, 1))
        let scaleY = Double(32767) / Double(max(metal.drawableSize.height, 1))
        for touch in touches {
            let point = touch.location(in: self)
            let x = Int((point.x * scaleX).rounded())
            let y = Int((point.y * scaleY).rounded())
            switch phase {
            case .down, .moved:
                sink(.pointer(x: x, y: y))
            case .up:
                sink(.pointer(x: x, y: y))
                sink(.button(linuxButton: 0x110 /* BTN_LEFT */, down: false))
            }
        }
    }

    /// A tap is a left button press and release at one place, which is what the
    /// guest's Wayland pointer expects and what a finger means.
    func sendTap(at point: CGPoint) {
        guard let sink = inputSink, let metal = layer?.metal else { return }
        let x = Int((point.x * Double(32767) / Double(max(metal.drawableSize.width, 1))).rounded())
        let y = Int((point.y * Double(32767) / Double(max(metal.drawableSize.height, 1))).rounded())
        sink(.pointer(x: x, y: y))
        sink(.button(linuxButton: 0x110, down: true))
        sink(.button(linuxButton: 0x110, down: false))
    }
}