import ABIBridge
import AppKit
import SwiftUI

@MainActor
extension NSImage {
    static func deviceControlSymbol(named name: String, accessibilityDescription: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
            ?? (NSImage.perform(NSSelectorFromString("imageWithPrivateSystemSymbolName:"), with: name)?
                .takeUnretainedValue() as? NSImage)
        image?.accessibilityDescription = accessibilityDescription
        return image
    }
}

/// A custom symbol whose images and palette paths come from one asset catalog.
@MainActor
final class DeviceSymbolResource {
    let image: NSImage
    private let layers: [Layer]
    private let canvasSize: CGSize

    private init(_ contents: Contents) {
        image = contents.image
        layers = contents.layers
        canvasSize = contents.canvasSize
    }

    /// Returns nil when the catalog does not contain the named symbol.
    static func load(named name: String, from catalogURL: URL,
                            weight: NSFont.Weight = .regular) async throws -> DeviceSymbolResource? {
        guard let contents = try await read(named: name, from: catalogURL, weight: weight.rawValue) else { return nil }
        return DeviceSymbolResource(contents)
    }

    func palette(primary: some ShapeStyle, secondary: some ShapeStyle) -> some View {
        Palette(resource: self, primary: AnyShapeStyle(primary), secondary: AnyShapeStyle(secondary))
    }

    nonisolated private struct Layer {
        let path: CGPath
        let level: UInt
        let opacity: Double
        let isEraser: Bool
    }

    nonisolated private struct Contents {
        let image: NSImage
        let layers: [Layer]
        let canvasSize: CGSize
    }

    @concurrent private static func read(named name: String, from url: URL,
                                         weight: Double) async throws -> sending Contents? {
        let runtime = ABIRuntime.shared
        guard let catalogClass = NSClassFromString("CUICatalog"),
              let allocated = (catalogClass as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeRetainedValue()
        else { throw HostError.unavailable("CoreUI symbol catalogs are unavailable") }
        let initialize = try runtime.resolveAndWait(
            .objc(.method("initWithURL:error:", as: ((NSURL) throws -> AnyObject).self)), on: catalogClass)
        // Bundle-based themes share storage between Xcodes with the same identifier.
        // Opening Assets.car itself keeps both lookup and drawing bound to its URL.
        let catalog = try unsafe initialize.unsafeInvoke(on: allocated, url as NSURL)
        let object = runtime.object(catalog)
        let lookup = try object.resolveAndWait(.objc(.method(
            "NS_namedVectorGlyphWithName:", as: ((String) -> AnyObject?).self)))
        guard let base = try unsafe lookup.unsafeInvoke(name) else { return nil }
        let baseObject = runtime.object(base)
        let pointSize = try unsafe baseObject.resolveAndWait(
            .objc(.method("pointSize", as: (() -> Double).self))).unsafeInvoke()
        let continuousSize = try unsafe baseObject.resolveAndWait(
            .objc(.method("glyphContinuousSize", as: (() -> Double).self))).unsafeInvoke()
        let idiom = try unsafe object.resolveAndWait(.objc(.method(
            "nativeIdiom", as: (() -> Int).self))).unsafeInvoke()
        let glyphLookup = try object.resolveAndWait(.objc(.method(
            "namedVectorGlyphWithName:scaleFactor:deviceIdiom:layoutDirection:glyphContinuousSize:glyphContinuousWeight:glyphPointSize:appearanceName:locale:",
            as: ((String, Double, Int, Int, Double, Double, Double, String?, NSLocale?) -> AnyObject?).self)))
        guard let glyph = try unsafe glyphLookup.unsafeInvoke(name, 1, idiom, 0, continuousSize, weight, pointSize, nil, nil)
        else { return nil }
        let glyphObject = runtime.object(glyph)
        let canvas = try unsafe glyphObject.resolveAndWait(.objc(.method(
            "referenceCanvasSize", as: (() -> CGSize).self))).unsafeInvoke()
        let nativeLayers = try unsafe glyphObject.resolveAndWait(.objc(.method(
            "paletteLayers", as: (() -> [AnyObject]).self))).unsafeInvoke()
        var layers: [Layer] = []
        for nativeLayer in nativeLayers {
            let layer = runtime.object(nativeLayer)
            let copy = try layer.resolveAndWait(.objc(.method("copyClipShape", as: (() -> OpaquePointer?).self)))
            guard let pointer = try unsafe copy.unsafeInvoke() else { continue }
            // This is a CoreGraphics copy result, not an Objective-C object return.
            let path = unsafe Unmanaged<CGPath>.fromOpaque(UnsafeRawPointer(pointer)).takeRetainedValue()
            let level = try unsafe layer.resolveAndWait(.objc(.method(
                "hierarchyLevel", as: (() -> UInt).self))).unsafeInvoke()
            let opacity = try unsafe layer.resolveAndWait(.objc(.method(
                "opacity", as: (() -> Double).self))).unsafeInvoke()
            let isEraser = try unsafe layer.resolveAndWait(.objc(.method(
                "isEraserLayer", as: (() -> Bool).self))).unsafeInvoke()
            layers.append(Layer(path: path, level: level, opacity: opacity, isEraser: isEraser))
        }
        let makeImage = try runtime.resolveAndWait(.objc(.method(
            "_imageWithSymbolName:inCatalog:variableValue:accessibilityDescription:createdWithCompatibilityImageName:",
            as: ((String, AnyObject, Double, String?, Bool) -> NSImage?).self)), on: NSImage.self, classMethod: true)
        guard let image = try unsafe makeImage.unsafeInvoke(on: NSImage.self, name, catalog, 0, nil, false)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: NSFont.Weight(rawValue: weight)))
        else { return nil }
        return Contents(image: image, layers: layers, canvasSize: canvas)
    }

    private struct Palette: View {
        let resource: DeviceSymbolResource
        let primary: AnyShapeStyle
        let secondary: AnyShapeStyle
        @Environment(\.displayScale) private var displayScale

        var body: some View {
            // CoreUI rounds the reference canvas out to whole display pixels.
            let intrinsic = CGSize(width: ceil(resource.canvasSize.width * displayScale) / displayScale,
                                   height: ceil(resource.canvasSize.height * displayScale) / displayScale)
            Canvas { context, size in
                let scale = min(size.width / intrinsic.width, size.height / intrinsic.height)
                let transform = CGAffineTransform(
                    translationX: (size.width - intrinsic.width * scale) / 2,
                    y: (size.height - intrinsic.height * scale) / 2).scaledBy(x: scale, y: scale)
                for layer in resource.layers {
                    var drawing = context
                    drawing.opacity = layer.opacity
                    if layer.isEraser { drawing.blendMode = .destinationOut }
                    drawing.fill(Path(layer.path).applying(transform),
                                 with: .style(layer.level == 0 ? primary : secondary))
                }
            }
        }
    }
}
