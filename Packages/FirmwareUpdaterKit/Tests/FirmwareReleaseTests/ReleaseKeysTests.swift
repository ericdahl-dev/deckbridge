import Testing
@testable import FirmwareRelease

/// Guards the owner's paste into ReleaseKeys.swift: a mistyped key would otherwise be dropped without a word.
@Test func everyListedReleaseKeyIsAWellFormedPrimaryOrBackupKey() {
    #expect(ReleaseKeys.trusted.count == ReleaseKeys.listed.count)
    #expect(ReleaseKeys.listed.allSatisfy { ["primary", "backup"].contains($0.id) && $0.hex.count == 64 })
    #expect(Set(ReleaseKeys.listed.map(\.id)).count == ReleaseKeys.listed.count)
}
