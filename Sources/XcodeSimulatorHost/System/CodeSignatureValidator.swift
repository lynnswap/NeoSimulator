import Foundation
import Security

struct CodeSignatureValidator: Sendable {
    let validateAppleApplication: @Sendable (URL, String) throws -> Void

    static let live = CodeSignatureValidator { applicationURL, bundleIdentifier in
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw CLIError.unavailable(
                "code-signature",
                "could not inspect the signature of \(applicationURL.path): \(securityMessage(createStatus))"
            )
        }

        var requirement: SecRequirement?
        let requirementText = "identifier \"\(bundleIdentifier)\" and anchor apple" as CFString
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
                | kSecCSRestrictToAppLike
        )
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            flags,
            requirement
        )
        guard validationStatus == errSecSuccess else {
            throw CLIError.unavailable(
                "code-signature",
                "\(applicationURL.path) is not an intact Apple-signed \(bundleIdentifier) application: \(securityMessage(validationStatus))"
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
