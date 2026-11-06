import AppKit
import NeoSimulatorKit

/// What a quit tells the user about what it leaves unfinished.
@MainActor
package enum QuitReport {
    /// Logs the notes and shows them, for a limited time because nobody may be there to answer, and a quit must end.
    package static func present(_ notes: [String], for limit: Duration = .seconds(30)) {
        guard !notes.isEmpty else { return }
        for note in notes { hostLog(note) }
        let alert = NSAlert()
        alert.messageText = "Some operations did not finish before NeoSimulator quit."
        alert.informativeText = notes.joined(separator: "\n\n")
        // Not a task: a job that presents this runs inside a drain of the main queue, and until it returns the modal's run
        // loop does not serve that queue, so nothing on the main actor would run to end it.
        let timer = Timer(timeInterval: limit / .seconds(1), repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        alert.runModal()
        timer.invalidate()
    }
}
