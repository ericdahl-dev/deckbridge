/// The LC6000 section's status lines (#762): one per step, and a step starting clears the ones it makes stale.
public struct LC6000Lines: Sendable, Equatable {
    /// The update-mode step's result.
    public var step: String?
    /// The backup's result.
    public var backup: String?

    public init() {}

    public mutating func stepStarts() { step = nil }

    public mutating func backupStarts() {
        step = nil
        backup = nil
    }

    public mutating func writeStarts() { backup = nil }
}
