struct SimulatorMenuDevice<ID: Hashable> {
    let identifier: ID
    let name: String
    let descriptiveName: String
    let runtimeIdentifier: String
    let runtimeName: String
    let state: UInt
}
