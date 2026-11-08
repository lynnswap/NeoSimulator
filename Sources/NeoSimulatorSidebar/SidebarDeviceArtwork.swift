import AppKit
import NeoSimulatorDeviceScreens
import NeoSimulatorPresentationAdapters
import SwiftUI

struct SidebarDeviceArtwork: View {
    let model: DeviceArtworkModel
    let isActive: Bool
    let isEmphasized: Bool
    var showsSymbol = true
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
                Group {
                    if let resource = symbol.resource {
                        resource.palette(primary: outline, secondary: fill)
                            .frame(width: 32 * 0.66, height: 32 * 0.66)
                    } else {
                        Image(systemName: symbol.name)
                            .symbolRenderingMode(.palette)
                            .resizable()
                            .symbolVariant(.none)
                            .foregroundStyle(outline, fill)
                            .fontWeight(.thin)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32 * 0.66, height: 32 * 0.66)
                    }
                }
                .opacity(showsSymbol ? 1 : 0)
            }
        }
        .frame(width: 32, height: 32)
        .environment(\.backgroundProminence, isEmphasized ? .increased : .standard)
        .accessibilityHidden(true)
    }
}

struct SidebarDeviceLabels: View {
    let name: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
