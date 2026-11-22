import Testing
import UnitCheck

/// One status line per step in the LC6000 section (#762): starting a step clears the lines it makes stale, so the
/// owner never reads an old result under a new step.
@Suite("Unit check: the LC6000 section's status lines")
struct LC6000LinesTests {
    static func both() -> LC6000Lines {
        var lines = LC6000Lines()
        lines.step = "Sent."
        lines.backup = "Backup saved."
        return lines
    }

    @Test("A backup starting clears the update-mode step's line and the last backup's")
    func backupStarts() {
        var lines = Self.both()
        lines.backupStarts()
        #expect(lines.step == nil && lines.backup == nil)
    }

    @Test("A write starting clears the backup's line, and leaves the step's alone")
    func writeStarts() {
        var lines = Self.both()
        lines.writeStarts()
        #expect(lines.backup == nil)
        #expect(lines.step == "Sent.")
    }

    @Test("The update-mode step starting clears its own last line only")
    func stepStarts() {
        var lines = Self.both()
        lines.stepStarts()
        #expect(lines.step == nil)
        #expect(lines.backup == "Backup saved.")
    }
}
