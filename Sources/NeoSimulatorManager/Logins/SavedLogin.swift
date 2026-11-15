import Foundation

/// A web origin where a login may be typed.
package struct WebOrigin: Codable, Hashable, Sendable {
    package struct Invalid: Error, LocalizedError {
        package let text: String

        package var errorDescription: String? {
            "“\(text)” isn’t a web origin. Enter a scheme and a host, such as https://example.com."
        }
    }

    package let scheme: String
    package let host: String
    package let port: Int

    private static let defaultPorts = ["https": 443, "http": 80]

    /// Reads an origin such as `https://example.com` or `http://localhost:3000`. A host without a scheme is HTTPS.
    package init?(_ text: String) {
        let text = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            let defaultPort = Self.defaultPorts[scheme], let host = components.host?.lowercased(), !host.isEmpty,
            components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else { return nil }
        self.scheme = scheme
        // URLComponents keeps the brackets of an IPv6 address on some hosts and drops them on others.
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        port = components.port ?? defaultPort
    }

    /// Reads the origins that a person entered, separated by commas, spaces, or line breaks.
    package static func list(from text: String) throws -> [WebOrigin] {
        var origins: [WebOrigin] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        for entry in text.components(separatedBy: separators) where !entry.isEmpty {
            guard let origin = WebOrigin(entry) else { throw Invalid(text: entry) }
            if !origins.contains(origin) { origins.append(origin) }
        }
        return origins
    }

    /// The origin as a person enters it, without the scheme's own port.
    package var text: String {
        let host = host.contains(":") ? "[\(host)]" : host
        return port == Self.defaultPorts[scheme] ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}

/// A login that a person saved for an app, without its password.
package struct SavedLogin: Equatable, Sendable, Identifiable {
    /// An app's bundle identifier and a label, which together name one login.
    package struct ID: Hashable, Sendable {
        package var applicationIdentifier: String
        package var label: String

        package init(applicationIdentifier: String, label: String) {
            self.applicationIdentifier = applicationIdentifier
            self.label = label
        }
    }

    package var applicationIdentifier: String
    package var label: String
    package var userName: String
    /// The origins where a web sign-in may type the login.
    package var origins: [WebOrigin]
    /// Whether a caller other than the person at the Mac may ask to sign in with the login.
    package var allowsAutomation: Bool

    package var id: ID { ID(applicationIdentifier: applicationIdentifier, label: label) }

    package init(
        applicationIdentifier: String, label: String, userName: String, origins: [WebOrigin] = [],
        allowsAutomation: Bool = true
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.label = label
        self.userName = userName
        self.origins = origins
        self.allowsAutomation = allowsAutomation
    }
}
