import Darwin
import Foundation
import NeoSimulatorHostSupport

@main
enum CoreDeviceInventoryProbe {
    static func main() async {
        do {
            let data = try await SimulatorHostController.readCoreDeviceInventory()
            let devices = try CoreDeviceInventoryDecoder.decode(data)
            print("Decoded \(devices.count) CoreDevice records.")
        } catch {
            FileHandle.standardError.write(Data("CoreDevice inventory probe failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
