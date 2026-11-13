import AppKit
import Foundation
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
import Observation
import SwiftUI
import Synchronization
import Testing
import IOSurface
@testable import NeoSimulatorManager
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorSidebar

extension ManagerModelTests {
    @Test func aThumbnailWaitsForTheBootedSimulatorsScreenAdapter() async throws {
        let adapter = NSObject()
        var reads = 0
        var waits = 0
        let connected = try await SimulatorScreenThumbnail.waitForAdapter(read: {
            reads += 1
            return reads < 3 ? nil : adapter
        }, wait: { waits += 1 })
        #expect(connected === adapter)
        #expect(waits == 2)
        await #expect(throws: CancellationError.self) {
            _ = try await SimulatorScreenThumbnail.waitForAdapter(read: { nil }, wait: { throw CancellationError() })
        }
    }

    @Test func thumbnailsReleaseLiveSurfacesAndKeepOnlyFrozenImagesOffscreen() async throws {
        let device = SimulatorHostDevice(identifier: "thumbnail", name: "Phone", descriptiveName: "Phone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted")
        let identifier = InventoryDevice.simulator(device).id
        let source = ThumbnailTestSource()
        var receive: ((DeviceThumbnailFrame?) -> Void)?
        let store = DeviceThumbnailStore { _, frame, _ in receive = frame; return source }
        store.update(visible: [device], booted: [device])
        try await wait { receive != nil }
        let surface = try #require(IOSurface(properties: [.width: 128, .height: 256, .bytesPerElement: 4,
                                                          .pixelFormat: 0x42475241]))
        receive?(DeviceThumbnailFrame(surface: surface))
        #expect(store.frame(for: identifier)?.surface === surface)
        store.update(visible: [], booted: [device])
        #expect(source.stops == 1)
        #expect(store.frame(for: identifier) == nil)
        try await wait { store.image(for: identifier) != nil }
        let image = try #require(store.image(for: identifier))
        #expect(image.width == 48 && image.height == 96)
        // A queued callback from the stopped subscription cannot replace the frozen image.
        receive?(DeviceThumbnailFrame(surface: surface))
        #expect(store.frame(for: identifier) == nil)
        #expect(store.image(for: identifier) === image)
        store.update(visible: [], booted: [])
        #expect(store.image(for: identifier) == nil)
    }

    @Test func visibleThumbnailsRecoverFromConnectionAndStreamFailures() async throws {
        let device = SimulatorHostDevice(identifier: "thumbnail-retry", name: "Phone", descriptiveName: "Phone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted")
        let identifier = InventoryDevice.simulator(device).id
        var attempts = 0
        var sources: [Int: ThumbnailTestSource] = [:]
        var receive: [Int: (DeviceThumbnailFrame?) -> Void] = [:]
        var fail: [Int: (any Error) -> Void] = [:]
        let store = DeviceThumbnailStore(connect: { _, frame, failure in
            attempts += 1
            if attempts == 1 { throw SimulatorError.unavailable("Screen is still starting") }
            let source = ThumbnailTestSource()
            sources[attempts] = source
            receive[attempts] = frame
            fail[attempts] = failure
            return source
        }, waitToRetry: { _ in await Task.yield() })
        store.update(visible: [device], booted: [device])
        try await wait { sources[2] != nil }
        fail[2]?(SimulatorError.unavailable("Screen connection ended"))
        try await wait { sources[3] != nil }
        #expect(sources[2]?.stops == 1)
        let surface = try #require(IOSurface(properties: [.width: 16, .height: 16, .bytesPerElement: 4,
                                                          .pixelFormat: 0x42475241]))
        receive[3]?(DeviceThumbnailFrame(surface: surface))
        receive[2]?(nil)
        #expect(store.frame(for: identifier)?.surface === surface)
        store.update(visible: [], booted: [device])
        fail[3]?(SimulatorError.unavailable("Late callback"))
        await Task.yield()
        #expect(attempts == 3 && sources[3]?.stops == 1)
    }

    @Test func frozenThumbnailsKeepTheDeviceBezelAndRotation() async throws {
        let context = try #require(CGContext(data: nil, width: 12, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 24))
        let bezel = try #require(context.makeImage())
        let chrome = DeviceThumbnailChrome(image: bezel, mask: nil, size: CGSize(width: 120, height: 240),
            displayRect: CGRect(x: 20, y: 40, width: 80, height: 160), cornerRadius: 0)
        let surface = try #require(IOSurface(properties: [.width: 80, .height: 160, .bytesPerElement: 4,
                                                         .pixelFormat: 0x42475241]))
        IOSurfaceLock(surface, [], nil)
        IOSurfaceGetBaseAddress(surface).initializeMemory(as: UInt8.self, repeating: 255,
                                                          count: IOSurfaceGetAllocSize(surface))
        IOSurfaceUnlock(surface, [], nil)
        let image = try await DeviceThumbnailFrame(surface: surface, rotation: .pi / 2, chrome: chrome).snapshot()
        #expect(image.width == 96 && image.height == 48)
        let pixels = NSBitmapImageRep(cgImage: image)
        let edge = try #require(pixels.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        let center = try #require(pixels.colorAt(x: 48, y: 24)?.usingColorSpace(.deviceRGB))
        #expect(edge.redComponent > 0.9 && edge.greenComponent < 0.1)
        #expect(center.redComponent > 0.9 && center.greenComponent > 0.9)
    }

    @Test func thumbnailsReuseVisibleSubscriptionsAndStopOffscreenDevices() async throws {
        let devices = ["A", "B"].map { name in
            SimulatorHostDevice(identifier: name, name: name, descriptiveName: name, runtimeIdentifier: "runtime",
                                runtimeName: "iOS", productFamily: "iPhone", state: "Booted")
        }
        var sources: [String: ThumbnailTestSource] = [:]
        let thumbnails = DeviceThumbnailStore { device, _, _ in
            let source = ThumbnailTestSource()
            sources[device.identifier] = source
            return source
        }
        thumbnails.update(visible: devices, booted: devices)
        try await wait(timeout: .seconds(5)) { sources.count == 2 }
        let first = try #require(sources["A"])
        let second = try #require(sources["B"])
        thumbnails.update(visible: devices.reversed(), booted: devices)
        await Task.yield()
        #expect(sources["A"] === first && sources["B"] === second)
        #expect(first.stops == 0 && second.stops == 0)
        thumbnails.update(visible: [devices[0]], booted: devices)
        #expect(first.stops == 0 && second.stops == 1)
        thumbnails.update(visible: [], booted: devices)
        #expect(first.stops == 1 && second.stops == 1)
    }

    @Test func previewViewScreenOpensTheSelectedDevice() async throws {
        _ = NSApplication.shared
        let devices = try CoreDeviceInventoryDecoder.decode(Data(#"{"result":{"devices":[{"identifier":"A","properties":{"hardware":{"fidelity":"physical"},"state":{"name":"A"},"connection":{"state":"connected"}},"capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.viewdevicescreen"}]}]}}"#.utf8))
        let source = ManagerModelSource(devices: devices.map(InventoryDevice.remote))
        let model = SimulatorManagerModel(source: source)
        model.registry.stopReading()
        await model.refresh()
        var requested: [DeviceInventoryID] = []
        model.onDeviceOpenRequested = { requested.append($0) }
        let screens = DeviceScreens(model: model)
        let controller = ManagerWindowController(
            model: model, screens: screens,
                                                 menus: MenuController(application: nil))
        controller.window?.setFrameAutosaveName("")
        defer { controller.window?.close() }
        controller.selectDevice(.coreDevice("A"))
        let content = try #require(controller.window?.contentView)
        let viewScreen = try #require(inspectorViews(content).compactMap { $0 as? NSButton }
            .first { $0.title == "View Screen" })
        viewScreen.performClick(nil)
        #expect(requested == [.coreDevice("A")])
        try await wait(timeout: .seconds(5)) { !model.isBusy }
        let outline = try #require(inspectorViews(content).compactMap { $0 as? NSOutlineView }.first)
        #expect(NSApp.sendAction(try #require(outline.doubleAction), to: outline.target, from: outline))
        #expect(requested == [.coreDevice("A"), .coreDevice("A")])
        #expect(controller.presentationIntent.placement == .compact)
        let compactWindow = try #require(screens.compactWindow(for: .coreDevice("A")))
        #expect(compactWindow.isVisible)
        try await wait(timeout: .seconds(5)) { !model.isBusy }
        compactWindow.close()
    }

    @Test func artworkResolvesXcodeBeforeOpeningAScreen() async throws {
        let device = simulator(deviceSet: "/tmp/artwork-device-set")
        let source = ManagerModelSource(devices: [device])
        let model = SimulatorManagerModel(source: source)
        let urls = await model.artworkXcodeURLs(for: device)
        #expect(urls == [URL(fileURLWithPath: "/Applications/Test Xcode.app")])
        #expect(await source.artworkXcodeRequests == [device.id])
    }

    @Test func missingModelUsesFamilyPreview() async throws {
        let artwork = DeviceArtworkCache().artwork(modelIdentifier: nil, family: "Mac", xcodeURL: nil)
        let image = try #require(await artwork.hardwarePreview())
        let expected = try #require(NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil))
        #expect(try #require(image.tiffRepresentation) == #require(expected.tiffRepresentation))
    }
}
