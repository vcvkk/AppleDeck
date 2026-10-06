// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import MetalKit
import SwiftUI
import UIKit

/// Presents guest frames, and takes touch.
///
/// This is the whole of DroidDeck's `WaylandCompositor` view layer on iOS: QEMU
/// hands over a BGRA scanout, it goes into a texture and on to a `CAMetalLayer`.
/// No compositing of the guest's own surfaces happens here - that is the guest's
/// job, and it is the same code it runs on Android (MangoApp, gamescope,
/// labwc). AppleDeck's compositor is a blitter, which is the smallest thing that
/// can be correct.
final class MetalPresenter: UIView {
    /// Called once, the first time the guest produces a frame.
    var onFirstFrame: (() -> Void)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var metalLayer: CAMetalLayer?
    private var texture: MTLTexture?
    private var textureSize = CGSize(width: 0, height: 0)
    private var textureStride = 0
    private var sawFirstFrame = false

    /// Frames the guest produced while nothing was on screen. Dropped rather
    /// than queued: TCG produces them faster than a phone can draw them, and a
    /// queue would turn a fast guest into a laggy one.
    private(set) var droppedFrames: UInt64 = 0

    override init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            // UIRequiredDeviceCapabilities says metal, so a device without it
            // cannot have installed this app.
            fatalError("AppleDeck needs Metal")
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
        // The guest's scanout size drives the drawable size and the view is
        // scaled to fit: the guest was told an output size, renders at that
        // size, and is presented edge to edge either way.
        metal.contentsGravity = .resizeAspect
        layer.addSublayer(metal)
        metalLayer = metal
        metal.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer?.frame = bounds
    }

    var droppedFrameCount: UInt64 { droppedFrames }

    /// Called from QEMU's display thread. The copy into the texture happens here,
    /// immediately, because the pixels belong to the emulator and are gone by
    /// the time this returns; only the draw is deferred to the main thread.
    func present(frame: GuestFrame) {
        let bytesPerPixel = 4
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * bytesPerPixel else {
            droppedFrames += 1
            return
        }
        let wanted = CGSize(width: frame.width, height: frame.height)
        if texture == nil || textureSize != wanted || textureStride != frame.stride {
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
        guard let texture else {
            droppedFrames += 1
            return
        }

        // BGRA in, BGRA out: no conversion, so this is a copy of the bytes QEMU
        // already produced, at the pitch it already has.
        let rowBytes = min(textureStride, frame.width * bytesPerPixel)
        frame.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: rowBytes)
        }

        if Thread.isMainThread {
            draw(texture)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let texture = self.texture else { return }
                self.draw(texture)
            }
        }
    }

    private func draw(_ texture: MTLTexture) {
        guard let metal = metalLayer, let drawable = metal.nextDrawable() else { return }
        guard let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture,
                  to: drawable.texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  destinationSlice: 0,
                  destinationLevel: 0)
        command.present(drawable)
        command.commit()

        if !sawFirstFrame {
            sawFirstFrame = true
            onFirstFrame?()
        }
    }

    // MARK: - Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, release: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, release: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, release: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, release: true)
    }

    /// A touch, in the guest's absolute coordinate space.
    ///
    /// virtio-tablet's absolute range is 0...32767 on both axes and QEMU maps
    /// that onto the display size the guest was told about - not the view's
    /// bounds, because the guest does not know the view exists. The touch modes
    /// (direct against touchpad) are `InputRouter`'s decision, not this view's,
    /// so this only converts and reports.
    func guestPoint(for point: CGPoint) -> CGPoint {
        guard let metal = metalLayer else { return point }
        let width = Double(max(metal.drawableSize.width, 1))
        let height = Double(max(metal.drawableSize.height, 1))
        return CGPoint(x: (Double(point.x) / width) * 32767.0,
                       y: (Double(point.y) / height) * 32767.0)
    }

    var onTouch: ((CGPoint, UIGestureRecognizer.State) -> Void)?

    private func forward(_ touches: Set<UITouch>, release: Bool) {
        guard let handler = onTouch else { return }
        for touch in touches {
            let point = touch.location(in: self)
            let state: UIGestureRecognizer.State = release ? .ended : (touches.count > 0 ? .changed : .began)
            handler(guestPoint(for: point), state)
        }
    }
}

/// The presenter inside SwiftUI. The session screen holds one `UIView`, not a
/// Metal command queue and a texture cache, and this is the only place the two
/// meet.
struct MetalPresenterView: UIViewRepresentable {
    /// Set by the session screen once, after the view exists: frames in, first
    /// frame out.
    var onReady: ((MetalPresenter) -> Void)?

    func makeUIView(context: Context) -> MetalPresenter {
        let view = MetalPresenter(frame: .zero)
        onReady?(view)
        return view
    }

    func updateUIView(_ uiView: MetalPresenter, context: Context) {}
}