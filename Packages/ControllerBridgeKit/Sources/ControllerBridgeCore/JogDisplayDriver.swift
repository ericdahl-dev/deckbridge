// Drives the LC6000 jog display (#165): the hello, then one image upload at a time, into slot 1 and 2 by turns so the
// shown image stays up while the next one loads, the newest content winning; a refusal or a silent unit is logged
// once and not retried until the content changes; goodbye at the end.

/// Where the jog display's messages go: the Controller port (the hello and goodbye) and the WD port (images, the
/// needle). The app's CoreMIDI adapter, a test's fake, and the Diagnostics simulator (#221) all take this.
public protocol JogDisplayPort: AnyObject, Sendable {
    func sendController(_ bytes: [UInt8])
    func sendWD(_ bytes: [UInt8])
    /// Whether the unit's WD port is there now (#305). Without it there's no display to say hello to.
    var isAttached: Bool { get }
    /// Returns once everything sent so far has gone out (#600): the app is about to exit.
    func flush()
}

extension JogDisplayPort {
    public var isAttached: Bool { true }
    public func flush() {}
}

/// What the display shows for the deck in front (#165). Two of these that are equal draw the same image.
public struct JogDisplayContent: Equatable, Sendable {
    public var deck: Int
    /// The deck's color, [r, g, b].
    public var color: [Int]
    /// From Syndicate's TrackInfo: nil until a track is loaded.
    public var title: String?
    public var artist: String?
    public var key: String?
    public var bpm: Double?
    /// "track", "empty", or what a clip or sequencer says (#209).
    public var playerType: String?
    /// Syndicate's feedback has stopped (#464): the display shows the waiting look, our logo, instead of stale values.
    public var stale: Bool

    public init(deck: Int, color: [Int], title: String? = nil, artist: String? = nil, key: String? = nil, bpm: Double? = nil,
                playerType: String? = nil, stale: Bool = false) {
        self.deck = deck
        self.color = color
        self.title = title
        self.artist = artist
        self.key = key
        self.bpm = bpm
        self.playerType = playerType
        self.stale = stale
    }
}

/// What the driver did, for the Diagnostics simulator (#221): the same facts as the bytes it sent.
public enum JogDisplayEvent: Equatable, Sendable {
    case connected
    case disconnected
    /// An image for `content` started into `slot`: `bytes` of SysEx on the wire.
    case uploadStarted(slot: UInt8, content: JogDisplayContent, bytes: Int)
    /// The unit stored it and shows `slot` now.
    case shown(slot: UInt8)
    /// The upload stopped: refused with the ack's status, or nil for no answer.
    case failed(refusal: UInt8?)
    /// The needle on the unit: the deck in front's (pitch bend on WD).
    case needle(pitchBend: Int)
    case playLight(Bool)
    /// Each deck's needle for the simulator (#165): its own phase in the bar. Nothing is sent for it.
    case deckNeedle(deck: Int, pitchBend: Int)
    /// The master clock's beat (1-4), the lit ring segment on every deck. Nothing is sent for it (#215 may draw it).
    case masterBeat(Int)
    /// Whether `deck` is playing, from Syndicate's feedback, reported on change (#317). Nothing is sent for it: the
    /// unit's play light is `playLight`, which also blinks while a loaded deck is paused.
    case deckPlaying(deck: Int, playing: Bool)
    /// What a deck's display would show (#221): every deck, live, for the simulator; only the deck in front is
    /// uploaded. Nothing is sent for it.
    case preview(JogDisplayContent)
    /// What a deck's drawn display would show (#465), as the chip would decode it from the host's messages: every deck,
    /// live, while the jog display would draw (previewsDrawn). Nothing is sent for it.
    case drawnPreview(DrawnDisplayState)
    /// The previews show images again (#465): the view goes back to `preview`'s images.
    case drawnPreviewsEnded
}

extension JogDisplayEvent {
    /// The event's line in the Debug trace (#605); nil for the per-tick events (each deck's drawn state and needle, and
    /// the deck in front's needle, #637), which at the live cadence filled a 20 MB file in about a minute. What the unit
    /// gets is in the WD out lines; mode changes have their own.
    public var traceLine: String? {
        switch self {
        case .drawnPreview, .deckNeedle, .needle: nil
        default: "event \(self)"
        }
    }
}

public final class JogDisplayDriver {
    /// Called with each thing the driver does (#221).
    public var onEvent: ((JogDisplayEvent) -> Void)?

    /// The unit's ports; nil when there's no LC6000 jog display, and the driver only previews (#221).
    private let port: (any JogDisplayPort)?
    private let clock: any Clock
    private let log: any LogSink
    /// The image's width and height: 198 on the unit.
    private let size: Int
    /// Draws content as RGBA rows, upright; the driver turns and encodes it.
    private let render: (JogDisplayContent) -> [UInt8]
    /// Draws content with one master beat (1–4) lit (#215). When set, each deck's content goes up once per beat, into
    /// that deck's own slots (#424), and each master beat shows the front deck's slot; when nil, one image alternates
    /// between slots 1 and 2.
    private let renderBeat: ((JogDisplayContent, Int) -> [UInt8])?
    /// The unit's display firmware (#425): Denon's shows slots 1-15 (it drops a show above 15, though it stores 16);
    /// a unit flashed with the slot 16 patch shows all 16. Changing it uploads, or stops using, deck 4's fourth beat.
    public var displayFirmware = DisplayFirmware.denon {
        didSet {
            guard displayFirmware != oldValue else { return }
            if connected { handshakeAgain() }
            if upload == nil { next() }
        }
    }
    /// Deck N's beat B lives in slot (N - 1) × 4 + B (#424), so every deck's images stay on the unit and a deck switch
    /// is one show. Nil past the last slot the firmware shows: on Denon's, deck 4's beat 4, where its screen holds.
    func slot(deck: Int, beat: Int) -> UInt8? {
        guard (1...4).contains(deck), (1...4).contains(beat) else { return nil }
        let slot = (deck - 1) * 4 + beat
        return slot <= displayFirmware.showableSlots ? UInt8(slot) : nil
    }
    /// Every deck's content to keep on the unit, the front deck's too.
    private var contents: [Int: JogDisplayContent] = [:]
    /// Failed tries per slot for its deck's content: a stalled upload is tried again, up to `beatTries` in all.
    private var beatFailures: [UInt8: Int] = [:]
    static let beatTries = 3
    /// What each slot holds on the unit now: a slot is shown on its beat only if it holds its deck's content.
    private var slotContent: [UInt8: JogDisplayContent] = [:]
    /// The slot on the unit's screen (beat mode): each upload leads with it, so the screen holds while a slot goes up.
    private var screenSlot: UInt8?

    /// How long an upload may wait for the unit's answers.
    static let timeout = 5.0

    /// The debug trace (#395): every message to the unit and every reply, for the WD work (#165).
    public var trace: TraceSink?
    /// When the last SysEx went out on WD, so a reply's trace line says how long it took.
    private var lastWDSend: Double?

    private func sendWD(_ bytes: [UInt8]) {
        port?.sendWD(bytes)
        if bytes.first == 0xF0 { lastWDSend = clock.now }
        trace?(.jogDisplay, "WD out " + Self.describe(bytes))
    }

    private func sendController(_ bytes: [UInt8]) {
        port?.sendController(bytes)
        trace?(.jogDisplay, "CTL out " + Self.describe(bytes))
    }

    /// "cmd=0x0A 11 bytes" for the unit's own SysEx (F0, a 5-byte head, the command); anything else as hex.
    static func describe(_ bytes: [UInt8]) -> String {
        if bytes.count > 7, bytes[0] == 0xF0, Array(bytes[1...3]) == [0x00, 0x02, 0x0B] {
            // Drawn messages share one command and two ops share a length (#582): name the op.
            if bytes[6] == DrawnDisplay.command, bytes.count > 9, let op = DrawnDisplayProtocol.Op(rawValue: bytes[9]) {
                return String(format: "cmd=0x%02X op=%02X %@ %d bytes", bytes[6], bytes[9], "\(op)", bytes.count)
            }
            return String(format: "cmd=0x%02X %d bytes", bytes[6], bytes.count)
        }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// "WD in cmd=0x0F status=0x00 +12 ms": a reply's command, its status (the first payload byte, when there is one)
    /// and the time since the last SysEx sent.
    private func traceReply(_ bytes: [UInt8]) {
        guard let trace else { return }
        var text = "WD in "
        if bytes.count > 4, Array(bytes[0...1]) == [0xF0, 0x7E], Array(bytes[3...4]) == [0x06, 0x02] {
            // A universal identity reply carries the unit's serial number in ASCII; users attach the trace to issues.
            text += "identity reply (serial redacted)"
        } else if bytes.count > 9, bytes[0] == 0xF0, Array(bytes[1...3]) == [0x00, 0x02, 0x0B] {
            text += String(format: "cmd=0x%02X", bytes[6])
            let length = Int(bytes[7]) << 7 | Int(bytes[8])
            if length > 0, bytes.count > 9 { text += String(format: " status=0x%02X", bytes[9]) }
        } else {
            text += bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        if let lastWDSend { text += " +\(Int(((clock.now - lastWDSend) * 1000).rounded())) ms" }
        trace(.jogDisplay, text)
    }
    /// How long after the last ack an upload counts as stored without the commit reply, which the unit sometimes
    /// skips while still showing the image (#165).
    static let commitGrace = 0.3

    /// How the unit shows the deck (#456): images (Denon's firmware, or custom that didn't answer), waiting for the
    /// custom firmware's answer to the capability question, or drawing the screen itself from small messages.
    enum Mode: Equatable {
        case images
        case asking(since: Double)
        case drawn(version: Int)
    }
    private(set) var mode = Mode.images { didSet { reportPreviewsIfStaleChanged() } }
    /// The firmware found (#456): nil before the hello and while asking.
    var found: DisplayFound? {
        guard connected else { return nil }
        switch mode {
        case .asking: return nil
        case .drawn(let version): return .customDrawn(version: version)
        case .images: return displayFirmware == .custom ? .customImages : .denon
        }
    }
    /// How long custom firmware has to answer the capability question: a USB round trip is milliseconds, and half a
    /// second costs less than two image uploads (#456).
    static let answerTimeout = 0.5
    /// The last deck message sent in drawn mode, so only a change goes out.
    private var lastDeck: [UInt8]?
    /// The deck in front's state flags for drawn mode (#464), and the last state message sent.
    private var drawnState: DrawnDisplay.State = []
    private var lastState: [UInt8]?
    /// The deck in front's text and tempo messages last sent in drawn mode (#458), in full-state order.
    private var lastTexts: [[UInt8]] = []
    /// When drawn mode last sent begin and the full state (#464): the heartbeat sends them again every second, so a
    /// chip that reset without its port going away is brought back, and one whose host is gone goes stale on its own.
    private var lastFullState: Double?
    static let heartbeat = 1.0

    /// Whether it has said hello to a unit (#165); the Coordinator repaints the LEDs after the hello (#426).
    public private(set) var connected = false
    /// Whether the hello went out and no goodbye since.
    public var isConnected: Bool { connected }
    /// The last needle and play light sent, so only changes go out.
    private var lastNeedle: Int?
    private var lastPlayLight: Bool?
    /// The content shown, or being uploaded, and the content wanted next.
    private var current: JogDisplayContent?
    private var wanted: JogDisplayContent?
    /// The slot shown; the next upload goes into the other one.
    private var shownSlot: UInt8 = 2
    /// The last content drawn and its image (#221): what the preview drew goes to the unit when it connects, unredrawn.
    /// Each deck's last previewed content.
    private var previews: [Int: JogDisplayContent] = [:]
    private var deckNeedles: [Int: Int] = [:]
    private var lastMasterBeat: Int?
    private var deckPlays: [Int: Bool] = [:]
    private var drawn: (content: JogDisplayContent, image: [UInt8])?
    /// The upload in flight; `content` is what its slot will hold (beat mode).
    typealias Running = (upload: JogDisplay.Upload, slot: UInt8, acks: Int, finished: Bool, startedAt: Double, content: JogDisplayContent?)
    private var upload: Running?

    public init(port: (any JogDisplayPort)?, clock: any Clock, log: any LogSink, size: Int = JogImage.size,
                renderBeat: ((JogDisplayContent, Int) -> [UInt8])? = nil,
                render: @escaping (JogDisplayContent) -> [UInt8]) {
        self.port = port
        self.clock = clock
        self.log = log
        self.size = size
        self.renderBeat = renderBeat
        self.render = render
    }

    /// Whether a unit's WD port is there to show on (#305).
    public var attached: Bool { port?.isAttached == true }

    /// Whether images are going up to the unit now (#422): one in flight, or more of the content's slots still to go.
    public var uploading: Bool {
        guard connected, mode == .images else { return false }
        return upload != nil || (renderBeat != nil && nextJob() != nil)
    }

    /// The unit is attached: say hello as a host, then show what's wanted. With no port it stays a preview.
    public func connect() {
        guard !connected, let port else { return }
        connected = true
        // What the preview showed goes to the unit now, and the needle and light are sent afresh.
        if wanted == nil { wanted = current }
        current = nil
        slotContent = [:]
        beatFailures = [:]
        screenSlot = nil
        lastNeedle = nil
        lastPlayLight = nil
        for message in JogDisplay.hello { sendController(message) }
        hello = (at: clock.now, resent: 0, due: clock.now + Self.helloAgainFirst, said: false)
        awaitingReady = true
        readyAskedSince = nil
        readyPending = false
        lastShow = nil
        // Custom firmware may draw the screen itself (#456): ask. Denon's is never asked.
        mode = .images
        lastDeck = nil
        lastState = nil
        if displayFirmware == .custom {
            mode = .asking(since: clock.now)
            ask()
        }
        onEvent?(.connected)
        next()
    }

    /// The unit is going away, or the app is quitting: goodbye, so it returns to standalone.
    public func disconnect() {
        guard connected else { return }
        // Drawn mode ends first, so the unit's own screen comes back (#456); unless the app is quitting (#600).
        if case .drawn(let version) = mode {
            if quitting, let leaving { leaveLogo(leaving) } else { endDrawing(version) }
        }
        mode = .images
        asked = false
        reasks = nil
        if hello?.said == true { trace?(.jogDisplay, "jog display: hello re-sends stop: goodbye") }
        hello = nil
        awaitingReady = false
        readyPending = false
        connected = false
        upload = nil
        lastNeedle = nil
        lastPlayLight = nil
        current = nil
        sendController(JogDisplay.goodbye)
        onEvent?(.disconnected)
    }

    /// The hub of our logo when the app quits (#600): the app icon's own hub, a neutral gray from the logo's palette.
    static let quitHub = [0xD5, 0xD5, 0xD5]

    /// The app is quitting (#600): from now on no new content goes to the unit, and the disconnect
    /// to come, as the controllers drop one by one, leaves our logo up in drawn mode, not Denon's screen. The deck in
    /// front now is the one it shows.
    private var quitting = false, leaving: JogDisplayContent?
    public func quit() {
        quitting = true
        if case .drawn = mode { leaving = current }
    }

    /// The deck again with the neutral hub, then its state with stale, and no end, so the chip keeps drawing the waiting
    /// look (the deck's number in the hub) after the app is gone (#600).
    private func leaveLogo(_ content: JogDisplayContent) {
        sendWD(DrawnDisplay.Message.deck(number: content.deck, color: Self.quitHub,
                                         player: DrawnDisplay.Player(playerType: content.playerType)).bytes)
        drawnState.insert(.stale)
        sendWD(DrawnDisplay.Message.state(drawnState).bytes)
    }

    /// Returns once everything sent so far has gone out (#600): the app is about to exit.
    public func flush() {
        port?.flush()
    }

    /// Asks for `content` on the display. Equal content sends nothing; while an upload runs, only the newest waits.
    public func show(_ content: JogDisplayContent) {
        guard !quitting else { return }
        wanted = content
        if upload == nil { next() }
    }

    /// Another deck's content, kept on the unit in that deck's slots (#424), after the front deck's. Beat mode only.
    public func keep(_ content: JogDisplayContent) {
        guard !quitting, renderBeat != nil, content.deck != (wanted ?? current)?.deck, contents[content.deck] != content else { return }
        contents[content.deck] = content
        forgetFailures(deck: content.deck)
        if upload == nil { next() }
    }

    private func forgetFailures(deck: Int) {
        for beat in 1...4 { if let slot = slot(deck: deck, beat: beat) { beatFailures[slot] = nil } }
    }

    /// The front deck's slot for the beat now, on screen if it holds the deck's content.
    private func showFrontBeat() {
        guard let current, let slot = slot(deck: current.deck, beat: lastMasterBeat ?? 1), slotContent[slot] == current else { return }
        if connected {
            sendWD(JogDisplay.show(slot: slot))
            lastShow = (slot, JogDisplay.show(slot: slot))
            showAfterReady(sent: true)
        }
        screenSlot = slot
        onEvent?(.shown(slot: slot))
    }

    /// The next slot to upload: the front deck's first, from the master's beat, then the other decks'. A slot given up
    /// on is skipped until its deck's content changes.
    private func nextJob() -> (content: JogDisplayContent, beat: Int, slot: UInt8)? {
        let first = lastMasterBeat ?? 1
        var decks: [JogDisplayContent] = []
        if let current { decks.append(current) }
        for deck in contents.keys.sorted() where deck != current?.deck { if let content = contents[deck] { decks.append(content) } }
        for content in decks {
            for offset in 0..<4 {
                let beat = (first - 1 + offset) % 4 + 1
                guard let slot = slot(deck: content.deck, beat: beat), slotContent[slot] != content,
                      (beatFailures[slot] ?? 0) < Self.beatTries else { continue }
                return (content, beat, slot)
            }
        }
        return nil
    }

    /// The needle at `pitchBend` (0...16383): pitch bend on WD ch1. Only a change goes out.
    public func needle(_ pitchBend: Int) {
        guard pitchBend != lastNeedle else { return }
        lastNeedle = pitchBend
        // Drawing, the chip draws the needle from our message, and stock's pitch bend would only make it recompose
        // its own hidden layer (#459, agent2's #466 reading).
        if connected, case .drawn = mode { sendWD(DrawnDisplay.Message.needle(pitchBend).bytes) }
        else if connected { sendWD([0xE0, UInt8(pitchBend & 0x7F), UInt8(pitchBend >> 7 & 0x7F)]) }
        onEvent?(.needle(pitchBend: pitchBend))
    }

    /// A deck's needle for the simulator, reported on change; nothing is sent to the unit.
    public func deckNeedle(deck: Int, _ pitchBend: Int) {
        guard deckNeedles[deck] != pitchBend else { return }
        deckNeedles[deck] = pitchBend
        onEvent?(.deckNeedle(deck: deck, pitchBend: pitchBend))
    }

    /// The master clock's beat, reported on change; nothing is sent to the unit.
    public func masterBeat(_ beat: Int) {
        guard beat != lastMasterBeat else { return }
        lastMasterBeat = beat
        onEvent?(.masterBeat(beat))
        // Drawing, the chip lights the section itself (#459); no image is shown.
        if case .drawn = mode { return connected ? sendWD(DrawnDisplay.Message.beat(beat).bytes) : () }
        // Beat mode (#215): show the beat's slot, if it holds what's current; otherwise the screen holds. Never in the
        // middle of an upload: a show between its chunks can spoil it (ack 06). The upload's end shows the beat now.
        guard renderBeat != nil, upload == nil else { return }
        showFrontBeat()
    }

    /// A deck's play state, reported on change; nothing is sent to the unit.
    public func deckPlaying(deck: Int, _ playing: Bool) {
        guard deckPlays[deck] != playing else { return }
        deckPlays[deck] = playing
        onEvent?(.deckPlaying(deck: deck, playing: playing))
    }

    /// The play light: note 1 on WD ch1, 127 or 0. Only a change goes out.
    public func playLight(_ on: Bool) {
        guard on != lastPlayLight else { return }
        lastPlayLight = on
        // Drawing, stock's play light does nothing (#459, agent2's #466 reading): it isn't sent.
        if connected, !drawing { sendWD([0x90, 0x01, on ? 0x7F : 0x00]) }
        onEvent?(.playLight(on))
    }

    /// A deck's content for the simulator (#221), reported on change; nothing is sent to the unit. While feedback is
    /// stale it shows the waiting look (#502), from the same flag as the drawn state's stale bit.
    public func preview(_ content: JogDisplayContent) {
        guard previews[content.deck] != content else { return }
        previews[content.deck] = content
        reportPreview(content)
    }

    /// Whether the jog display would draw, so the previews show the drawn layout (#465): a unit that answered draws, one
    /// that didn't shows images; with no unit, Custom shows the drawn look so it can be tried, Denon the images.
    public var previewsDrawn: Bool { connected ? drawing : displayFirmware == .custom }
    private var drawnPreviews: [Int: DrawnDisplayState] = [:]
    /// Each deck's drawn preview as last reported; forgotten while previews show images, so the switch back reports all.
    private var reportedDrawn: [Int: DrawnDisplayState] = [:]

    /// A deck's live drawn values for the preview (#465): its flags, needle, meter, phase and time (op 06's message), with its content as
    /// `preview` last gave it and the master beat. They go through the deck's own copy of the chip's state as the
    /// messages the host would send, and a change is reported while previews are drawn (all of them again once they are).
    public func drawnPreview(deck: Int, flags: DrawnDisplay.State, needle: Int?, meter: (level: Int, peak: Int)?,
                             phase: Int, time: DrawnDisplay.Message? = nil) {
        guard let content = previews[deck] else { return }
        typealias Message = DrawnDisplay.Message
        let color = content.color.count == 3 ? content.color : [255, 255, 255]
        var messages: [Message] = [.begin(version: DrawnDisplay.version),
                                   .deck(number: deck, color: color, player: DrawnDisplay.Player(playerType: content.playerType)),
                                   .state(drawnState.contains(.stale) ? flags.union(.stale) : flags),
                                   .beat(lastMasterBeat ?? 0), .phase(phase)]
        if let needle { messages.append(.needle(needle)) }
        if let meter { messages.append(.meter(level: meter.level, peak: meter.peak)) }
        if let time { messages.append(time) }
        var state = drawnPreviews[deck] ?? DrawnDisplayState()
        // On the driver's clock (#569): fed every tick, the copy hears the host as the chip would, so it goes silent
        // only if the feed stops.
        let now = Int(clock.now * 1000)
        for bytes in messages.map(\.bytes) + Self.texts(content) { state.apply(bytes, atMs: now) }
        state.tick(atMs: now)
        drawnPreviews[deck] = state
        guard previewsDrawn else {
            if !reportedDrawn.isEmpty { onEvent?(.drawnPreviewsEnded) }
            return reportedDrawn.removeAll()
        }
        guard reportedDrawn[deck] != state else { return }
        reportedDrawn[deck] = state
        onEvent?(.drawnPreview(state))
    }

    /// Whether the previews show the waiting look: only while the unit draws, as only then does its screen (#502).
    private var previewStale: Bool { drawing && drawnState.contains(.stale) }
    private var reportedStale = false

    private func reportPreview(_ content: JogDisplayContent) {
        var shown = content
        shown.stale = previewStale
        onEvent?(.preview(shown))
    }

    /// Every deck's preview again when the waiting look comes or goes.
    private func reportPreviewsIfStaleChanged() {
        guard previewStale != reportedStale else { return }
        reportedStale = previewStale
        for deck in previews.keys.sorted() { reportPreview(previews[deck]!) }
    }

    /// Whether the capability question went out since the hello (#604): an answer after the fallback to images still
    /// counts, since a unit just power cycled answers only once its chip has started.
    private var asked = false

    private func ask() {
        asked = true
        sendWD(DrawnDisplay.Message.capability(version: DrawnDisplay.version).bytes)
    }

    /// The question again after the fallback to images (#604), custom firmware only: `reaskLimit` times, the first
    /// `reaskFirst` s after it and each gap twice the last (1, 3, 7, 15, 31 s), then never until the next hello. Only the
    /// same question again; Denon's firmware drops it silently (#466).
    static let reaskFirst = 1.0, reaskLimit = 5
    private var reasks: (done: Int, due: Double)?

    private func reaskIfDue() {
        guard case .images = mode, let pending = reasks, clock.now >= pending.due - 1e-9 else { return }
        ask()
        let done = pending.done + 1
        reasks = done < Self.reaskLimit ? (done, clock.now + Self.reaskFirst * Double(1 << done)) : nil
    }

    /// The hello again while the top panel hasn't answered it (#606): after a power cycle it can miss the first. The
    /// same pair, `helloAgainLimit` times, the first `helloAgainFirst` s after the hello and each gap twice the last (1,
    /// 3, 7, 15, 31 s), then never until the next connect. An answer is due within `helloAnswerTime` of a hello.
    static let helloAgainFirst = 1.0, helloAgainLimit = 5, helloAnswerTime = 0.5
    /// The hello awaiting the top panel's answer: when it first went, how many re-sends, the next one's time (nil
    /// after the last), and whether the trace said it wasn't answered. Nil once answered, given up on, or gone.
    private var hello: (at: Double, resent: Int, due: Double?, said: Bool)?

    private func helloAgainIfDue() {
        guard connected, var waiting = hello else { return }
        let now = clock.now
        if !waiting.said, now >= waiting.at + Self.helloAnswerTime - 1e-9 {
            waiting.said = true
            trace?(.jogDisplay, "jog display: no answer to the hello in 0.5 s: sending it again at 1, 3, 7, 15, 31 s")
        }
        if let due = waiting.due, now >= due - 1e-9 {
            for message in JogDisplay.hello { sendController(message) }
            waiting.resent += 1
            trace?(.jogDisplay, "jog display: hello again (\(waiting.resent) of \(Self.helloAgainLimit))")
            // From now, not from when it was due: a stalled tick sends one pair, not the missed ones in a burst.
            waiting.due = waiting.resent < Self.helloAgainLimit ? now + Self.helloAgainFirst * Double(1 << waiting.resent) : nil
            if waiting.due == nil { lastHelloAt = now }
        } else if waiting.due == nil, let last = lastHelloAt, now >= last + Self.helloAnswerTime - 1e-9 {
            let text = String(format: "the top panel never answered the hello (%d re-sends, %.1f s): no more",
                              waiting.resent, now - waiting.at)
            log.log("The jog display: " + text)
            trace?(.jogDisplay, "jog display: " + text)
            hello = nil
            return
        }
        hello = waiting
    }
    private var lastHelloAt: Double?

    /// The top panel answered the hello (#606): ch16 note 55 on (`9F 37 7F`). Shift + deck select sends the same, and
    /// stops the re-sends too. Whether a re-sent hello was the one answered.
    @discardableResult
    public func helloAnswered() -> Bool {
        guard connected, let waiting = hello else { return false }
        hello = nil
        if waiting.said {
            trace?(.jogDisplay, String(format: "jog display: the top panel answered the hello %.1f s after it: no more re-sends",
                                       clock.now - waiting.at))
        }
        return waiting.resent > 0
    }

    /// Whether the display chip hasn't said ready since the hello (#606). After a power cycle its own boot sequence
    /// covers the host's images until it ends; it then answers the pending 10, and the next 0A uncovers them. Its
    /// first 10 reply sends the last show again, so that 0A comes at once.
    private var awaitingReady = false
    /// The last show sent for a stored slot: never an upload's lead.
    private var lastShow: (slot: UInt8, bytes: [UInt8])?

    /// Ready came, and the show again waits for the upload in flight to end: a 0A between its chunks can spoil it.
    private var readyPending = false
    private static let readySaid = "jog display: the display said ready (its first 10 reply since the hello): "

    /// When the first 10 since the hello went (#606): no reply `readyWait` s later is said once; nothing is sent for it.
    private var readyAskedSince: Double?
    static let readyWait = 60.0

    private func neverReadyIfDue() {
        guard awaitingReady, connected, case .images = mode, let since = readyAskedSince,
              clock.now - since >= Self.readyWait - 1e-9 else { return }
        awaitingReady = false
        let text = "the display never said ready in 60 s (no 10 reply since the hello); nothing sent for it"
        log.log("The jog display: " + text)
        trace?(.jogDisplay, "jog display: " + text)
    }

    private func readyIfFirst(_ bytes: [UInt8]) {
        guard awaitingReady, connected, case .images = mode, JogDisplay.Reply(bytes) == .committed else { return }
        awaitingReady = false
        readyPending = true
    }

    /// The show after ready: an upload's own, once stored, counts; with none in flight, the last show again.
    private func showAfterReady(sent: Bool) {
        guard readyPending else { return }
        if sent {
            readyPending = false
            return trace?(.jogDisplay, Self.readySaid + "a show went out after it, nothing sent again") ?? ()
        }
        guard upload == nil else { return }
        readyPending = false
        guard connected, case .images = mode else { return }
        guard let lastShow else { return trace?(.jogDisplay, Self.readySaid + "nothing shown yet, nothing sent") ?? () }
        sendWD(lastShow.bytes)
        trace?(.jogDisplay, Self.readySaid + "show slot \(lastShow.slot) sent again")
    }

    /// A message from the WD port.
    public func reply(_ bytes: [UInt8]) {
        traceReply(bytes)
        readyIfFirst(bytes)
        defer { showAfterReady(sent: false) }
        if case .asking = mode, let version = DrawnDisplay.answer(bytes) {
            return draw(version: min(version, DrawnDisplay.version))
        }
        // A late answer, in images (#604): drawn from here. An upload in flight is dropped; the chip draws over it.
        if case .images = mode, asked, let version = DrawnDisplay.answer(bytes) {
            upload = nil
            return draw(version: min(version, DrawnDisplay.version))
        }
        // A refusal (ack 06) ends the wait at once. Denon's firmware never sends one for this command: it says nothing,
        // so the timeout is its path (#466).
        if case .asking = mode, upload == nil, case .refused = JogDisplay.Reply(bytes) { return showImages() }
        // A refusal to the question again (#604): not drawing firmware after all, so no more asking.
        if case .images = mode, reasks != nil, upload == nil, case .refused = JogDisplay.Reply(bytes) {
            reasks = nil
            return
        }
        guard var running = upload, let reply = JogDisplay.Reply(bytes) else { return }
        switch reply {
        case .accepted where !running.finished:
            running.acks += 1
            if running.acks == running.upload.expectedAcks {
                running.finished = true
                running.startedAt = clock.now   // from here, the commit grace
                for message in running.upload.finish { sendWD(message) }
                if readyAskedSince == nil { readyAskedSince = clock.now }
            }
            upload = running
        case .refused(let status):
            log.log("The jog display refused the image (ack \(String(format: "%02X", status))); it keeps what it showed")
            fail(running)
            onEvent?(.failed(refusal: status))
        case .committed where running.finished:
            stored(running)
        default:
            break
        }
    }

    /// The unit has the image: show it (in beat mode, only on its beat) and start the next upload.
    private func stored(_ running: Running) {
        upload = nil
        if renderBeat != nil {
            if let content = running.content { slotContent[running.slot] = content }
            // The front deck's slot for the beat now goes on screen after every upload, once it holds its content; the
            // others wait for their beat. A deck asked for meanwhile is the front deck from here.
            adoptWanted()
            showFrontBeat()
        } else {
            showSlot(running)
        }
        next()
    }

    private func showSlot(_ running: Running) {
        sendWD(running.upload.show)
        lastShow = (running.slot, running.upload.show)
        showAfterReady(sent: true)
        shownSlot = running.slot
        onEvent?(.shown(slot: running.slot))
    }

    /// Times out a silent upload; starts the next one.
    public func tick() {
        if case .asking(let since) = mode, clock.now - since >= Self.answerTimeout - 1e-9 {
            showImages()
            if displayFirmware == .custom { reasks = (0, clock.now + Self.reaskFirst) }
        }
        reaskIfDue()
        helloAgainIfDue()
        if case .drawn = mode, let last = lastFullState, clock.now - last >= Self.heartbeat - 1e-9 { beat() }
        if let running = upload, running.finished, clock.now - running.startedAt >= Self.commitGrace {
            stored(running)
        } else if let running = upload, clock.now - running.startedAt >= Self.timeout {
            log.log("The jog display didn't answer the upload to slot \(running.slot) (\(running.acks) of "
                    + "\(running.upload.expectedAcks) acks); it keeps what it showed")
            fail(running)
            onEvent?(.failed(refusal: nil))
        }
        showAfterReady(sent: false)
        neverReadyIfDue()
        if upload == nil { next() }
    }

    /// The upload is over without a show: what's shown stays, and nothing retries until the content changes.
    private func fail(_ running: Running) {
        upload = nil
        guard renderBeat != nil else {
            wanted = nil
            return
        }
        // Beat mode: a stalled slot (seen after a deck change, 1 of 3 acks) is tried again, then given up on; the other
        // slots still go up, so the ring keeps stepping.
        let failures = (beatFailures[running.slot] ?? 0) + 1
        beatFailures[running.slot] = failures
        if failures >= Self.beatTries {
            log.log("The jog display gave up on slot \(running.slot) after \(Self.beatTries) tries")
        }
    }

    /// Settings' firmware changed while connected (#456): Custom asks the unit; Denon's ends drawn mode, and the deck
    /// in front goes up as images.
    private func handshakeAgain() {
        if case .drawn(let version) = mode {
            endDrawing(version)
            if wanted == nil { wanted = current }
            current = nil
        }
        mode = .images
        // The asking starts over (#604): Denon's firmware is never asked, nor drawn on by a late answer.
        asked = false
        reasks = nil
        lastDeck = nil
        lastState = nil
        if displayFirmware == .custom {
            mode = .asking(since: clock.now)
            ask()
        }
    }

    /// No drawing firmware answered (#456): images, as on Denon's, until the next connect.
    private func showImages() {
        mode = .images
        log.log("The jog display didn't answer as custom firmware that draws; it shows images")
        // The debug trace (deckbridge.log) gets it too: the log above goes to the unified log only.
        trace?(.jogDisplay, "jog display: no drawn-display answer in 0.5 s, using images")
        next()
    }

    /// The unit draws (#456): begin, then the deck in front.
    private func draw(version: Int) {
        mode = .drawn(version: version)
        reasks = nil
        trace?(.jogDisplay, "jog display: drawn display, protocol \(version)")
        sendWD(DrawnDisplay.Message.begin(version: version).bytes)
        if wanted == nil { wanted = current }
        current = nil
        // The full state, every message once, in a fixed order: the deck, then the state.
        next()
        sendState()
        sendLive()
        lastFullState = clock.now
    }

    /// The live part of the full state (#459): the master beat (0 with no master clock), then the needle, if known.
    private func sendLive() {
        sendWD(DrawnDisplay.Message.beat(lastMasterBeat ?? 0).bytes)
        if let lastNeedle { sendWD(DrawnDisplay.Message.needle(lastNeedle).bytes) }
        // The deck's time (#460), once known.
        if let lastTime { sendWD(lastTime); timeCleared = false }
        // The level meter (#461): empty until the deck's channel reports.
        sendWD(DrawnDisplay.Message.meter(level: lastMeter.level, peak: lastMeter.peak).bytes)
        // The phase (#462), once known: the chip's own is unknown until it comes.
        if lastPhase != DrawnPhase.unknown { sendWD(DrawnDisplay.Message.phase(lastPhase).bytes) }
    }

    /// The heartbeat: begin, the deck and the state again, unchanged or not.
    private func beat() {
        guard connected, case .drawn(let version) = mode else { return }
        sendWD(DrawnDisplay.Message.begin(version: version).bytes)
        if let lastDeck { sendWD(lastDeck) }
        let state = DrawnDisplay.Message.state(drawnState).bytes
        lastState = state
        sendWD(state)
        for text in lastTexts { sendWD(text) }
        sendLive()
        lastFullState = clock.now
    }

    private var drawing: Bool { if case .drawn = mode { true } else { false } }

    /// The hand-back (#459): stock's needle is stale after drawing, and it redraws only on a change, so the current
    /// one goes as pitch bend just before end; the play light is sent again on the next tick.
    private func endDrawing(_ version: Int) {
        if let lastNeedle { sendWD([0xE0, UInt8(lastNeedle & 0x7F), UInt8(lastNeedle >> 7 & 0x7F)]) }
        sendWD(DrawnDisplay.Message.end(version: version).bytes)
        lastPlayLight = nil
    }

    /// The deck in front's level meter for drawn mode (#461), 0-127 each; 0 and 0 until its channel reports. Sent
    /// only while drawing, and only on a change; whether it went out.
    private var lastMeter = (level: 0, peak: 0)
    @discardableResult
    public func meter(level: Int, peak: Int) -> Bool {
        guard (level, peak) != lastMeter else { return false }
        lastMeter = (level, peak)
        guard connected, drawing else { return false }
        sendWD(DrawnDisplay.Message.meter(level: level, peak: peak).bytes)
        return true
    }

    /// The deck in front's phase for drawn mode (#462), as op 0B carries it (DrawnPhase's value). Sent only while
    /// drawing, and only on a change; whether it went out. A known one is in the full state and the heartbeat too. The
    /// chip starts each deck at unknown, so a deck change forgets the last one.
    private var lastPhase = DrawnPhase.unknown
    @discardableResult
    public func phase(_ value: Int) -> Bool {
        guard value != lastPhase else { return false }
        lastPhase = value
        guard connected, drawing else { return false }
        sendWD(DrawnDisplay.Message.phase(value).bytes)
        return true
    }

    /// The deck in front's time for drawn mode (#460): sent only while drawing, and only when it changes (the shown
    /// second, or the length); whether it went out.
    private var lastTime: [UInt8]?, timeCleared = false
    @discardableResult
    public func time(_ message: DrawnDisplay.Message) -> Bool {
        let bytes = message.bytes
        guard bytes != lastTime || timeCleared else { return false }
        lastTime = bytes
        guard connected, drawing else { return false }
        timeCleared = false
        sendWD(bytes)
        return true
    }

    /// The deck in front's play state for drawn mode (#459): loaded, playing, a quantized start waiting; and (#463)
    /// a loop on and the CUE button held.
    public func deckState(loaded: Bool, playing: Bool, pending: Bool, loop: Bool = false, cue: Bool = false) {
        let flags: [(DrawnDisplay.State, Bool)] = [(.loaded, loaded), (.playing, playing), (.playPending, pending),
                                                   (.loopOn, loop), (.cueHeld, cue)]
        for (flag, on) in flags { if on { drawnState.insert(flag) } else { drawnState.remove(flag) } }
        sendState()
    }

    /// Syndicate's feedback stopped or came back (#464): drawn mode shows the waiting look while stale.
    public func setStale(_ stale: Bool) {
        // Its own trace line (#605): the preview's events, which carried it, aren't traced any more.
        if stale != drawnState.contains(.stale) {
            trace?(.jogDisplay, stale ? "jog display: Syndicate's feedback stale: the waiting look"
                                      : "jog display: Syndicate's feedback fresh: stale ends")
        }
        if stale { drawnState.insert(.stale) } else { drawnState.remove(.stale) }
        sendState()
        reportPreviewsIfStaleChanged()
    }

    /// Drawn mode: the state message, sent only when it changes.
    private func sendState() {
        guard connected, case .drawn = mode else { return }
        let state = DrawnDisplay.Message.state(drawnState).bytes
        guard state != lastState else { return }
        lastState = state
        sendWD(state)
    }

    /// Drawn mode: the deck in front as one deck message, sent only when it changes.
    private func nextDrawn() {
        guard let content = wanted else { return }
        wanted = nil
        current = content
        let color = content.color.count == 3 ? content.color : [255, 255, 255]
        let deck = DrawnDisplay.Message.deck(number: content.deck, color: color,
                                             player: DrawnDisplay.Player(playerType: content.playerType)).bytes
        guard deck != lastDeck else { return sendChangedTexts(content) }
        lastDeck = deck
        sendWD(deck)
        // The chip's phase is unknown for the new deck (#462): the controller's next value for it goes.
        lastPhase = DrawnPhase.unknown
        // Every deck message is followed by its state: the flags are the deck's (#464). A new deck clears the chip's
        // texts and tempo, so they follow (#458).
        lastState = nil
        sendState()
        lastTexts = Self.texts(content)
        for text in lastTexts { sendWD(text) }
        // It clears the chip's time too (#460): the next time goes, even the same.
        timeCleared = true
    }

    /// Same deck: only the texts and tempo that changed, once each (#458).
    private func sendChangedTexts(_ content: JogDisplayContent) {
        let texts = Self.texts(content)
        defer { lastTexts = texts }
        guard texts.count == lastTexts.count else { return texts.forEach(sendWD) }
        for (text, last) in zip(texts, lastTexts) where text != last { sendWD(text) }
    }

    /// A deck's text and tempo messages (#458): title, artist and key (empty clears one), the untitled words (the big
    /// line with no title, as the image says it; empty with a title), then the tempo.
    static func texts(_ content: JogDisplayContent) -> [[UInt8]] {
        typealias Message = DrawnDisplay.Message
        let title = content.title ?? ""
        let untitled = title.isEmpty ? JogDisplayWords.untitled(content.playerType).title : ""
        let messages = [Message.text(.title, title), .text(.artist, content.artist ?? ""), .text(.key, content.key ?? ""),
                        .text(.untitled, untitled), .tempo(content.bpm)]
        return messages.map(\.bytes)
    }

    private func next() {
        switch mode {
        case .asking: return
        case .drawn: return connected ? nextDrawn() : ()
        case .images: break
        }
        if renderBeat != nil { return nextBeat() }
        guard upload == nil, let content = wanted, content != current else { return }
        wanted = nil
        current = content
        let slot: UInt8 = shownSlot == 1 ? 2 : 1
        let image: [UInt8]
        if let drawn, drawn.content == content {
            image = drawn.image
        } else {
            image = JogImage.forUnit(rgba: render(content), width: size, height: size)
            drawn = (content, image)
        }
        let job = JogDisplay.Upload(image: image, slot: slot)
        // A preview (#221): no unit, so nothing is sent and nothing waits for an answer; it's shown at once.
        guard connected, let port else {
            shownSlot = slot
            onEvent?(.uploadStarted(slot: slot, content: content, bytes: job.body.reduce(0) { $0 + $1.count }))
            onEvent?(.shown(slot: slot))
            return
        }
        send(job, slot: slot, content: content, port: port)
    }

    /// The deck asked for becomes the front deck; whether it changed.
    @discardableResult
    private func adoptWanted() -> Bool {
        guard let content = wanted else { return false }
        wanted = nil
        guard content != current else { return false }
        current = content
        if contents[content.deck] != content {
            contents[content.deck] = content
            forgetFailures(deck: content.deck)
        }
        return true
    }

    /// Beat mode (#215, #424): the front deck's slot goes on screen at once if the unit holds it; then one slot goes up
    /// at a time, the front deck's first, from the master's beat.
    private func nextBeat() {
        guard upload == nil, let renderBeat else { return }
        let changed = adoptWanted()
        guard connected, let port else {
            // A preview (#221): no unit, so nothing is sent or waited on; the front deck's beats are shown at once.
            guard changed, let content = current else { return }
            let first = lastMasterBeat ?? 1
            for offset in 0..<4 {
                let beat = (first - 1 + offset) % 4 + 1
                guard let slot = slot(deck: content.deck, beat: beat) else { continue }
                let job = JogDisplay.Upload(image: JogImage.forUnit(rgba: renderBeat(content, beat), width: size, height: size), slot: slot)
                onEvent?(.uploadStarted(slot: slot, content: content, bytes: job.body.reduce(0) { $0 + $1.count }))
                onEvent?(.shown(slot: slot))
            }
            return
        }
        if changed { showFrontBeat() }
        guard let next = nextJob() else { return }
        // It leads with the slot on screen, so the screen holds while this one goes up (no blank, no loading graphic).
        let job = JogDisplay.Upload(image: JogImage.forUnit(rgba: renderBeat(next.content, next.beat), width: size, height: size),
                                    slot: next.slot, showing: screenSlot ?? next.slot)
        send(job, slot: next.slot, content: next.content, port: port)
    }

    private func send(_ job: JogDisplay.Upload, slot: UInt8, content: JogDisplayContent, port: any JogDisplayPort) {
        upload = (job, slot, 0, false, clock.now, content)
        for message in job.start + job.body { sendWD(message) }
        onEvent?(.uploadStarted(slot: slot, content: content, bytes: job.body.reduce(0) { $0 + $1.count }))
        // The upload's start turns the play light off (90 01 00): the next tick puts it back.
        lastPlayLight = false
    }
}
