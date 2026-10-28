import Foundation
import Testing

@testable import XcodeSimulatorHost

@Suite
struct DeviceInventoryTests {
    @Test func currentPropertiesKeepCommandIdentityCapabilitiesAndConnectionRecency() throws {
        let records = try CoreDeviceInventoryDecoder.decode(Self.coreDeviceJSON)
        let phone = try #require(records.first { $0.kind == .physical })
        #expect(phone.identifier == "remote-command-id")
        #expect(phone.udid == "hardware-udid")
        #expect(phone.name == "Test Phone")
        #expect(phone.modelIdentifier == "iPhone99,1")
        #expect(phone.modelName == "Test Hardware")
        #expect(phone.platform == "iOS" && phone.osVersion == "27.0" && phone.osBuild == "27A100")
        #expect(phone.connectionState == "connected" && phone.pairingState == "paired")
        #expect(phone.transportType == "wired" && phone.bootState == "booted")
        #expect(phone.isAvailable)
        #expect(phone.lastConnectedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(phone.capabilities == ["com.apple.coredevice.feature.installapp"])
        let vm = try #require(records.first { $0.kind == .virtualMachine })
        #expect(vm.identifier == "vm-command-id" && vm.udid == "vm-hardware-udid")
        #expect(!vm.isAvailable && vm.lastConnectedAt == nil)
        #expect(vm.capabilities == ["com.apple.coredevice.feature.unpairdevice"])
    }

    @Test func joinsSimctlAuthorityWithoutConflatingCommandIDsOrDeviceSets() async throws {
        let normal = Self.simulator("simulator-udid")
        let clone = Self.simulator("simulator-udid", path: "/testing")
        // A remote command ID can be the same string as a simulator UDID.
        let collision = Self.simulator("remote-command-id")
        let calls = InventoryCalls()
        let reader = DeviceInventoryReader(readSimulators: {
            DeviceInventorySnapshot(devices: [normal, clone, collision].map(InventoryDevice.simulator), issues: [])
        }, readCoreDevices: {
            await calls.recordCoreDeviceRead()
            return Self.coreDeviceJSON
        })
        let snapshot = await reader.read()
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.devices.count == 5)
        #expect(Set(snapshot.devices.map(\.id)).count == 5)
        #expect(await calls.coreDeviceReads == 1)
        let joined = try #require(snapshot.devices.first { $0.id == .simulator(udid: normal.identifier, deviceSetPath: nil) })
        #expect(joined.capabilities == ["com.apple.coredevice.feature.customizeuistyle"])
        let joinedClone = try #require(snapshot.devices.first { $0.id == clone.inventoryID })
        #expect(joinedClone.capabilities == [])
        #expect(snapshot.devices.contains { $0.id == .coreDevice("remote-command-id") })
        #expect(!snapshot.devices.contains { $0.id == .simulator(udid: "coredevice-only-simulator", deviceSetPath: nil) })
        if case .simulator(let retained) = joined {
            #expect(retained.ownerXcodeURL == normal.ownerXcodeURL)
            #expect(retained.name == normal.name && retained.modelIdentifier == normal.modelIdentifier)
            #expect(retained.deviceTypeIdentifier == "phone-type")
        } else { Issue.record("simctl record was replaced by a remote record") }
        let transport = DeviceInspectorTransport(run: { command in
            #expect(command.arguments == ["list", "--json"])
            return CommandOutput(terminationStatus: 0, stdout: Data(#"""
            {"devices":{"runtime":[{"udid":"simulator-udid","name":"Simulator Name"}]}}
            """#.utf8), stderr: Data())
        })
        if case .simulator(let retained) = joined {
            let info = await DeviceInspector(device: .simulator(retained.inventoryCopy(owners: [])),
                simulatorXcodeURL: normal.ownerXcodeURL, transport: transport).info()
            #expect(info.issues.isEmpty)
            #expect(info.fields["connection"] == .object([
                "state": .string("disconnected"), "pairingState": .string("paired"),
                "transportType": .string("sameMachine"), "lastConnectionDate": .date(Date(timeIntervalSinceReferenceDate: 100)),
            ]))
            let failedInfo = await DeviceInspector(device: joined, simulatorXcodeURL: normal.ownerXcodeURL,
                transport: .init(run: { _ in throw CLIError.io("info-fixture", "Catalog unavailable") })).info()
            #expect(failedInfo.fields == ["connection": try #require(info.fields["connection"])])
            #expect(failedInfo.issues.count == 1)
            #expect((failedInfo.issues.first?.error as? CLIError)?.identifier == "info-fixture")
        }
        let cloneInfo = await DeviceInspector(device: joinedClone, simulatorXcodeURL: clone.ownerXcodeURL,
                                              transport: transport).info()
        #expect(cloneInfo.issues.isEmpty && cloneInfo.fields["connection"] == nil)
    }

    @Test(arguments: [true, false])
    func sourceFailuresRetainSuccessfulDevicesAndOriginalError(_ failCoreDevice: Bool) async throws {
        let sourceError = CLIError.io("inventory-fixture", "fixture query failed")
        let snapshot = await DeviceInventoryReader(readSimulators: {
            failCoreDevice
                ? DeviceInventorySnapshot(devices: [.simulator(Self.simulator("simulator-udid"))], issues: [])
                : DeviceInventorySnapshot(devices: [], issues: [.init(source: .simulators(xcodeURL: nil, deviceSetPath: nil), error: sourceError)])
        }, readCoreDevices: {
            if failCoreDevice { throw sourceError }
            return Self.coreDeviceJSON
        }).read()
        let issue = try #require(snapshot.issues.first)
        #expect(snapshot.issues.count == 1)
        #expect((issue.error as? CLIError)?.identifier == "inventory-fixture")
        if failCoreDevice {
            #expect(issue.source == .coreDevice)
            #expect(snapshot.devices.map(\.id) == [.simulator(udid: "simulator-udid", deviceSetPath: nil)])
        } else {
            #expect(issue.source == .simulators(xcodeURL: nil, deviceSetPath: nil))
            #expect(Set(snapshot.devices.map(\.id)) == [.coreDevice("remote-command-id"), .coreDevice("vm-command-id")])
        }
    }

    @Test func simulatorInventoryKeepsUnavailableAndOrphanedRuntimesWithoutChangingLaunchCandidates() throws {
        let launchCandidates = try SimulatorDeviceCatalog.decode(Self.simulatorJSON)
        let inventory = try SimulatorDeviceCatalog.decode(Self.simulatorJSON, deviceSetPath: "/testing", includeUnavailable: true)
        #expect(launchCandidates.map(\.identifier) == ["ready"])
        #expect(Set(inventory.map(\.identifier)) == ["ready", "unavailable", "orphan"])
        #expect(inventory.allSatisfy { $0.deviceSetPath == "/testing" })
        #expect(inventory.first { $0.identifier == "unavailable" }?.isAvailable == false)
        #expect(inventory.first { $0.identifier == "ready" }?.pairIdentifiers == ["pair-id"])
        #expect(inventory.first { $0.identifier == "ready" }?.deviceTypeIdentifier == "phone-type")
        #expect(inventory.first { $0.identifier == "unavailable" }?.pairIdentifiers == ["pair-id"])
        let orphan = try #require(inventory.first { $0.identifier == "orphan" })
        #expect(!orphan.isAvailable && orphan.runtimeIdentifier == "removed-runtime")
        #expect(orphan.lastUsedAt == Date(timeIntervalSince1970: 0.25))
    }

    @Test func activePairingUsesTheOppositeDeviceInTheSameSetWithoutDiscardingOtherPairs() throws {
        var catalog = try #require(JSONSerialization.jsonObject(with: Self.simulatorJSON) as? [String: Any])
        catalog["pairs"] = [
            "active": ["watch": ["udid": "unavailable"], "phone": ["udid": "ready"], "state": "(active, disconnected)"],
            "inactive": ["watch": ["udid": "orphan"], "phone": ["udid": "ready"], "state": "(inactive, connected)"],
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog)
        let devices = try SimulatorDeviceCatalog.decode(data, deviceSetPath: "/testing", includeUnavailable: true)
        let phone = try #require(devices.first { $0.identifier == "ready" })
        let watch = try #require(devices.first { $0.identifier == "unavailable" })
        #expect(phone.activePairedDeviceID == .simulator(udid: watch.identifier, deviceSetPath: "/testing"))
        #expect(watch.activePairedDeviceID == phone.inventoryID)
        #expect(devices.first { $0.identifier == "orphan" }?.activePairedDeviceID == nil)
        #expect(phone.pairIdentifiers == ["active", "inactive"])
        let copied = phone.inventoryCopy(ownerXcodeURL: URL(fileURLWithPath: "/Applications/Owner.app"), capabilities: ["feature"])
        #expect(copied.activePairedDeviceID == phone.activePairedDeviceID)
        #expect(copied.capabilities == ["feature"])
        // Older catalogs and unavailable pair records do not establish an active relationship.
        #expect(try SimulatorDeviceCatalog.decode(Self.simulatorJSON).first?.activePairedDeviceID == nil)
        catalog["pairs"] = ["unknown": ["watch": ["udid": "unavailable"], "phone": ["udid": "ready"], "state": "(unavailable)"]]
        #expect(try SimulatorDeviceCatalog.decode(JSONSerialization.data(withJSONObject: catalog), includeUnavailable: true)
            .allSatisfy { $0.activePairedDeviceID == nil })
    }

    @Test func testingCatalogFailurePreservesNormalDevicesAndReportsItsExactSource() throws {
        let newer = URL(fileURLWithPath: "/Applications/Xcode-New.app")
        let older = URL(fileURLWithPath: "/Applications/Xcode-Old.app")
        let snapshot = SimulatorInventoryReader(installations: [newer, older], testingDeviceSetPath: "/testing") { xcode, path in
            if xcode == newer, path != nil { throw CLIError.io("testing-inventory", "fixture testing set unavailable") }
            if xcode == older, path == nil {
                return Data(String(decoding: Self.simulatorJSON, as: UTF8.self).replacingOccurrences(
                    of: "\"name\":\"Unavailable\",\"state\":\"Shutdown\",\"isAvailable\":false",
                    with: "\"name\":\"Unavailable\",\"state\":\"Shutdown\",\"isAvailable\":true").utf8)
            }
            return Self.simulatorJSON
        }.read()
        #expect(snapshot.devices.count == 6)
        #expect(Set(snapshot.devices.map(\.id)).count == 6)
        let issue = try #require(snapshot.issues.first)
        #expect(snapshot.issues.count == 1)
        #expect(issue.source == .simulators(xcodeURL: newer, deviceSetPath: "/testing"))
        #expect((issue.error as? CLIError)?.identifier == "testing-inventory")
        #expect(snapshot.devices.first { $0.id == .simulator(udid: "unavailable", deviceSetPath: "/testing") }?.isAvailable == false)
        #expect(snapshot.devices.first { $0.id == .simulator(udid: "unavailable", deviceSetPath: nil) }?.isAvailable == true)
    }

    private static func simulator(_ identifier: String, path: String? = nil) -> SimulatorHostDevice {
        SimulatorHostDevice(identifier: identifier, name: "Simulator Name", descriptiveName: "Simulator Name — iOS 27.0",
            runtimeIdentifier: "runtime", runtimeName: "iOS 27.0", productFamily: "iPhone", state: "Booted",
            ownerXcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"), deviceSetPath: path, modelIdentifier: "iPhone99,2",
            deviceTypeIdentifier: "phone-type")
    }

    private static let coreDeviceJSON = Data(#"""
    {"result":{"devices":[
      {"identifier":"remote-command-id","hardwareProperties":{"udid":"wrong-deprecated-value"},
       "deviceProperties":{"name":"Wrong Deprecated Name"},"connectionProperties":{"lastConnectionDate":"invalid"},
       "properties":{"hardware":{"reality":"physical","udid":"hardware-udid","productType":"iPhone99,1","marketingName":"Test Hardware","platform":"iOS"},
         "state":{"name":"Test Phone","bootState":"booted"},
         "software":{"osVersionNumber":{"stringValue":"27.0"},"osBuildVersions":{"buildVersion":{"name":"27A100"}}},
         "connection":{"state":"connected","pairingState":"paired","transportType":"wired","lastConnectionDate":100}},
       "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.installapp","name":"Install Application"}]},
      {"identifier":"vm-command-id","properties":{"hardware":{"reality":"virtual","udid":"vm-hardware-udid","productType":"iPhone99,11"},
         "state":{"name":"Test VM"},"connection":{"state":"unavailable"}},
       "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.unpairdevice"}]},
      {"identifier":"simulator-udid","properties":{"hardware":{"reality":"simulated","udid":"simulator-udid"},
         "state":{"name":"CoreDevice Simulator Name"},
         "connection":{"state":"disconnected","pairingState":"paired","transportType":"sameMachine","lastConnectionDate":100}},
       "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.customizeuistyle"}]},
      {"identifier":"coredevice-only-simulator","properties":{"hardware":{"reality":"simulated","udid":"coredevice-only-simulator"}}}
    ]}}
    """#.utf8)

    private static let simulatorJSON = Data(#"""
    {"devicetypes":[{"identifier":"phone-type","productFamily":"iPhone","modelIdentifier":"iPhone99,2"}],
     "runtimes":[{"identifier":"runtime","name":"iOS 27.0","isAvailable":true}],
     "devices":{"runtime":[
       {"udid":"ready","deviceTypeIdentifier":"phone-type","name":"Ready","state":"Booted","isAvailable":true},
       {"udid":"unavailable","deviceTypeIdentifier":"phone-type","name":"Unavailable","state":"Shutdown","isAvailable":false}],
       "removed-runtime":[{"udid":"orphan","deviceTypeIdentifier":"removed-type","name":"Orphan","state":"Shutdown","isAvailable":false,"lastUsedAt":"1970-01-01T00:00:00.250Z"}]},
     "pairs":{"pair-id":{"watch":{"udid":"unavailable"},"phone":{"udid":"ready"}}}}
    """#.utf8)
}

private actor InventoryCalls {
    private(set) var coreDeviceReads = 0
    func recordCoreDeviceRead() { coreDeviceReads += 1 }
}
