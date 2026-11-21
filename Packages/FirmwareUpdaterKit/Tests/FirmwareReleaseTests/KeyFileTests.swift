import Foundation
import Testing
@testable import FirmwareRelease

/// The maintainer's key on disk (ADR 0012, #701): sealed with a passphrase, opened only with it.
@Test func aSealedKeyOpensWithItsPassphraseAndSignsAsBefore() throws {
    let key = SigningKey.generate(id: "primary")
    let file = try KeyFile.seal(key, passphrase: "correct horse battery staple")
    let opened = try KeyFile.open(file, passphrase: "correct horse battery staple")
    #expect(opened.id == "primary")
    let manifest = Data("manifest".utf8)
    #expect(key.trusted.signed(manifest, try opened.sign(manifest)))
}

@Test func aSealedKeyDoesNotOpenWithAnotherPassphrase() throws {
    let file = try KeyFile.seal(SigningKey.generate(id: "primary"), passphrase: "correct horse battery staple")
    #expect(throws: KeyFileError.wrongPassphraseOrDamaged) { try KeyFile.open(file, passphrase: "correct horse battery stapler") }
}

/// The id and public key are bound to the sealed seed, so a file relabeled as the backup key doesn't open.
@Test func aKeyFileWhoseNameWasChangedDoesNotOpen() throws {
    let file = try KeyFile.seal(SigningKey.generate(id: "primary"), passphrase: "pass phrase")
    let relabeled = Data(String(decoding: file, as: UTF8.self).replacingOccurrences(of: #""primary""#, with: #""backup""#).utf8)
    #expect(throws: KeyFileError.wrongPassphraseOrDamaged) { try KeyFile.open(relabeled, passphrase: "pass phrase") }
}

@Test func theKeyFileNeverHoldsTheSeedInTheClear() throws {
    let key = SigningKey.generate(id: "primary")
    let file = try KeyFile.seal(key, passphrase: "pass phrase")
    #expect(file.range(of: key.secret.rawRepresentation) == nil)
    #expect(file.range(of: Data(key.secret.rawRepresentation.base64EncodedString().utf8)) == nil)
}

/// What the maintainer builds into the app: the key's id and public half, read without the passphrase.
@Test func aKeyFilesPublicKeyIsReadWithoutThePassphrase() throws {
    let key = SigningKey.generate(id: "backup")
    let trusted = try KeyFile.publicKey(of: try KeyFile.seal(key, passphrase: "pass phrase"))
    #expect(trusted.id == "backup")
    #expect(trusted.publicKey == key.trusted.publicKey)
}
