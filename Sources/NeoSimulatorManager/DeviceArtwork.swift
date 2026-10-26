import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct DeviceSymbolArtwork: Sendable {
    let name: String
    var bundleURL: URL?

    @MainActor var image: Image {
        if let bundleURL, let bundle = Bundle(url: bundleURL) {
            Image(name, bundle: bundle)
        } else {
            Image(systemName: name)
        }
    }
}

/// Presentation artwork is cached by the device's model and Xcode resources.
@MainActor
final class DeviceArtworkCache {
    private let metadata = Task { await DeviceSymbolMetadata.read() }
    private var entries: [String: DeviceArtworkModel] = [:]

    func artwork(modelIdentifier: String?, family: String, xcodeURL: URL?,
                 resolveXcodeURL: @escaping @MainActor () async -> URL? = { nil }) -> DeviceArtworkModel {
        let key = [modelIdentifier ?? "", family, xcodeURL?.path ?? ""].joined(separator: "|")
        if let entry = entries[key] { return entry }
        let type = modelIdentifier.flatMap {
            UTType.types(tag: $0, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"),
                         conformingTo: nil).first(where: \.isDeclared)
        }
        let entry = DeviceArtworkModel(contentType: type, family: family, xcodeURL: xcodeURL,
                                       metadata: metadata, resolveXcodeURL: resolveXcodeURL)
        entries[key] = entry
        return entry
    }
}

@MainActor @Observable
final class DeviceArtworkModel {
    let contentType: UTType?
    private(set) var symbol: DeviceSymbolArtwork?
    @ObservationIgnored private var symbolTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<NSImage, Never>?

    fileprivate init(contentType: UTType?, family: String, xcodeURL: URL?,
                     metadata: Task<DeviceSymbolMetadata, Never>,
                     resolveXcodeURL: @escaping @MainActor () async -> URL?) {
        self.contentType = contentType
        symbolTask = Task { [weak self] in
            let definitions = await metadata.value
            let identifier = contentType?.identifier ?? ""
            let needsDuoResource = identifier.contains("iphone-duo") || identifier.contains("iphone-v68")
            var resourceURL = xcodeURL
            if needsDuoResource, resourceURL == nil { resourceURL = await resolveXcodeURL() }
            guard !Task.isCancelled, let self else { return }
            self.symbol = definitions.artwork(for: contentType, family: family, xcodeURL: resourceURL)
        }
    }

    func hardwarePreview() async -> NSImage? {
        if let previewTask { return await previewTask.value }
        guard let contentType else { return nil }
        let task = Task { await Self.loadHardwarePreview(contentType) }
        previewTask = task
        return await task.value
    }

    @concurrent private static func loadHardwarePreview(_ type: UTType) async -> NSImage {
        let image = NSWorkspace.shared.icon(for: type)
        var previewRect = CGRect(x: 0, y: 0, width: 128, height: 128)
        guard let preview = image.cgImage(forProposedRect: &previewRect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: preview.width, height: preview.height,
                                      bitsPerComponent: 8, bytesPerRow: preview.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return image }
        context.draw(preview, in: CGRect(x: 0, y: 0, width: preview.width, height: preview.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var left = preview.width, bottom = preview.height, right = -1, top = -1
        for y in 0..<preview.height {
            for x in 0..<preview.width where pixels[y * context.bytesPerRow + x * 4 + 3] != 0 {
                left = min(left, x)
                right = max(right, x)
                bottom = min(bottom, y)
                top = max(top, y)
            }
        }
        let largest = image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        var proposed = CGRect(x: 0, y: 0, width: largest?.pixelsWide ?? 512, height: largest?.pixelsHigh ?? 512)
        guard right >= left, top >= bottom,
              let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return image }
        let scaleX = Double(source.width) / Double(preview.width)
        let scaleY = Double(source.height) / Double(preview.height)
        guard let cropped = source.cropping(to: CGRect(
            x: Double(left) * scaleX, y: Double(bottom) * scaleY,
            width: Double(right - left + 1) * scaleX,
            height: Double(top - bottom + 1) * scaleY)) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

fileprivate struct DeviceSymbolMetadata: Sendable {
    var symbols: [String: String] = [:]
    var parents: [String: [String]] = [:]

    @concurrent static func read() async -> DeviceSymbolMetadata {
        let root = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle")
        let library = root.appendingPathComponent("Contents/Library")
        let children = (try? FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var result = DeviceSymbolMetadata()
        for url in [root] + children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let info = Bundle(url: url)?.infoDictionary else { continue }
            let declarations = (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
                + (info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
            for declaration in declarations {
                guard let identifier = declaration["UTTypeIdentifier"] as? String else { continue }
                if let icons = declaration["UTTypeIcons"] as? [String: Any],
                   let name = icons["UTTypeSymbolName"] as? String {
                    result.symbols[identifier] = name
                }
                if let parent = declaration["UTTypeConformsTo"] as? String {
                    result.parents[identifier] = [parent]
                } else if let parents = declaration["UTTypeConformsTo"] as? [String] {
                    result.parents[identifier] = parents
                }
            }
        }
        return result
    }

    @MainActor func artwork(for type: UTType?, family: String, xcodeURL: URL?) -> DeviceSymbolArtwork {
        if let type {
            let identifier = type.identifier.lowercased()
            if identifier.contains("iphone-duo") || identifier.contains("iphone-v68") {
                let url = xcodeURL?.appendingPathComponent("Contents/SharedFrameworks/DeviceKit.framework")
                if let url, Bundle(url: url)?.image(forResource: "v68_Closed") != nil {
                    return DeviceSymbolArtwork(name: "v68_Closed", bundleURL: url)
                }
                return DeviceSymbolArtwork(name: "questionmark")
            }
            if identifier.contains("macbook") { return DeviceSymbolArtwork(name: "laptopcomputer") }
            if identifier.contains("vision") { return DeviceSymbolArtwork(name: "visionpro") }
            if identifier.contains("apple-tv") { return DeviceSymbolArtwork(name: "tv") }
            var pending = [type.identifier]
            var visited: Set<String> = []
            while !pending.isEmpty {
                let identifier = pending.removeFirst()
                guard visited.insert(identifier).inserted else { continue }
                if let name = symbols[identifier],
                   NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                    return DeviceSymbolArtwork(name: name)
                }
                pending.append(contentsOf: parents[identifier] ?? [])
            }
        }
        let name: String = switch family {
        case "iPad": "ipad"
        case "iPhone": "iphone"
        case "Apple Watch": "applewatch"
        case "Apple TV": "tv"
        case "Apple Vision", "visionOS": "visionpro"
        case "Mac": "desktopcomputer"
        default: "externaldrive"
        }
        return DeviceSymbolArtwork(name: name)
    }
}

struct SidebarDeviceArtwork: View {
    let model: DeviceArtworkModel
    let isActive: Bool
    let isEmphasized: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var background: AnyShapeStyle {
        if isEmphasized {
            return isActive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary)
        }
        return AnyShapeStyle(Color(nsColor: isActive ? .controlColor : .tertiarySystemFill))
    }

    private var fill: AnyShapeStyle {
        if !isActive {
            return isEmphasized ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color(nsColor: .secondarySystemFill))
        }
        return AnyShapeStyle(Gradient(colors: [
            Color.blue.mix(with: .white, by: 0.13, in: .perceptual),
            Color.cyan.mix(with: .white, by: 0.13, in: .perceptual),
        ]))
    }

    private var outline: AnyShapeStyle {
        if isActive { return AnyShapeStyle(Color.black) }
        return isEmphasized ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color(nsColor: .tertiaryLabelColor))
    }

    var body: some View {
        ZStack {
            Circle().fill(background)
                .overlay {
                    Circle().strokeBorder(
                        Color(nsColor: isActive && !isEmphasized && colorScheme == .light ? .tertiarySystemFill : .clear),
                        lineWidth: 1)
                }
            if let symbol = model.symbol {
                symbol.image
                    .symbolRenderingMode(.palette)
                    .resizable()
                    .symbolVariant(.none)
                    .foregroundStyle(outline, fill)
                .fontWeight(.thin)
                .aspectRatio(contentMode: .fit)
                .frame(width: 32 * 0.66, height: 32 * 0.66)
            }
        }
        .frame(width: 32, height: 32)
        .environment(\.backgroundProminence, isEmphasized ? .increased : .standard)
        .accessibilityHidden(true)
    }
}
