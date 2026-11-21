import FirmwareCatalog

/// What the updater's screen says about the deck panel firmware it offers (#704): from the newest release, or built
/// into the app, and when a release wasn't used, why, in plain words.
public struct FirmwareOffer: Sendable, Equatable {
    /// Where the offered firmware comes from, and its version.
    public let source: String
    /// Why the newest release wasn't used; nil when it was.
    public let reason: String?

    public init(_ outcome: FetchOutcome) {
        let version = outcome.catalog.newestPanel().map { "deck panel \($0.version)" }
        guard let refusal = outcome.refusal else {
            source = "Firmware from the newest release: " + (version ?? "no deck panel image")
            reason = nil
            return
        }
        source = version.map { "Firmware built into this app: \($0)" } ?? "No deck panel firmware built into this app"
        reason = Self.reason(refusal)
    }

    static func reason(_ refusal: Refusal) -> String {
        let builtIn = ", so the firmware built into this app is offered."
        switch refusal {
        case .unreachable: return "GitHub couldn't be reached" + builtIn
        case .unknownKey: return "The newest release is signed with a key this app doesn't trust yet" + builtIn
        case .badSignature: return "The newest release's signature doesn't check out" + builtIn
        case .unreadableManifest: return "The newest release's manifest can't be read" + builtIn
        case .fileMismatch(let name): return "A file in the newest release (\(name)) isn't what its manifest says" + builtIn
        case .unsafeFileName: return "The newest release names a file outside its folder" + builtIn
        case .notNewer: return "The newest release is no newer than this app's firmware."
        case .notACatalog, .unreadableCatalog: return "The newest release's catalog isn't one this app accepts" + builtIn
        case .couldNotStore: return "The newest release couldn't be saved on this Mac" + builtIn
        case .dropsBuiltIn: return "The newest release leaves out firmware this app carries" + builtIn
        case .unknownFormat: return "The newest release needs a newer version of this app" + builtIn
        }
    }
}
