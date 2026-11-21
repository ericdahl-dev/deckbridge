import CommonCrypto
import CryptoKit
import Foundation

public enum KeyFileError: Error, Equatable {
    case wrongPassphraseOrDamaged
    case notAKeyFile
}

/// A release signing key on the maintainer's Mac (ADR 0012): PBKDF2-SHA256, 600,000 rounds, a 16-byte random salt,
/// deriving an AES-256-GCM key that seals the 32-byte Ed25519 seed. The id and public key are the sealing's
/// associated data, so neither can be changed without the file failing to open.
public enum KeyFile {
    static let format = "deckbridge-release-key-1"
    static let rounds: UInt32 = 600_000

    private struct File: Codable {
        let format: String
        let id: String
        let publicKey: Data
        let kdf: String
        let rounds: UInt32
        let salt: Data
        let sealed: Data

        enum CodingKeys: String, CodingKey {
            case format, id, kdf, rounds, salt, sealed
            case publicKey = "public_key"
        }

        var associatedData: Data { Data("\(format)\n\(id)\n".utf8) + publicKey }
    }

    public static func seal(_ key: SigningKey, passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else {
            throw KeyFileError.notAKeyFile
        }
        var file = File(format: format, id: key.id, publicKey: key.secret.publicKey.rawRepresentation, kdf: "pbkdf2-sha256",
                        rounds: rounds, salt: salt, sealed: Data())
        let box = try AES.GCM.seal(key.secret.rawRepresentation, using: try derive(passphrase, salt: salt, rounds: rounds),
                                   authenticating: file.associatedData)
        file = File(format: file.format, id: file.id, publicKey: file.publicKey, kdf: file.kdf, rounds: file.rounds,
                    salt: salt, sealed: box.combined!)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// The id and public key a key file names, without the passphrase: to build into the app.
    public static func publicKey(of data: Data) throws -> TrustedKey {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == format else { throw KeyFileError.notAKeyFile }
        return try TrustedKey(id: file.id, publicKey: file.publicKey)
    }

    public static func open(_ data: Data, passphrase: String) throws -> SigningKey {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == format, file.kdf == "pbkdf2-sha256",
              file.rounds >= rounds, file.salt.count == 16 else { throw KeyFileError.notAKeyFile }
        do {
            let seed = try AES.GCM.open(try AES.GCM.SealedBox(combined: file.sealed),
                                        using: try derive(passphrase, salt: file.salt, rounds: file.rounds),
                                        authenticating: file.associatedData)
            let secret = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            guard secret.publicKey.rawRepresentation == file.publicKey else { throw KeyFileError.wrongPassphraseOrDamaged }
            return SigningKey(id: file.id, secret: secret)
        } catch {
            throw KeyFileError.wrongPassphraseOrDamaged
        }
    }

    private static func derive(_ passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { CChar(bitPattern: $0) }, password.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        guard status == kCCSuccess else { throw KeyFileError.notAKeyFile }
        return SymmetricKey(data: out)
    }
}
