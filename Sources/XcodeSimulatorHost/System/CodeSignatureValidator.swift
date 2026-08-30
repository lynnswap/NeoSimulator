import Foundation
import Security

struct CodeSignatureValidator: Sendable {
    let validateAppleCode: @Sendable (URL, String) throws -> Void
    let validateAppleApplication: @Sendable (URL, String) throws -> Void

    init(
        _ validateAppleCode: @escaping @Sendable (URL, String) throws -> Void,
        validateAppleApplication: (@Sendable (URL, String) throws -> Void)? = nil
    ) {
        self.validateAppleCode = validateAppleCode
        self.validateAppleApplication = validateAppleApplication ?? validateAppleCode
    }

    static let live = CodeSignatureValidator(
        { codeURL, identifier in
            try checkAppleCodeSignature(
                at: codeURL,
                identifier: identifier,
                policy: .code
            )
        },
        validateAppleApplication: { applicationURL, identifier in
            try checkAppleCodeSignature(
                at: applicationURL,
                identifier: identifier,
                policy: .application
            )
        }
    )
}

enum AppleCodeValidationPolicy: Sendable {
    case code
    case application

    func requirement(for identifier: String) -> String {
        switch self {
        case .code:
            return #"identifier "\#(identifier)" and anchor apple"#
        case .application:
            return #"identifier "\#(identifier)" and (anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists))"#
        }
    }

    var validationFlags: SecCSFlags {
        var rawFlags = kSecCSCheckAllArchitectures
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
        if self == .application {
            rawFlags |= kSecCSRestrictToAppLike
        }
        return SecCSFlags(rawValue: rawFlags)
    }

    var description: String {
        switch self {
        case .code:
            return "code"
        case .application:
            return "application"
        }
    }
}

private func checkAppleCodeSignature(
    at codeURL: URL,
    identifier: String,
    policy: AppleCodeValidationPolicy
) throws {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(
        codeURL as CFURL,
        SecCSFlags(),
        &staticCode
    )
    guard createStatus == errSecSuccess, let staticCode else {
        throw CLIError.unavailable(
            "code-signature",
            "could not inspect the signature of \(codeURL.path): \(securityMessage(createStatus))"
        )
    }

    var requirement: SecRequirement?
    let requirementText = policy.requirement(for: identifier) as CFString
    let requirementStatus = SecRequirementCreateWithString(
        requirementText,
        SecCSFlags(),
        &requirement
    )
    guard requirementStatus == errSecSuccess, let requirement else {
        throw CLIError.software(
            "code-requirement",
            "could not create the Apple code requirement: \(securityMessage(requirementStatus))"
        )
    }

    let validationStatus = SecStaticCodeCheckValidity(
        staticCode,
        policy.validationFlags,
        requirement
    )
    guard validationStatus == errSecSuccess else {
        throw CLIError.unavailable(
            "code-signature",
            "\(codeURL.path) is not intact Apple-signed \(policy.description) with identifier \(identifier): \(securityMessage(validationStatus))"
        )
    }
}

private func securityMessage(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) {
        return message as String
    }
    return "OSStatus \(status)"
}
