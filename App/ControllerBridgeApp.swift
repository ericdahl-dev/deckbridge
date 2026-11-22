import ControllerBridgeCore
import SwiftUI

@main
enum Entry {
    static func main() {
        // First: the log's print to stdout must not kill the app when stdout is a pipe nobody reads (#653).
        ProcessSignals.ignoreBrokenPipe()
        Theme.registerFonts()
        #if DEBUG
        // Debug builds only: renders the panel to PNGs for PR screenshots and exits (#34). Not in Release.
        if let index = CommandLine.arguments.firstIndex(of: "--render-snapshots"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshots.render(to: CommandLine.arguments[index + 1]) }
            exit(0)
        }
        #endif
        ControllerBridgeApp.main()
    }
}

struct ControllerBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = BridgeModel()

    var body: some Scene {
        // Window style, not .menu, so it carries the dark panel.
        MenuBarExtra {
            StatusPanel(
                status: model.status, setDemo: model.setDemo, setDeck: { model.setDeck($0, controller: $1) },
                helpAdd: { model.captureRequest.device = $0 }
            )
                .environment(\.deckColors, model.status.deckColors)
        } label: {
            MenuBarLabel(status: model.status)
        }
        .menuBarExtraStyle(.window)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsWindow(
                log: model.diagnostics, status: model.status, sweeping: model.status.sweeping, setOpen: model.setDiagnostics(open:),
                startSweep: model.startLEDSweep(delay:), stopSweep: model.stopLEDSweep,
                hiddenNotes: model.profiles.first?.mapping.midi.ignoreNotes ?? [], jogSimulator: model.jogSimulator,
                setJogPreviewDeck: model.setJogPreviewDeck, captureMeter: { model.captureMeter(seconds: 10) }
            )
            .environment(\.deckColors, model.status.deckColors)
        }
        .defaultSize(width: 720, height: 480)
        // Opens only from the panel's Diagnostics…, never by itself at launch.
        .defaultLaunchBehavior(.suppressed)

        // The first-run guide (#27): opens itself on first launch, and from the panel's "Setup guide…".
        // "Setup Guide": the caption inside says SET UP SYNDICATE, so the title doesn't repeat it (#68).
        Window("Setup Guide", id: SetupGuideWindow.id) {
            SetupGuideView(guide: model.status.setupGuide, presentation: model.status.presentation)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // The guided capture (#186): from Settings › Controller.
        Window(CaptureWindow.title, id: CaptureWindow.id) {
            CaptureWindowRoot(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(model: model)
                .environment(\.deckColors, model.status.deckColors)
        }
    }
}

/// The menu-bar icon. It exists from launch, so it also opens the setup guide the first time (#27).
struct MenuBarLabel: View {
    let status: BridgeStatus
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = status.presentation
        Image(nsImage: MenuBarIcon.image(presentation.icon))
            .accessibilityLabel(presentation.iconAccessibilityLabel)
            .task { SetupGuideWindow.openIfNew(openWindow) }
    }
}
