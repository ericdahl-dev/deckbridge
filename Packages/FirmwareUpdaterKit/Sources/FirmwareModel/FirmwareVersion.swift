/// A dotted firmware version such as "1.10.0", compared number by number.
public struct FirmwareVersion: Sendable, Hashable {
    public let parts: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }
}

extension FirmwareVersion: Comparable {
    /// Number by number; a missing part counts as 0, so "1.2" equals "1.2.0".
    public static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

extension FirmwareVersion: CustomStringConvertible {
    public var description: String { parts.map(String.init).joined(separator: ".") }
}
