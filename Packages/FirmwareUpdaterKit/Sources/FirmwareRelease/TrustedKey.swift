import CryptoKit
import Foundation

/// A public key the app trusts to sign releases (ADR 0012): the maintainer's primary key or the offline backup key.
public struct TrustedKey: Sendable {
    public let id: String
    private let key: Curve25519.Signing.PublicKey
    public var publicKey: Data { key.rawRepresentation }

    public init(id: String, publicKey: Data) throws {
        self.id = id
        key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    }

    /// Whether `signature` is this key's Ed25519 signature over exactly `bytes`.
    public func signed(_ bytes: Data, _ signature: Data) -> Bool {
        key.isValidSignature(signature, for: bytes)
    }
}
