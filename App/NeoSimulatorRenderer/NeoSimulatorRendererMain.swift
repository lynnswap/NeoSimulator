@_spi(AppBootstrap) import NeoSimulatorService

@main
enum NeoSimulatorRendererMain {
    @MainActor static func main() {
        NeoSimulatorServiceMain.main()
    }
}
