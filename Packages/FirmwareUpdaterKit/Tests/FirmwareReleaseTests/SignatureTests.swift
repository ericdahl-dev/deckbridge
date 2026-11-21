import Foundation
import Testing
import FirmwareRelease

func hex(_ text: String) -> Data {
    Data(stride(from: 0, to: text.count, by: 2).map { i in
        UInt8(text[text.index(text.startIndex, offsetBy: i)..<text.index(text.startIndex, offsetBy: i + 2)], radix: 16)!
    })
}

/// RFC 8032 section 7.1, TEST 1: the panel's libsodium (#690) checks the same vector, so both sides agree on Ed25519.
@Test func theRFC8032TestVectorVerifies() throws {
    let key = try TrustedKey(id: "rfc8032-test-1", publicKey: hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
    let signature = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
    #expect(key.signed(Data(), signature))
    #expect(!key.signed(Data([0]), signature))
}

/// The vector shared with the panel (#690): a randomized CryptoKit signature, which libsodium must accept too.
@Test func theSharedCryptoKitVectorVerifiesAndAnAlteredOneDoesNot() throws {
    let url = try #require(Bundle.module.url(forResource: "cryptokit-ed25519", withExtension: "json", subdirectory: "Fixtures"))
    let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    let key = try TrustedKey(id: "shared-vector", publicKey: hex(vector["public_key"]!))
    var signature = hex(vector["signature"]!)
    #expect(key.signed(hex(vector["message"]!), signature))
    signature[signature.startIndex] ^= 1
    #expect(!key.signed(hex(vector["message"]!), signature))
}
