import Foundation

/// The public keys the updater trusts to sign firmware releases (ADR 0012): the maintainer's primary key and the
/// offline backup key. Empty until the owner makes them (docs/FIRMWARE-RELEASE-SIGNING.md); until then every
/// fetched release is refused as signed by an unknown key, and the built-in firmware is used.
public enum ReleaseKeys {
    /// Each entry: (id, public key as 64 hex characters), as `firmware-release public-key` prints it.
    static let listed: [(id: String, hex: String)] = []

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
