import AppKit

/// The launch smoke check (#734, scripts/updater_smoke.sh): started with --smoke, the app quits right after its
/// first look has been logged. Without it, nothing here runs.
enum SmokeLaunch {
    static var isOn: Bool { CommandLine.arguments.contains("--smoke") }

    @MainActor static func finish() { NSApplication.shared.terminate(nil) }
}
