import Foundation
import Security

struct CodeSignatureValidator: Sendable {
    let validateAppleCode: @Sendable (URL, String) throws -> Void

    static let live = CodeSignatureValidator { codeURL, identifier in
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

        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSStrictValidate
                | kSecCSRestrictSymlinks
        )
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            flags,
            requirement
        )
        guard validationStatus == errSecSuccess else {
            throw CLIError.unavailable(
                "code-signature",
                "\(codeURL.path) is not intact Apple-signed code with identifier \(identifier): \(securityMessage(validationStatus))"
            )
        }
    }
}

private func securityMessage(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) {
        return message as String
    }
    return "OSStatus \(status)"
}
