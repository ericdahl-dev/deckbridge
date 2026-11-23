#if DEBUG
import Foundation
import UpdaterScreen

/// Screenshots of the window (#761), in Debug builds only: `FirmwareUpdater --preview <shot>` opens it in a fixed state
/// on fake ports (Updater.preview). No IOKit, CoreMIDI or serial object is made, no DeckBridge signal is sent, and its
/// buttons reach only the fakes. Shots: nothing, found, backup, updating; #762's stepConfirm, writeConfirm, writing.
enum PreviewLaunch {
    enum Shot: String {
        case nothing, found, backup, updating
        /// #762: the update-mode step's confirm; the write's confirm with its typed-word field; the write running; the
        /// sectors under Details.
        case stepConfirm, writeConfirm, writing, details

        var state: PreviewState {
            switch self {
            case .nothing: .nothing
            case .found, .backup, .stepConfirm, .writeConfirm, .writing, .details: .found
            case .updating: .updating
            }
        }

        /// The backup line shown in the LC6000 section, after a backup.
        var backupResult: String? {
            [.backup, .writeConfirm, .writing, .details].contains(self) ? "Backup saved: read twice and the same, 2 files.\nTop panel chip: firmware 1.0.0." : nil
        }
    }

    static var shot: Shot? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count else { return nil }
        return Shot(rawValue: arguments[flag + 1])
    }

    /// The first look on the fakes, then for `updating`, the update over the (fake) cable.
    @MainActor static func run(_ shot: Shot, on model: Updater) async {
        await model.refresh()
        if shot == .updating { await model.updatePanel() }
    }
}
#endif
