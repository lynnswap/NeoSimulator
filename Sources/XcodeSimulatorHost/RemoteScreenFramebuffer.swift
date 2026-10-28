import AppKit

/// Coordinates in the device's touch and pointer reference frames.
public struct RemoteDeviceInputLocations: Equatable, Sendable {
    public let touch: CGPoint
    public let pointer: CGPoint
}

/// The video and HID surface share this coordinate tree. The video crop does not change the HID ROI.
@MainActor
final class RemoteScreenFramebuffer: NSView {
    struct Display: Equatable {
        let size: CGSize
        let angle: CGFloat
        var identifier: UInt32? = nil
    }

    let sourceLayer = CALayer()
    private let plane = CALayer()
    private let video = CALayer()
    private var contentsObservation: NSKeyValueObservation?
    private(set) var display: Display?
    private var attributes: RemoteDeviceVideoAttributes?
    var isReady: Bool { display != nil && attributes != nil && !plane.bounds.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        plane.masksToBounds = true
        video.contentsGravity = .resize
        layer?.addSublayer(plane)
        plane.addSublayer(video)
        contentsObservation = sourceLayer.observe(\.contents, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.withoutAnimations { self.video.contents = self.sourceLayer.contents }
            }
        }
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

    func inputLocations(at point: CGPoint, from view: NSView, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? {
        layoutSubtreeIfNeeded()
        guard isReady, let display, let layer else { return nil }
        let local = convertToLayer(convert(point, from: view))
        let location = plane.convert(local, from: layer)
        let size = plane.bounds.size
        guard clampingToDisplay || plane.bounds.contains(location) else { return nil }
        let touch = CGPoint(x: min(1, max(0, location.x / size.width)),
                            y: min(1, max(0, 1 - location.y / size.height)))
        // HIDEventGeometry.windowToPointerUnitTransform applies +displayAngle around unit center.
        let correction = CGAffineTransform(translationX: 0.5, y: 0.5)
            .rotated(by: display.angle * .pi / 180).translatedBy(x: -0.5, y: -0.5)
        return RemoteDeviceInputLocations(touch: touch, pointer: touch.applying(correction))
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

    private func withoutAnimations(_ operation: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        operation()
        CATransaction.commit()
    }
}
