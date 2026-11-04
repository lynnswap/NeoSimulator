import NeoSimulatorKit
@_spi(NeoSimulator) import XcodeSimulatorHost
package struct SimulatorMenuDevice<ID: Hashable> {
    package let identifier: ID
    package let name: String
    package let descriptiveName: String
    package let runtimeIdentifier: String
    package let runtimeName: String
    package let state: UInt

    package init(identifier: ID, name: String, descriptiveName: String, runtimeIdentifier: String, runtimeName: String, state: UInt) {
        self.identifier = identifier
        self.name = name
        self.descriptiveName = descriptiveName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.state = state
    }
}
