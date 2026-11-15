import ArgumentParser
import Foundation
import NeoSimulatorManager

/// The app's executable as a command-line tool. Started with one of these commands, it asks the NeoSimulator that is
/// already running and exits, without becoming an app itself.
///
/// The tool names a login by its label and learns how the sign-in ended. Nothing it takes or prints is a user name, a
/// password, a URL or a field.
struct NeoSimulatorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "NeoSimulator",
        abstract: "Ask the running NeoSimulator to sign in on a simulator with a saved login.",
        discussion: """
            Save logins in NeoSimulator's Settings, under Logins. A login is used only for the app it was saved for \
            and, for a web sign-in, only on the origins saved with it. Only logins that allow automated use are \
            available here.

            Exit status: 0 signed in, 1 failed, 2 refused, 3 the simulator showed a screen that NeoSimulator does \
            not recognize, 69 NeoSimulator is not running.
            """,
        subcommands: [Logins.self, SignIn.self])

    /// The arguments that make a launch of the app a use of the tool.
    static let launchArguments: Set<String> = ["logins", "sign-in", "help", "--help", "-h"]

    /// What the tool exits with, besides 0 for a sign-in that ended signed in and the parser's 64 for a wrong usage.
    enum Status: Int32 {
        case failed = 1
        case refused = 2
        case unrecognized = 3
        /// `EX_UNAVAILABLE`.
        case notRunning = 69

        init(_ kind: SignInOutcome.Kind) {
            self =
                switch kind {
                case .signedIn, .failed: .failed
                case .refused: .refused
                case .unrecognized: .unrecognized
                }
        }
    }

    /// Sends `request` to the running app, and exits with `Status.notRunning` when none answers.
    static func ask(_ request: ControlRequest, at socket: String?) throws -> ControlResponse {
        do {
            let response = try ControlSocket.send(request, to: socket ?? ControlSocket.defaultPath)
            if case .failure(let reason) = response { throw Failure(reason, status: .failed) }
            return response
        } catch let failure as ControlSocket.Failure {
            throw Failure(failure.localizedDescription, status: failure == .notRunning ? .notRunning : .failed)
        }
    }

    /// Ends the tool with a reason on standard error and a status.
    struct Failure: Error {
        let reason: String
        let status: Status

        init(_ reason: String, status: Status) {
            self.reason = reason
            self.status = status
        }

        func exit() -> ExitCode {
            FileHandle.standardError.write(Data((reason + "\n").utf8))
            return ExitCode(status.rawValue)
        }
    }

    struct Connection: ParsableArguments {
        @Option(help: .hidden) var socket: String?
    }

    struct Logins: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the labels of the logins that are saved for an app and allow automated use.")

        @Argument(help: "The app's bundle identifier.") var app: String
        @OptionGroup var connection: Connection

        func run() throws {
            do {
                let answer = try NeoSimulatorCommand.ask(.logins(application: app), at: connection.socket)
                guard case .logins(let labels) = answer else {
                    throw Failure("NeoSimulator answered with something else.", status: .failed)
                }
                for label in labels { print(label) }
            } catch let failure as Failure {
                throw failure.exit()
            }
        }
    }

    struct SignIn: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sign-in",
            abstract: "Sign in to the web sign-in sheet that the frontmost app of a simulator shows.",
            discussion: "The simulator's screen has to be open in NeoSimulator. The command waits for the outcome.")

        @Argument(help: "The login's label.") var label: String
        @Option(help: "The simulator's UDID.") var device: String
        @Option(help: "The bundle identifier of the login's app, where two apps have a login with the label.")
        var app: String?
        @OptionGroup var connection: Connection

        func run() throws {
            do {
                let request = ControlRequest.signIn(device: device, application: app, label: label)
                guard case .signIn(let outcome) = try NeoSimulatorCommand.ask(request, at: connection.socket)
                else { throw Failure("NeoSimulator answered with something else.", status: .failed) }
                guard outcome.kind != .signedIn else { return print("Signed in.") }
                throw Failure(outcome.reason ?? "The sign-in did not finish.", status: Status(outcome.kind))
            } catch let failure as Failure {
                throw failure.exit()
            }
        }
    }
}
