import ControllerBridgePresentation
import Testing

/// The Diagnostics window's words and lists (#70), apart from the SwiftUI.
@Suite("Diagnostics presentation")
struct DiagnosticsPresentationTests {
    @Test("Each empty list says what to do; the monitor's line depends on whether a controller is connected")
    func emptyStates() {
        #expect(DiagnosticsTab.monitor.emptyText(controllerConnected: true) == "Press any button on the controller.")
        #expect(DiagnosticsTab.monitor.emptyText(controllerConnected: false) == "No controller connected.")
        #expect(DiagnosticsTab.sweep.emptyText(controllerConnected: true) == "Press Start Sweep. Watch the pads and ring.")
        #expect(DiagnosticsTab.osc.emptyText(controllerConnected: false) == "Nothing sent or received yet.")
    }

    @Test("Start Sweep needs the controller's LED output: without one it's disabled, with the reason")
    func sweepAvailability() {
        #expect(SweepAvailability(outputOpen: true) == SweepAvailability(enabled: true, reason: nil))
        #expect(SweepAvailability(outputOpen: false) == SweepAvailability(enabled: false, reason: "No controller output. Plug in the controller."))
    }

    @Test("Clear empties only the tab you're on")
    func clearOneTab() {
        var lines = DiagnosticsLines()
        lines.append(to: .monitor, message: "       1.500  ch1  note_on channel=0 note=1 velocity=127 time=0", label: "play")
        lines.append(to: .osc, message: "OSC -> /Syndicate/Deck/1/PlayPause 1")
        lines.append(to: .sweep, message: "pads+ring velocity 0x00 (0)")
        lines.clear(.osc)
        #expect(lines.shown(.osc).isEmpty)
        #expect(lines.shown(.monitor).map(\.label) == ["play"])
        #expect(lines.shown(.sweep).count == 1)
    }

    @Test("Each list keeps its newest 20,000 lines (#218): about a minute of busy feedback, not one second")
    func limit() {
        var lines = DiagnosticsLines()
        for n in 1...20_001 { lines.append(to: .osc, message: "OSC -> /Syndicate/Browser/Down \(n)") }
        let shown = lines.shown(.osc)
        #expect(shown.count == 20_000)
        #expect(shown.first?.message == "OSC -> /Syndicate/Browser/Down 2")
        #expect(shown.last?.message == "OSC -> /Syndicate/Browser/Down 20001")
    }

    @Test("Hide streaming values (#218) hides Syndicate's fast feedback: Position, BarRamp, Meter, Header/Clock, CurrentStep, SampleProgress, Progress and Time")
    func hideStreaming() {
        var lines = DiagnosticsLines()
        for message in [
            "OSC <- /Syndicate/Deck/3/Position 48.91",
            "OSC <- /Syndicate/Deck/3/BarRamp 0.42",
            "OSC <- /Syndicate/Mixer/CH3/Meter 0.61",
            "OSC <- /Syndicate/Header/Clock 2",
            "OSC <- /Syndicate/Deck/1/CurrentStep 5",
            "OSC <- /Syndicate/Deck/1/SampleProgress 0.5",
            "OSC <- /Syndicate/Deck/1/Progress 0.25",
            "OSC <- /Syndicate/Deck/1/Time 61",
            "OSC <- /Syndicate/Header/BPM 128.0",
            "OSC <- /Syndicate/Deck/3/TrackInfo \"Song\" \"Artist\"",
            "OSC -> /Syndicate/Deck/3/Position 0.5",
        ] { lines.append(to: .osc, message: message) }
        #expect(lines.hideStreaming)
        #expect(lines.shown(.osc).map(\.message) == [
            "OSC <- /Syndicate/Header/BPM 128.0",
            "OSC <- /Syndicate/Deck/3/TrackInfo \"Song\" \"Artist\"",
            "OSC -> /Syndicate/Deck/3/Position 0.5",
        ])
        lines.hideStreaming = false
        #expect(lines.shown(.osc).count == 11)
    }

    @Test("The search field shows only lines containing its text, any case; empty shows all; nothing is dropped (#218)")
    func textFilter() {
        var lines = DiagnosticsLines()
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/2/TrackInfo \"Song\"")
        lines.append(to: .osc, message: "OSC <- /Syndicate/Mixer/CH1/Volume 1.0")
        lines.append(to: .osc, message: "OSC -> /Syndicate/Deck/1/PlayPause 1")
        lines.append(to: .monitor, message: "       1.500  ch1  note_on channel=0 note=1 velocity=127 time=0 ", label: "play")
        lines.filter.text = "trackinfo"
        #expect(lines.shown(.osc).map(\.message) == ["OSC <- /Syndicate/Deck/2/TrackInfo \"Song\""])
        lines.filter.text = "MIXER"
        #expect(lines.shown(.osc).map(\.message) == ["OSC <- /Syndicate/Mixer/CH1/Volume 1.0"])
        lines.filter.text = "play"
        #expect(lines.shown(.monitor).map(\.label) == ["play"], "the monitor's mapping label counts too")
        lines.filter.text = ""
        #expect(lines.shown(.osc).count == 3)
    }

    @Test("Direction shows OSC received from Syndicate, sent to it, or both (#218)")
    func directionFilter() {
        var lines = DiagnosticsLines()
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 1")
        lines.append(to: .osc, message: "OSC -> /Syndicate/Deck/1/PlayPause 1")
        #expect(lines.filter.direction == .both)
        lines.filter.direction = .received
        #expect(lines.shown(.osc).map(\.message) == ["OSC <- /Syndicate/Deck/1/Playing 1"])
        lines.filter.direction = .sent
        #expect(lines.shown(.osc).map(\.message) == ["OSC -> /Syndicate/Deck/1/PlayPause 1"])
        #expect(DiagnosticsDirection.allCases.map(\.rawValue) == ["In and out", "In", "Out"])
    }

    @Test("Deck shows only the OSC lines for that deck: its Deck/N address, its mixer channel and its filter (#218)")
    func deckFilter() {
        var lines = DiagnosticsLines()
        for message in [
            "OSC <- /Syndicate/Deck/2/Playing 1",
            "OSC <- /Syndicate/Deck/12/Playing 1",
            "OSC <- /Syndicate/Mixer/CH2/Volume 1.0",
            "OSC <- /Syndicate/Mixer/filter2.cut 0.5",
            "OSC -> /Syndicate/Deck/2/PlayPause 1",
            "OSC <- /Syndicate/Deck/3/Playing 1",
            "OSC <- /Syndicate/Header/BPM 128.0",
        ] { lines.append(to: .osc, message: message) }
        #expect(lines.filter.deck == nil)
        lines.filter.deck = 2
        #expect(lines.shown(.osc).map(\.message) == [
            "OSC <- /Syndicate/Deck/2/Playing 1",
            "OSC <- /Syndicate/Mixer/CH2/Volume 1.0",
            "OSC <- /Syndicate/Mixer/filter2.cut 0.5",
            "OSC -> /Syndicate/Deck/2/PlayPause 1",
        ])
    }

    @Test("Shown, streaming values collapse: each stretch of them shows each address once, at its latest value, with how many arrived (#218)")
    func collapseStreaming() {
        var lines = DiagnosticsLines()
        lines.hideStreaming = false
        for message in [
            "OSC <- /Syndicate/Deck/1/Playing 1",
            "OSC <- /Syndicate/Deck/3/Position 48.89",
            "OSC <- /Syndicate/Deck/3/BarRamp 0.40",
            "OSC <- /Syndicate/Deck/3/Position 48.90",
            "OSC <- /Syndicate/Deck/3/BarRamp 0.41",
            "OSC <- /Syndicate/Deck/3/Position 48.91",
            "OSC <- /Syndicate/Deck/3/Cues 1",
            "OSC <- /Syndicate/Deck/3/Position 49.00",
        ] { lines.append(to: .osc, message: message) }
        #expect(lines.collapseStreaming)
        #expect(lines.shown(.osc).map(\.message) == [
            "OSC <- /Syndicate/Deck/1/Playing 1",
            "OSC <- /Syndicate/Deck/3/BarRamp 0.41 ×2",
            "OSC <- /Syndicate/Deck/3/Position 48.91 ×3",
            "OSC <- /Syndicate/Deck/3/Cues 1",
            "OSC <- /Syndicate/Deck/3/Position 49.00",
        ])
        lines.collapseStreaming = false
        #expect(lines.shown(.osc).count == 8)
    }

    @Test("Pause freezes what a list shows while lines keep arriving; Resume shows them all (#218)")
    func pause() {
        var lines = DiagnosticsLines()
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 1")
        lines.append(to: .monitor, message: "       1.500  ch1  note_on channel=0 note=1 velocity=127 time=0 ", label: "play")
        #expect(!lines.isPaused)
        lines.pause()
        #expect(lines.isPaused)
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 0")
        lines.append(to: .monitor, message: "       1.600  ch1  note_off channel=0 note=1 velocity=0 time=0 ", label: "play")
        #expect(lines.shown(.osc).map(\.message) == ["OSC <- /Syndicate/Deck/1/Playing 1"])
        #expect(lines.shown(.monitor).count == 1)
        lines.filter.text = "Playing 1"
        #expect(lines.shown(.osc).count == 1, "the filter still works on the frozen lines")
        lines.filter.text = ""
        lines.resume()
        #expect(lines.shown(.osc).map(\.message) == ["OSC <- /Syndicate/Deck/1/Playing 1", "OSC <- /Syndicate/Deck/1/Playing 0"])
        #expect(lines.shown(.monitor).count == 2)
    }

    @Test("Pause holds: more than `limit` lines arriving while paused don't empty or shift the frozen view (#319)")
    func pauseHolds() {
        var lines = DiagnosticsLines(limit: 3)
        lines.hideStreaming = false
        lines.collapseStreaming = false
        for n in 1...3 { lines.append(to: .monitor, message: "note \(n)") }
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 1")
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Position 1.0")
        let monitorBefore = lines.shown(.monitor), oscBefore = lines.shown(.osc)
        lines.pause()
        for n in 4...10 { lines.append(to: .monitor, message: "note \(n)") }
        for n in 2...9 { lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Position \(n).0") }
        #expect(lines.shown(.monitor) == monitorBefore)
        #expect(lines.shown(.osc) == oscBefore)
        #expect(monitorBefore.map(\.message) == ["note 1", "note 2", "note 3"])
        lines.resume()
        #expect(lines.shown(.monitor).map(\.message) == ["note 8", "note 9", "note 10"])
    }

    @Test("Copy takes the visible lines; Save takes the whole history: streaming, filtered-out and post-pause lines too, uncollapsed (#218)")
    func copyVisibleSaveAll() {
        var lines = DiagnosticsLines()
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 1")
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Position 1.0")
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Position 1.1")
        lines.append(to: .osc, message: "OSC -> /Syndicate/Deck/2/PlayPause 1")
        lines.filter.deck = 1
        lines.pause()
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 0")
        #expect(lines.plainText(.osc) == "OSC <- /Syndicate/Deck/1/Playing 1\n")
        #expect(lines.historyText(.osc) == """
            OSC <- /Syndicate/Deck/1/Playing 1
            OSC <- /Syndicate/Deck/1/Position 1.0
            OSC <- /Syndicate/Deck/1/Position 1.1
            OSC -> /Syndicate/Deck/2/PlayPause 1
            OSC <- /Syndicate/Deck/1/Playing 0

            """)
    }

    @Test("The window draws the newest 2,000 shown lines; Copy still takes every shown line (#218)")
    func drawLimit() {
        var lines = DiagnosticsLines()
        for n in 1...2_500 { lines.append(to: .osc, message: "OSC -> /Syndicate/Browser/Down \(n)") }
        let drawn = lines.drawn(.osc)
        #expect(drawn.count == 2_000)
        #expect(drawn.first?.message == "OSC -> /Syndicate/Browser/Down 501")
        #expect(drawn.last?.message == "OSC -> /Syndicate/Browser/Down 2500")
        #expect(lines.plainText(.osc).split(separator: "\n").count == 2_500)
    }

    @Test("400 messages a second for 60 seconds: 24,000 appends, then a refresh of the shown lines, stay well inside budget (#218)")
    func sustainedLoad() {
        var lines = DiagnosticsLines()
        lines.hideStreaming = false
        let clock = ContinuousClock()
        let appending = clock.measure {
            for n in 0..<24_000 {
                let message = switch n % 4 {
                case 0: "OSC <- /Syndicate/Deck/\(n % 3 + 1)/Position \(n)"
                case 1: "OSC <- /Syndicate/Deck/\(n % 3 + 1)/BarRamp 0.\(n)"
                case 2: "OSC <- /Syndicate/Mixer/CH\(n % 3 + 1)/Meter 0.\(n)"
                default: "OSC <- /Syndicate/Deck/1/Playing \(n % 2)"
                }
                lines.append(to: .osc, message: message)
            }
        }
        var drawn: [DiagnosticsLines.Line] = []
        let refreshing = clock.measure { drawn = lines.drawn(.osc) }
        #expect(drawn.count == 2_000)
        // A guard against going quadratic again (500 lines' removeFirst at 20,000 took seconds), not a timing spec: this
        // runs as a debug build on a shared CI runner, where one refresh took 115 ms. The app's release build measured
        // 15 ms on an M-series Mac, well inside the window's 100 ms between refreshes.
        #expect(appending < .seconds(2), "appending took \(appending)")
        #expect(refreshing < .milliseconds(500), "a refresh took \(refreshing)")
    }

    @Test("Hidden streaming lines can't push the rest out: after 20,100 of them, the Playing line is still shown (#97)")
    func hiddenLinesDontEvict() {
        var lines = DiagnosticsLines()
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 1")
        for n in 1...20_100 { lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Progress 0.\(n)") }
        #expect(lines.shown(.osc).map(\.message) == ["OSC <- /Syndicate/Deck/1/Playing 1"])

        // Unticking the box shows everything in arrival order, newest 20,000: the Progress list kept its newest 20,000
        // (0.101 to 0.20100), and with Playing that is 20,001 lines, so the oldest of them (Playing) is past the limit.
        lines.hideStreaming = false
        lines.collapseStreaming = false
        let all = lines.shown(.osc)
        #expect(all.count == 20_000)
        #expect(all.first?.message == "OSC <- /Syndicate/Deck/1/Progress 0.101")
        #expect(all.last?.message == "OSC <- /Syndicate/Deck/1/Progress 0.20100")
    }

    @Test("The monitor says which notes it hides, so a quiet port doesn't look dead; with none hidden it says nothing")
    func hiddenNotesHint() {
        #expect(DiagnosticsTab.hiddenNotesHint([52]) == "Note 52, the controller's idle heartbeat, is hidden.")
        #expect(DiagnosticsTab.hiddenNotesHint([52, 53]) == "Notes 52 and 53, which the controller sends on its own, are hidden.")
        #expect(DiagnosticsTab.hiddenNotesHint([]) == nil)
    }

    // #162: the visible tab, as plain text to copy or save.

    @Test("A tab's plain text is its shown lines, oldest first, each ending in a newline; UNMAPPED keeps its words only")
    func plainText() {
        var lines = DiagnosticsLines()
        lines.append(to: .monitor, message: "12:00:01.000  1  Note On  1 127  ", label: "play")
        lines.append(to: .monitor, message: "12:00:02.000  1  Note On 99 127  ", label: "UNMAPPED", isUnmapped: true)
        lines.append(to: .osc, message: "OSC -> /Syndicate/Deck/1/PlayPause 1")
        #expect(lines.plainText(.monitor) == "12:00:01.000  1  Note On  1 127  play\n12:00:02.000  1  Note On 99 127  UNMAPPED\n")
        #expect(lines.plainText(.sweep) == "")
    }

    @Test("The OSC tab's plain text follows the streaming filter, both ways")
    func plainTextFollowsFilter() {
        var lines = DiagnosticsLines()
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Playing 1")
        lines.append(to: .osc, message: "OSC <- /Syndicate/Deck/1/Progress 0.25")
        lines.append(to: .osc, message: "OSC -> /Syndicate/Deck/1/PlayPause 1")
        #expect(lines.plainText(.osc) == "OSC <- /Syndicate/Deck/1/Playing 1\nOSC -> /Syndicate/Deck/1/PlayPause 1\n")
        lines.hideStreaming = false
        #expect(lines.plainText(.osc)
            == "OSC <- /Syndicate/Deck/1/Playing 1\nOSC <- /Syndicate/Deck/1/Progress 0.25\nOSC -> /Syndicate/Deck/1/PlayPause 1\n")
    }

    @Test("Save… suggests the app's name and the tab's, as a .txt file", arguments: [
        (DiagnosticsTab.monitor, "DeckBridge MIDI Monitor.txt"),
        (.sweep, "DeckBridge LED Sweep.txt"),
        (.osc, "DeckBridge OSC Log.txt"),
    ])
    func exportFileName(tab: DiagnosticsTab, name: String) {
        #expect(tab.exportFileName(appName: "DeckBridge") == name)
    }
}
