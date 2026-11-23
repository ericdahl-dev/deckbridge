import Testing
@testable import FirmwareRelease

/// Guards the owner's paste into ReleaseKeys.swift: a mistyped key would otherwise be dropped without a word.
@Test func everyListedReleaseKeyIsAWellFormedPrimaryOrBackupKey() {
    #expect(ReleaseKeys.trusted.count == ReleaseKeys.listed.count)
    #expect(ReleaseKeys.listed.allSatisfy { ["primary", "backup"].contains($0.id) && $0.hex.count == 64 })
    #expect(Set(ReleaseKeys.listed.map(\.id)).count == ReleaseKeys.listed.count)
}

/// The owner's keys (#689, made 2026-11-23): the public halves `firmware-release public-key` printed, copied here
/// from that output, so a changed or dropped key in ReleaseKeys.swift fails.
@Test func theAppTrustsTheOwnersPrimaryAndBackupKeys() {
    let hex = ReleaseKeys.trusted.map { key in (key.id, key.publicKey.map { String(format: "%02x", $0) }.joined()) }
    #expect(hex.map(\.0) == ["primary", "backup"])
    #expect(hex.map(\.1) == [
        "26739c2c075965fd9a99330f97c3b09a28d11f85c1fa4d81bd5495cb67c1a5f8",
        "2e972a79fd40b287a151166dcdc723d07e84afe9ffc933fb211c670873c07cbe",
    ])
}
