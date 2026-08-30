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
                requiresApplicationForm: false
            )
        },
        validateAppleApplication: { applicationURL, identifier in
            try checkAppleCodeSignature(
                at: applicationURL,
                identifier: identifier,
                requiresApplicationForm: true
            )
        }
    )
}

private func checkAppleCodeSignature(
    at codeURL: URL,
    identifier: String,
    requiresApplicationForm: Bool
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
    let requirementText = "identifier \"\(identifier)\" and anchor apple" as CFString
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

    var rawFlags = kSecCSCheckAllArchitectures
        | kSecCSStrictValidate
        | kSecCSRestrictSymlinks
    if requiresApplicationForm {
        rawFlags |= kSecCSRestrictToAppLike
    }
    let validationStatus = SecStaticCodeCheckValidity(
        staticCode,
        SecCSFlags(rawValue: rawFlags),
        requirement
    )
    guard validationStatus == errSecSuccess else {
        let kind = requiresApplicationForm ? "application" : "code"
        throw CLIError.unavailable(
            "code-signature",
            "\(codeURL.path) is not intact Apple-signed \(kind) with identifier \(identifier): \(securityMessage(validationStatus))"
        )
    }
}

private func securityMessage(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) {
        return message as String
    }
    return "OSStatus \(status)"
}
