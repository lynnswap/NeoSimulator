import AppKit

/// Coordinates in the device's touch and pointer reference frames.
public struct RemoteDeviceInputLocations: Equatable, Sendable {
    public let touch: CGPoint
    public let pointer: CGPoint
    /// Maps the locations that give `pointer`, which are window locations for a screen session, to pointer coordinates
    /// without clamping them to the display, as DeviceKit's `HIDEventGeometry.windowToPointerUnitTransform` does.
    let pointerTransform: CGAffineTransform
}

/// The video and HID surface share this coordinate tree. The video crop does not change the HID ROI.
@MainActor
final class RemoteScreenFramebuffer: NSView {
    struct Display: Equatable {
        let size: CGSize
        let angle: CGFloat
        var identifier: UInt32? = nil
    }

    private let plane = CALayer()
    /// The transport supplies the layer that shows its frames.
    let video: CALayer
    private(set) var display: Display?
    private var attributes: RemoteDeviceVideoAttributes?
    var isReady: Bool { display != nil && attributes != nil && !plane.bounds.isEmpty }

    init(frame: NSRect, video: CALayer = CALayer()) {
        self.video = video
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        plane.masksToBounds = true
        video.contentsGravity = .resize
        layer?.addSublayer(plane)
        plane.addSublayer(video)
    }

    required init?(coder: NSCoder) { nil }

    func update(display: Display?) {
        self.display = display
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func update(attributes: RemoteDeviceVideoAttributes) {
        self.attributes = attributes
        withoutAnimations { video.contentsRect = attributes.contentsRect }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        withoutAnimations {
            guard let display, let attributes,
                  display.size.width > 0, display.size.height > 0,
                  bounds.width > 0, bounds.height > 0 else {
                plane.bounds = .zero
                return
            }
            // SwiftUI's display angles use a top-left origin. AppKit/Core Animation here use
            // a bottom-left origin, so the rendered rotation has the opposite sign.
            let displayAngle = -display.angle * .pi / 180
            let outerSize = Self.rotatedSize(display.size, angle: displayAngle)
            let scale = min(bounds.width / outerSize.width, bounds.height / outerSize.height)
            plane.bounds = CGRect(origin: .zero, size: display.size)
            plane.position = CGPoint(x: bounds.midX, y: bounds.midY)
            plane.setAffineTransform(CGAffineTransform(rotationAngle: displayAngle).scaledBy(x: scale, y: scale))

            // DeviceKit's framebuffer undoes the video orientation inside the display rotation.
            let videoAngle = Self.videoAngle(attributes.orientation) * .pi / 180
            let cropped = CGSize(width: attributes.aspectRatio.width * attributes.contentsRect.width,
                                 height: attributes.aspectRatio.height * attributes.contentsRect.height)
            guard cropped.width > 0, cropped.height > 0 else { video.bounds = .zero; return }
            let rotatedVideo = Self.rotatedSize(cropped, angle: videoAngle)
            let videoScale = min(display.size.width / rotatedVideo.width, display.size.height / rotatedVideo.height)
            video.bounds = CGRect(origin: .zero, size: cropped)
            video.position = CGPoint(x: display.size.width / 2, y: display.size.height / 2)
            video.setAffineTransform(CGAffineTransform(rotationAngle: videoAngle).scaledBy(x: videoScale, y: videoScale))
        }
    }

    /// The input locations of `point` in `view`'s coordinates, or the window's when `view` is nil.
    func inputLocations(at point: CGPoint, from view: NSView?, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? {
        layoutSubtreeIfNeeded()
        guard isReady, let display, let layer else { return nil }
        let locate = { (point: CGPoint) in self.plane.convert(self.convertToLayer(self.convert(point, from: view)), from: layer) }
        let location = locate(point)
        let size = plane.bounds.size
        guard clampingToDisplay || plane.bounds.contains(location) else { return nil }
        let touch = CGPoint(x: min(1, max(0, location.x / size.width)),
                            y: min(1, max(0, 1 - location.y / size.height)))
        // HIDEventGeometry.windowToPointerUnitTransform applies +displayAngle around unit center.
        let correction = CGAffineTransform(translationX: 0.5, y: 0.5)
            .rotated(by: display.angle * .pi / 180).translatedBy(x: -0.5, y: -0.5)
        // The views and layers between `view` and the plane only move, scale, and turn it, so three points give the
        // affine transform of the whole conversion, which then maps to touch coordinates like `touch` without the clamp.
        let toPlane = CGAffineTransform(sampling: locate)
        let toTouch = CGAffineTransform(a: 1 / size.width, b: 0, c: 0, d: -1 / size.height, tx: 0, ty: 1)
        return RemoteDeviceInputLocations(touch: touch, pointer: touch.applying(correction),
                                          pointerTransform: toPlane.concatenating(toTouch).concatenating(correction))
    }

    private static func rotatedSize(_ size: CGSize, angle: CGFloat) -> CGSize {
        CGSize(width: abs(size.width * cos(angle)) + abs(size.height * sin(angle)),
               height: abs(size.width * sin(angle)) + abs(size.height * cos(angle)))
    }

    private static func videoAngle(_ orientation: RemoteDeviceOrientation?) -> CGFloat {
        switch orientation {
        case .portraitUpsideDown: 180
        case .landscapeLeft: 90
        case .landscapeRight: -90
        default: 0
        }
    }

    func withoutAnimations(_ operation: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        operation()
        CATransaction.commit()
    }
}

extension CGAffineTransform {
    /// The transform of `convert`, a conversion that only moves, scales, and turns points, from the points it gives the
    /// origin and the ends of the unit axes.
    init(sampling convert: (CGPoint) -> CGPoint) {
        let origin = convert(.zero), xAxis = convert(CGPoint(x: 1, y: 0)), yAxis = convert(CGPoint(x: 0, y: 1))
        self.init(a: xAxis.x - origin.x, b: xAxis.y - origin.y, c: yAxis.x - origin.x, d: yAxis.y - origin.y,
                  tx: origin.x, ty: origin.y)
    }
}
