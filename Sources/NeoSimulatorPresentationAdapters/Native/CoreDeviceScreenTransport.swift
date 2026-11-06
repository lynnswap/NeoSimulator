import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Security

@MainActor
package enum CoreDeviceScreenTransport {
    /// Opens the primary display through Screen Sharing or the device's chosen Mac capture source,
    /// and an app-resize display through CoreDevice's media stream.
    package static func make(_ device: CoreDeviceDevice, contentView: NSView, displayUniqueID: String?,
                     captureSources: any RemoteScreenCaptureSourceCatalog) async throws -> any RemoteScreenTransport {
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: device.identifier)
        if displayUniqueID == nil, let url = try await remote.vncURL() {
            return try await ScreenSharingDeviceTransport(remote: remote, url: url, contentView: contentView)
        }
        guard try remote.supports("com.apple.coredevice.feature.viewdevicescreen") else {
            throw RemoteScreenError.unavailable("remote-screen-capability", "The device does not currently expose a screen connection.")
        }
        guard let displayUniqueID else {
            // Capture sources do not reveal their device, so only an explicit choice selects one.
            guard let source = captureSources.chosenSource(for: device.identifier) else {
                throw RemoteScreenCaptureSourceError(reason: .unchosen)
            }
            try await captureSources.waitUntilConnected(source)
            try await CoreDeviceRuntime.loadDeviceKit()
            return try await CoreDeviceCaptureTransport(remote: remote, source: source, contentView: contentView)
        }
        guard try hasMediaStreamEntitlement() else {
            throw RemoteScreenError.unavailable("remote-screen-entitlement", "This build of NeoSimulator cannot open the app's display because it lacks the video conferencing entitlement CoreDevice's display stream requires.")
        }
        try await CoreDeviceRuntime.loadDeviceKit()
        return try await CoreDeviceMediaStreamTransport(remote: remote, contentView: contentView, displayUniqueID: displayUniqueID)
    }

    /// Reads the device's primary display for its frame, without opening a screen connection.
    package static func primaryDisplay(_ device: CoreDeviceDevice) async throws -> RemoteDeviceDisplay? {
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: device.identifier)
        guard try remote.supports("com.apple.coredevice.feature.getdisplayinfo") else { return nil }
        return try await CoreDeviceDisplayGeometry.primaryDisplay(of: remote)
    }

    /// avconferenced rejects a stream from a process without this entitlement, and the native
    /// activation then never returns, so an unentitled build must not start the stream.
    private static func hasMediaStreamEntitlement() throws -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            throw RemoteScreenError.software("remote-screen-entitlement", "Could not inspect this app's entitlements before opening the device's display stream.")
        }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.videoconference.allow-conferencing" as CFString, &error)
        if value == nil, let error { throw error.takeRetainedValue() }
        return value as? Bool == true
    }

    /// Resizing shows the app on a dedicated display, which only the media stream can show.
    package static func resizeTransport(_ device: CoreDeviceDevice) async throws -> (any AppResizeTransport)? {
        guard try hasMediaStreamEntitlement() else { return nil }
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: device.identifier)
        guard try remote.supports("com.apple.coredevice.feature.viewdevicescreen"),
              try remote.supports(CoreDeviceScreenInput.universalHIDFeature) else { return nil }
        return try await CoreDeviceAppResizeTransport.make(deviceIdentifier: device.identifier)
    }
}
