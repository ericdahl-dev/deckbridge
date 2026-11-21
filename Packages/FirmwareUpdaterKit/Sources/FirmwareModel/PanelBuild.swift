/// The build a deck panel says it runs, from its boot line "deck panel: boot, build <sha>".
/// `version` stays nil until the panel firmware reports one (#695).
public struct PanelBuild: Sendable, Hashable {
    public let sha: String
    public let version: FirmwareVersion?

    public init(sha: String, version: FirmwareVersion? = nil) {
        self.sha = sha
        self.version = version
    }
}
