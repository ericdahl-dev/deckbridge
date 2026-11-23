import Foundation

/// The public keys the updater trusts to sign firmware releases (ADR 0012): the maintainer's primary key and the
/// offline backup key, made by the owner on 2026-11-23 (docs/FIRMWARE-RELEASE-SIGNING.md). Public halves only.
public enum ReleaseKeys {
    /// Each entry: (id, public key as 64 hex characters), as `firmware-release public-key` prints it.
    static let listed: [(id: String, hex: String)] = [
        ("primary", "26739c2c075965fd9a99330f97c3b09a28d11f85c1fa4d81bd5495cb67c1a5f8"),
        ("backup", "2e972a79fd40b287a151166dcdc723d07e84afe9ffc933fb211c670873c07cbe"),
    ]

    public static var trusted: [TrustedKey] {
        listed.compactMap { entry in
            let bytes = stride(from: 0, to: entry.hex.count, by: 2).compactMap { i -> UInt8? in
                let start = entry.hex.index(entry.hex.startIndex, offsetBy: i)
                return UInt8(entry.hex[start..<entry.hex.index(start, offsetBy: 2)], radix: 16)
            }
            return try? TrustedKey(id: entry.id, publicKey: Data(bytes))
        }
    }
}
