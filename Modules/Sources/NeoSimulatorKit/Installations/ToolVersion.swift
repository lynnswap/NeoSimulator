import Foundation

package struct ToolVersion: Comparable, Equatable, CustomStringConvertible {
    package let components: [Int]
    package let description: String

    package init(_ value: String) throws {
        let numericPrefix = value.prefix { $0.isNumber || $0 == "." }
        let parsed = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !parsed.isEmpty,
              parsed.allSatisfy({ !$0.isEmpty && Int($0) != nil })
        else {
            throw CLIError.configuration(
                "version-format",
                "invalid tool version '\(value)'"
            )
        }
        components = parsed.compactMap { Int($0) }
        description = value
    }

    package var major: Int {
        components[0]
    }

    package static func == (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        !((lhs < rhs) || (rhs < lhs))
    }

    package static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}
