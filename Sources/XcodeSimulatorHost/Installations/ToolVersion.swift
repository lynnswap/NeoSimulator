import Foundation

struct ToolVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]
    let description: String

    init(_ value: String) throws {
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

    var major: Int {
        components[0]
    }

    static func == (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        !((lhs < rhs) || (rhs < lhs))
    }

    static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
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
