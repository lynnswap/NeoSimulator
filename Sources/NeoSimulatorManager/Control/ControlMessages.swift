import Foundation
import NeoSimulatorDeviceIO

/// What the command-line tool asks the running app. A request and its answer are each one JSON object on a line.
package enum ControlRequest: Codable, Equatable, Sendable {
    /// The labels of the logins that are saved for an app and allow automated use.
    case logins(application: String)
    /// Signs in on a device with the login of a label. Without an app, the label alone has to name one login.
    case signIn(device: String, application: String?, label: String)
}

package enum ControlResponse: Codable, Equatable, Sendable {
    case logins([String])
    case signIn(SignInOutcome)
    /// The app could not answer the request, with why.
    case failure(String)
}

/// How a sign-in that the tool asked for ended. Neither it nor its reason holds a user name or a password.
package struct SignInOutcome: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case signedIn
        /// A check stopped the sign-in before it filled anything in.
        case refused
        /// The sign-in ran and did not end signed in, such as with a login that the page rejected.
        case failed
        /// The device showed a screen that the sign-in does not recognize.
        case unrecognized
    }

    package var kind: Kind
    /// Why, for an outcome other than `signedIn`.
    package var reason: String?

    package init(_ kind: Kind, reason: String? = nil) {
        self.kind = kind
        self.reason = reason
    }
}

/// A check that stops a sign-in before it starts, with what it found.
package struct SignInRefusal: Error, LocalizedError, Equatable {
    package let reason: String

    package init(_ reason: String) { self.reason = reason }

    package var errorDescription: String? { reason }
}

extension LoginStore {
    /// Answers a request of the command-line tool. `signIn` signs in on the device that the request names with the
    /// login that this found for it, and throws a ``SignInRefusal`` when it will not start.
    ///
    /// The tool reaches only the logins that allow automated use, and learns of no other.
    package func answer(
        _ request: ControlRequest, signIn: (SavedLogin.ID, _ device: String) async throws -> Void
    ) async -> ControlResponse {
        // The keychain is read for each request, so that a login saved or changed a moment ago counts.
        await reload()
        if let issue { return .failure(issue) }
        let automated = logins.filter(\.allowsAutomation)
        switch request {
        case .logins(let application):
            return .logins(automated.filter { $0.applicationIdentifier == application }.map(\.label))
        case .signIn(let device, let application, let label):
            let named = automated.filter {
                $0.label == label && (application == nil || $0.applicationIdentifier == application)
            }
            guard let login = named.first else {
                return .signIn(SignInOutcome(.refused, reason: "No login with this label allows automated use."))
            }
            guard named.count == 1 else {
                return .signIn(
                    SignInOutcome(.refused, reason: "More than one app has a login with this label. Name the app."))
            }
            do {
                try await signIn(login.id, device)
                return .signIn(SignInOutcome(.signedIn))
            } catch let refusal as SignInRefusal {
                return .signIn(SignInOutcome(.refused, reason: refusal.reason))
            } catch let failure as WebAuthenticationSignIn.Failure {
                let kind: SignInOutcome.Kind =
                    switch failure {
                    case .otherApplication: .refused
                    case .noSheet, .unrecognizedPage: .unrecognized
                    case .rejected, .timedOut: .failed
                    }
                // The page chooses its own origin, so the tool is not told it.
                let reason =
                    if case .unrecognizedPage = failure {
                        "The web sign-in sheet shows a page that is not a sign-in page of the login."
                    } else {
                        failure.localizedDescription
                    }
                return .signIn(SignInOutcome(kind, reason: reason))
            } catch let failure as WebInspectorFailure {
                // What a page's script threw, and what a page answered, are the page's words, which can repeat what
                // was filled into it. The tool gets NeoSimulator's own words only.
                let reason =
                    switch failure {
                    case .scriptThrew, .unreadableAnswer: "The page did not run the sign-in’s script."
                    case .disconnected, .pageGone, .pageInUse: failure.localizedDescription
                    }
                return .signIn(SignInOutcome(.failed, reason: reason))
            } catch {
                return .signIn(SignInOutcome(.failed, reason: error.localizedDescription))
            }
        }
    }
}
