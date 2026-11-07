@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorKit
@testable import NeoSimulatorHostSupport
import Darwin
import Foundation
import Testing


@Suite
struct DeviceInventoryTests {
    @Test func nativeInventoryKeepsUnavailableDevicesAndPairIdentityInTheirOwnSet() throws {
        func record(_ id: String, family: String, available: Bool) -> SimulatorInventorySnapshot.Device {
            .init(identifier: id, name: id, runtimeIdentifier: "runtime", runtimeName: "OS",
                  productFamily: family, state: "Shutdown", modelIdentifier: "model", deviceTypeIdentifier: "type",
                  isAvailable: available, lastUsedAt: Date(timeIntervalSinceReferenceDate: 10), dataPath: nil)
        }
        let snapshot = SimulatorInventorySnapshot(devices: [
            record("phone", family: "iPhone", available: true),
            record("watch", family: "Apple Watch", available: false),
            record("unsupported", family: "Other", available: true),
        ], pairs: [.init(identifier: "pair", watch: "watch", phone: "phone", isActive: true)])
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let available = SimulatorDeviceCatalog.devices(in: snapshot, deviceSetPath: "/testing", catalogXcodeURL: xcode)
        #expect(available.map(\.identifier) == ["phone"])
        let phone = try #require(available.first)
        #expect(phone.activePairedDeviceID == .simulator(udid: "watch", deviceSetPath: "/testing"))
        #expect(phone.pairIdentifiers == ["pair"] && phone.catalogXcodeURL == xcode)
        #expect(phone.modelIdentifier == "model" && phone.lastUsedAt == Date(timeIntervalSinceReferenceDate: 10))
        let all = SimulatorDeviceCatalog.devices(in: snapshot, includeUnavailable: true, catalogXcodeURL: xcode)
        let watch = try #require(all.first { $0.identifier == "watch" })
        #expect(!watch.isAvailable && watch.catalogXcodeURL == nil)
        #expect(watch.activePairedDeviceID == .simulator(udid: "phone", deviceSetPath: nil))
        #expect(all.first { $0.identifier == "unsupported" }?.productFamily == "")
    }

    @Test func everySpellingOfASimulatorIsTheSameIdentity() throws {
        let canonical = DeviceInventoryID.simulator(udid: "ABC-DEF", deviceSetPath: "/tmp/Fixture")
        let device = InventoryDevice.simulator(SimulatorHostDevice(identifier: "abc-def", name: "Fixture", descriptiveName: "Fixture",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted", deviceSetPath: "/tmp/Fixture/"))
        let address = DeviceAddress(identifier: "abc-def", deviceSetPath: "/tmp/Fixture")
        let spellings: [DeviceInventoryID] = [
            .simulator(udid: "abc-def", deviceSetPath: "/tmp/Other/../Fixture/"),
            .simulator(SimulatorDeviceIdentifier("abc-def", deviceSetPath: "/tmp/Fixture")),
            .simulator(udid: address.identifier, deviceSetPath: address.deviceSetPath),
            try JSONDecoder().decode(DeviceInventoryID.self, from: JSONEncoder().encode(canonical)),
            device.id,
        ]
        #expect(spellings.allSatisfy { $0 == canonical })
        #expect(canonical != .simulator(udid: "ABC-DEF", deviceSetPath: nil))
        // CoreDevice names its own destinations, and they keep the spelling it gave them.
        #expect(DeviceInventoryID.coreDevice("abc-def") != .coreDevice("ABC-DEF"))
    }

    @Test(arguments: [false, true])
    func currentPropertiesKeepCommandIdentityCapabilitiesAndConnectionRecency(previousFieldNames: Bool) throws {
        let json = previousFieldNames ? String(decoding: Self.coreDeviceJSON, as: UTF8.self)
            .replacingOccurrences(of: "\"fidelity\"", with: "\"reality\"")
            .replacingOccurrences(of: "\"osPlatform\"", with: "\"platform\"") : String(decoding: Self.coreDeviceJSON, as: UTF8.self)
        let records = try CoreDeviceInventoryDecoder.decode(Data(json.utf8))
        let phone = try #require(records.first { $0.kind == .physical })
        #expect(phone.identifier == "remote-command-id")
        #expect(phone.udid == "hardware-udid")
        #expect(phone.name == "Test Phone" && phone.reportedName == "Test Phone")
        #expect(phone.modelIdentifier == "iPhone99,1")
        #expect(phone.modelName == "Test Hardware")
        #expect(phone.cpuType?.type == 16777228)
        #expect(phone.cpuType?.subtype == Int32(bitPattern: 0x80000002))
        #expect(phone.platform == "iOS" && phone.osVersion == "27.0" && phone.osBuild == "27A100")
        // Malformed comparison metadata keeps the record and its display build.
        #expect(phone.osBuildUpdate == nil)
        #expect(phone.connectionState == "connected" && phone.pairingState == "paired")
        #expect(phone.transportType == "wired" && phone.bootState == "booted")
        #expect(phone.isAvailable)
        #expect(phone.lastConnectedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(phone.capabilities == ["com.apple.coredevice.feature.installapp"])
        let vm = try #require(records.first { $0.kind == .virtualMachine })
        #expect(vm.identifier == "vm-command-id" && vm.udid == "vm-hardware-udid")
        #expect(!vm.isAvailable && vm.lastConnectedAt == nil)
        #expect(vm.capabilities == ["com.apple.coredevice.feature.unpairdevice"])
        let base = try #require(vm.osBuildUpdate)
        let simulator = try #require(records.first { $0.identifier == "simulator-command-id" })
        #expect(simulator.osBuild == "24B114")
        // The supplemental 24B91016s natively precedes 24B114, although its name sorts after it.
        let supplemental = try #require(simulator.osBuildUpdate)
        #expect(supplemental < base)
        let unnamed = try #require(records.first { $0.identifier == "coredevice-only-simulator" })
        #expect(unnamed.name == unnamed.identifier && unnamed.reportedName == nil)
        // CoreDevice defines no order for fewer than five revision components.
        #expect(unnamed.osBuildUpdate == nil)
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
        let snapshot = try await reader.read()
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.devices.count == 5)
        #expect(Set(snapshot.devices.map(\.id)).count == 5)
        #expect(await calls.coreDeviceReads == 1)
        let joined = try #require(snapshot.devices.first { $0.id == .simulator(udid: normal.identifier, deviceSetPath: nil) })
        #expect(joined.capabilities == ["com.apple.coredevice.feature.customizeuistyle"])
        #expect(joined.lastConnectionDate == Date(timeIntervalSinceReferenceDate: 100))
        let joinedClone = try #require(snapshot.devices.first { $0.id == clone.inventoryID })
        #expect(joinedClone.capabilities == [] && joinedClone.lastConnectionDate == nil)
        #expect(snapshot.devices.contains { $0.id == .coreDevice("remote-command-id") })
        #expect(!snapshot.devices.contains { $0.id == .simulator(udid: "coredevice-only-simulator", deviceSetPath: nil) })
        if case .simulator(let retained) = joined {
            #expect(retained.ownerXcodeURL == normal.ownerXcodeURL)
            #expect(retained.catalogXcodeURL == normal.catalogXcodeURL)
            #expect(retained.name == normal.name && retained.modelIdentifier == normal.modelIdentifier)
            #expect(retained.deviceTypeIdentifier == "phone-type")
        } else { Issue.record("simctl record was replaced by a remote record") }
        let transport = DeviceInspectorTransport(run: { command in
            #expect(command.arguments == ["list", "--json"])
            return CommandOutput(terminationStatus: 0, stdout: Data(#"""
            {"devices":{"runtime":[{"udid":"simulator-udid","name":"Simulator Name","state":"Booted"}]}}
            """#.utf8), stderr: Data())
        })
        if case .simulator(let retained) = joined {
            let info = await DeviceInspector(device: .simulator(retained.inventoryCopy(owners: [])),
                simulatorXcodeURL: normal.ownerXcodeURL, transport: transport).info()
            #expect(info.issues.isEmpty)
            let knownFields: [String: DeviceInspectorValue] = [
                "coreDeviceIdentifier": .string("simulator-command-id"),
                "hardware": .object(["cpuType": .object(["type": .integer(16777228), "subtype": .integer(0)]),
                    "platform": .string("iOS"), "productType": .string("iPhone99,2"), "reality": .string("simulated")]),
                "bootState": .string("shutdown"), "preparednessState": .integer(0),
                "connection": .object(["state": .string("disconnected"), "pairingState": .string("paired"),
                    "transportType": .string("sameMachine"), "lastConnectionDate": .date(Date(timeIntervalSinceReferenceDate: 100))]),
            ]
            #expect(info.fields.filter { knownFields[$0.key] != nil } == knownFields)
            #expect(info.fields["state"] == .string("Booted"))
            let failedInfo = await DeviceInspector(device: joined, simulatorXcodeURL: normal.ownerXcodeURL,
                transport: .init(run: { _ in throw DeviceIOError.io("info-fixture", "Catalog unavailable") })).info()
            #expect(failedInfo.fields == knownFields)
            #expect(failedInfo.issues.count == 1)
            #expect((failedInfo.issues.first?.error as? DeviceIOError)?.identifier == "info-fixture")
        }
        let cloneInfo = await DeviceInspector(device: joinedClone, simulatorXcodeURL: clone.ownerXcodeURL,
                                              transport: transport).info()
        #expect(cloneInfo.issues.isEmpty)
        #expect(["connection", "coreDeviceIdentifier", "hardware", "bootState", "preparednessState"].allSatisfy { cloneInfo.fields[$0] == nil })
    }

    @Test(arguments: [true, false])
    func sourceFailuresRetainSuccessfulDevicesAndOriginalError(_ failCoreDevice: Bool) async throws {
        let sourceError = DeviceIOError.io("inventory-fixture", "fixture query failed")
        let snapshot = try await DeviceInventoryReader(readSimulators: {
            failCoreDevice
                ? DeviceInventorySnapshot(devices: [.simulator(Self.simulator("simulator-udid"))], issues: [])
                : DeviceInventorySnapshot(devices: [], issues: [.init(source: .simulators(xcodeURL: nil, deviceSetPath: nil), error: sourceError)])
        }, readCoreDevices: {
            if failCoreDevice { throw sourceError }
            return Self.coreDeviceJSON
        }).read()
        let issue = try #require(snapshot.issues.first)
        #expect(snapshot.issues.count == 1)
        #expect((issue.error as? DeviceIOError)?.identifier == "inventory-fixture")
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

    @Test func unusedSimulatorKeepsItsCreationDateThroughInventoryJoins() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let createdAt = try #require(directory.resourceValues(forKeys: [.creationDateKey]).creationDate)
        var catalog = try #require(JSONSerialization.jsonObject(with: Self.simulatorJSON) as? [String: Any])
        var devices = try #require(catalog["devices"] as? [String: [[String: Any]]])
        devices["runtime"]?[0]["dataPath"] = directory.appending(path: "data").path
        catalog["devices"] = devices
        let decoded = try SimulatorDeviceCatalog.decode(JSONSerialization.data(withJSONObject: catalog))
        let device = try #require(decoded.first)
        #expect(device.lastUsedAt == nil && device.createdAt == createdAt)
        let snapshot = try await DeviceInventoryReader(
            readSimulators: { .init(devices: [.simulator(device)], issues: []) },
            readCoreDevices: { Data(#"{"result":{"devices":[]}}"#.utf8) }).read()
        #expect(snapshot.devices.first?.lastActivityDate == createdAt)
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

    /// The other source has devices to offer, but publishing them would make the stopped source's devices look removed.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func aHeldChildStoppedByItsReadsEndsTheInventoryWithNothingToPublish(_ holdsCoreDevice: Bool) async throws {
        let directory = try TemporaryTestDirectory()
        let held = try HeldChildren(in: directory.url)
        defer { held.release() }
        let reads = CommandReads()
        let command = try held.command(then: "", policy: .cancellable)
        let simulator = Self.simulator("simulator-udid")
        let reader = DeviceInventoryReader(readSimulators: {
            if holdsCoreDevice { return DeviceInventorySnapshot(devices: [.simulator(simulator)], issues: []) }
            return try await SimulatorInventoryReader(installations: [URL(fileURLWithPath: "/Applications/Xcode.app")], testingDeviceSetPath: nil) { xcode, path in
                try await SimulatorDeviceCatalog.decode(reads.run(command).stdout, deviceSetPath: path,
                                                       includeUnavailable: true, catalogXcodeURL: xcode)
            }.read()
        }, readCoreDevices: {
            holdsCoreDevice ? try await reads.run(command).stdout : Self.coreDeviceJSON
        })
        let reading = Task { try await reader.read() }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        reads.stop()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
    }

    /// Runs the real controller and Xcode discovery with a substitute for the embedded host, whose catalog read holds the operation queue.
    @Test(.timeLimit(.minutes(1))) func stoppingAHeldCreationCatalogReadFreesTheOperationQueue() async throws {
        let directory = try TemporaryTestDirectory()
        let held = try HeldChildren(in: directory.url)
        defer { held.release() }
        let bundle = directory.url.appendingPathComponent("Host.app", isDirectory: true)
        let executables = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": ToolConstants.neoHostBundleIdentifier, "CFBundleExecutable": "host", "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try held.writeExecutable(to: executables.appendingPathComponent("host"))
        let controller = SimulatorHostController(rendererApplicationURL: bundle)
        let catalog = Task { try await controller.creationCatalog() }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        controller.stopReads()
        await #expect(throws: CancellationError.self) { try await catalog.value }
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
        #expect(try await controller.operation(.hostTransition) { true })
    }

    @Test func cancellingTheSelectedXcodeReadEndsDiscoveryInsteadOfSkippingThatXcode() async throws {
        let inspector = XcodeInstallationInspector(environment: [:], readSelection: { throw CancellationError() })
        await #expect(throws: CancellationError.self) { _ = try await inspector.selectedXcodeIfUsable() }
        await #expect(throws: CancellationError.self) { _ = try await inspector.discoverXcodes() }
        let missing = XcodeInstallationInspector(environment: [:], readSelection: {
            throw DeviceIOError.unavailable("selected-xcode", "No selection")
        })
        #expect(try await missing.selectedXcodeIfUsable() == nil)
    }

    @Test func testingCatalogFailurePreservesNormalDevicesAndReportsItsExactSource() async throws {
        let newer = URL(fileURLWithPath: "/Applications/Xcode-New.app")
        let older = URL(fileURLWithPath: "/Applications/Xcode-Old.app")
        let snapshot = try await SimulatorInventoryReader(installations: [newer, older], testingDeviceSetPath: "/testing") { xcode, path in
            if xcode == newer, path != nil { throw DeviceIOError.io("testing-inventory", "fixture testing set unavailable") }
            if xcode == older, path == nil {
                return try SimulatorDeviceCatalog.decode(Data(String(decoding: Self.simulatorJSON, as: UTF8.self).replacingOccurrences(
                    of: "\"name\":\"Unavailable\",\"state\":\"Shutdown\",\"isAvailable\":false",
                    with: "\"name\":\"Unavailable\",\"state\":\"Shutdown\",\"isAvailable\":true").utf8),
                    deviceSetPath: path, includeUnavailable: true, catalogXcodeURL: xcode)
            }
            return try SimulatorDeviceCatalog.decode(Self.simulatorJSON, deviceSetPath: path, includeUnavailable: true, catalogXcodeURL: xcode)
        }.read()
        #expect(snapshot.devices.count == 6)
        #expect(Set(snapshot.devices.map(\.id)).count == 6)
        let issue = try #require(snapshot.issues.first)
        #expect(snapshot.issues.count == 1)
        #expect(issue.source == .simulators(xcodeURL: newer, deviceSetPath: "/testing"))
        #expect((issue.error as? DeviceIOError)?.identifier == "testing-inventory")
        #expect(snapshot.devices.first { $0.id == .simulator(udid: "unavailable", deviceSetPath: "/testing") }?.isAvailable == false)
        #expect(snapshot.devices.first { $0.id == .simulator(udid: "unavailable", deviceSetPath: nil) }?.isAvailable == true)
        func catalogXcodeURL(_ identifier: String, _ path: String?) -> URL? {
            guard case .simulator(let device) = snapshot.devices.first(where: { $0.id == .simulator(udid: identifier, deviceSetPath: path) })
            else { return nil }
            return device.catalogXcodeURL
        }
        // The kept entry records the Xcode whose catalog first listed it as available.
        #expect(catalogXcodeURL("ready", nil) == newer)
        #expect(catalogXcodeURL("unavailable", nil) == older)
        #expect(catalogXcodeURL("ready", "/testing") == older)
        #expect(catalogXcodeURL("unavailable", "/testing") == nil)
    }

    @Test(arguments: [false, true])
    func simulatorBootIdentitySurvivesInventoryJoinsAndReadFailures(fails: Bool) async throws {
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let boot = Date(timeIntervalSinceReferenceDate: 400)
        let snapshot = try await SimulatorInventoryReader(installations: [xcode], testingDeviceSetPath: nil,
            readBootDates: { _, _ in
                if fails { throw DeviceIOError.io("boot-identity", "unavailable") }
                return ["ready": boot, "unavailable": boot]
            }, readCatalog: { xcode, path in
                try SimulatorDeviceCatalog.decode(Self.simulatorJSON, deviceSetPath: path, includeUnavailable: true, catalogXcodeURL: xcode)
            }).read()
        let joined = try await DeviceInventoryReader(readSimulators: { snapshot },
            readCoreDevices: { Data(#"{"result":{"devices":[]}}"#.utf8) }).read()
        let device = try #require(joined.devices.first { $0.id == .simulator(udid: "ready", deviceSetPath: nil) })
        guard case .simulator(let simulator) = device else { Issue.record("Expected a simulator"); return }
        #expect(simulator.lastBootDate == (fails ? nil : boot))
        #expect(simulator.inventoryCopy(ownerXcodeURL: xcode).lastBootDate == simulator.lastBootDate)
        if case .simulator(let stopped) = joined.devices.first(where: { $0.id == .simulator(udid: "unavailable", deviceSetPath: nil) }) {
            #expect(stopped.lastBootDate == nil)
        }
        #expect(joined.devices.count == 3)
        #expect(joined.issues.count == (fails ? 1 : 0))
        #expect(!joined.retains([.simulators(xcodeURL: xcode, deviceSetPath: nil)]))
    }

    @Test func aLaterCatalogSuppliesTheBootDateWithoutReplacingTheChosenDevice() async throws {
        let first = URL(fileURLWithPath: "/Applications/First.app")
        let second = URL(fileURLWithPath: "/Applications/Second.app")
        let boot = Date(timeIntervalSinceReferenceDate: 400)
        let snapshot = try await SimulatorInventoryReader(installations: [first, second], testingDeviceSetPath: nil,
            readBootDates: { xcode, _ in
                if xcode == first { throw DeviceIOError.io("boot-identity", "unavailable") }
                return ["ready": boot]
            }, readCatalog: { xcode, path in
                try SimulatorDeviceCatalog.decode(Self.simulatorJSON, deviceSetPath: path, includeUnavailable: true, catalogXcodeURL: xcode)
            }).read()
        let item = try #require(snapshot.devices.first { $0.id == .simulator(udid: "ready", deviceSetPath: nil) })
        guard case .simulator(let device) = item else { Issue.record("Expected a simulator"); return }
        #expect(device.catalogXcodeURL == first && device.lastBootDate == boot)
    }

    private static func simulator(_ identifier: String, path: String? = nil) -> SimulatorHostDevice {
        SimulatorHostDevice(identifier: identifier, name: "Simulator Name", descriptiveName: "Simulator Name — iOS 27.0",
            runtimeIdentifier: "runtime", runtimeName: "iOS 27.0", productFamily: "iPhone", state: "Booted",
            ownerXcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            catalogXcodeURL: URL(fileURLWithPath: "/Applications/Catalog Xcode.app"), deviceSetPath: path, modelIdentifier: "iPhone99,2",
            deviceTypeIdentifier: "phone-type")
    }

    private static let coreDeviceJSON = Data(#"""
    {"result":{"devices":[
      {"identifier":"remote-command-id","hardwareProperties":{"udid":"wrong-deprecated-value"},
       "deviceProperties":{"name":"Wrong Deprecated Name"},"connectionProperties":{"lastConnectionDate":"invalid"},
       "properties":{"hardware":{"fidelity":"physical","udid":"hardware-udid","productType":"iPhone99,1","marketingName":"Test Hardware","cpuType":{"type":16777228,"subtype":18446744071562067970},"osPlatform":"iOS"},
         "state":{"name":"Test Phone","bootState":"booted"},
         "software":{"osVersionNumber":{"stringValue":"27.0"},"osBuildVersions":{"buildVersion":{"name":"27A100","revisionVersion":{"components":"27.0.100"}}}},
         "connection":{"state":"connected","pairingState":"paired","transportType":"wired","lastConnectionDate":100}},
       "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.installapp","name":"Install Application"}]},
      {"identifier":"vm-command-id","properties":{"hardware":{"fidelity":"virtual","udid":"vm-hardware-udid","productType":"iPhone99,11"},
         "state":{"name":"Test VM"},"connection":{"state":"unavailable"},
         "software":{"osBuildVersions":{"buildVersion":{"majorLetterComponent":"B","majorNumberComponent":24,"name":"24B114","revisionVersion":{"components":[24,2,114,0,0],"originalComponentsCount":5,"stringValue":"24.2.114.0.0"},"updateNumberComponent":114}}}},
       "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.unpairdevice"}]},
      {"identifier":"simulator-command-id","properties":{"hardware":{"fidelity":"simulated","udid":"simulator-udid",
         "cpuType":{"type":16777228,"subtype":0},"osPlatform":"iOS","productType":"iPhone99,2"},
         "state":{"name":"CoreDevice Simulator Name","bootState":"shutdown","preparednessState":0},
         "connection":{"state":"disconnected","pairingState":"paired","transportType":"sameMachine","lastConnectionDate":100},
         "software":{"osBuildVersions":{
           "buildVersion":{"majorLetterComponent":"B","majorNumberComponent":24,"name":"24B114","revisionVersion":{"components":[24,2,114,0,0],"originalComponentsCount":5,"stringValue":"24.2.114.0.0"},"updateNumberComponent":114},
           "supplementalBuildVersion":{"factoryIdentifier":9,"majorLetterComponent":"B","majorNumberComponent":24,"name":"24B91016s","revisionVersion":{"components":[24,2,101,6,19],"originalComponentsCount":5,"stringValue":"24.2.101.6.19"},"updateLetterComponent":"s","updateNumberComponent":91016}}}},
       "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.customizeuistyle"}]},
      {"identifier":"coredevice-only-simulator","properties":{"hardware":{"fidelity":"simulated","udid":"coredevice-only-simulator"},
         "software":{"osBuildVersions":{"buildVersion":{"name":"24B114","revisionVersion":{"components":[24,2,114,0],"originalComponentsCount":4,"stringValue":"24.2.114.0"}}}}}}
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
