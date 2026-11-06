import Foundation
import NeoSimulatorKit

/// Reports one external display host after every context affected by its takeover has stopped.
@MainActor
final class HostTakeovers<Member: AnyObject> {
    private final class Takeover {
        let hostName: String
        var stopping: [Member]
        var failures: [String] = []

        init(hostName: String, first: Member) {
            self.hostName = hostName
            stopping = [first]
        }
    }

    private var takeovers: [Takeover] = []
    private var opening: Takeover?
    private let didBegin: () -> Void
    private let report: (any Error) -> Void

    init(didBegin: @escaping () -> Void = {}, report: @escaping (any Error) -> Void) {
        self.didBegin = didBegin
        self.report = report
    }

    func begin(_ member: Member, hostName: String, checkOthers: () -> Void) {
        if let opening {
            opening.stopping.append(member)
            return
        }
        let takeover = Takeover(hostName: hostName, first: member)
        takeovers.append(takeover)
        opening = takeover
        defer { opening = nil }
        checkOthers()
        didBegin()
    }

    func end(_ member: Member, failure: (any Error)?) {
        guard let takeover = takeovers.first(where: { $0.stopping.contains { $0 === member } }) else { return }
        takeover.stopping.removeAll { $0 === member }
        if let failure { takeover.failures.append(failure.localizedDescription) }
        guard takeover.stopping.isEmpty else { return }
        takeovers.removeAll { $0 === takeover }
        let lines = ["\(takeover.hostName) is now displaying the simulators."] + takeover.failures
        report(SimulatorError.conflict(lines.joined(separator: "\n")))
    }
}
