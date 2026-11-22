// A deck's drawn state as the renderer's drawnImage takes it (#465): the content and the live values, so the
// Diagnostics preview draws what the chip would from what the chip got.
import Foundation

/// What drawnImage draws for one deck.
public struct DrawnPreviewImage: Equatable, Sendable {
    public var content: JogDisplayContent
    public var live: DrawnLive
}

extension DrawnDisplayState {
    /// The image inputs at `now`, nil with no deck yet. `timeAt` is when the deck's time last changed: the chip starts
    /// the warning's blink, red, on the frame the time changes.
    public func preview(now: Double, timeAt: Double?) -> DrawnPreviewImage? {
        guard let deck else { return nil }
        // The host sends an empty text for none.
        func text(_ field: DrawnDisplay.TextField) -> String? {
            let string = Self.string(texts[field] ?? [])
            return string.isEmpty ? nil : string
        }
        var content = JogDisplayContent(deck: deck.number, color: deck.color, title: text(.title),
                                        artist: text(.artist), key: text(.key), bpm: tempo > 0 ? Double(tempo) / 10 : nil,
                                        playerType: Self.playerType(deck.player, words: text(.untitled) ?? ""))
        // The waiting look: the host said feedback stopped, or nothing came for 3 s (#569), as on the chip.
        content.stale = stale
        var look = JogTrackTime.Look.normal
        if let time, let timeAt {
            let since = max(0, now - timeAt)
            look = JogTrackTime.look(elapsed: time.elapsed, length: time.length, playing: flags.contains(.playing),
                                     looping: flags.contains(.loopOn), phase: since - since.rounded(.down))
        }
        let live = DrawnLive(beat: beat == 0 ? nil : beat, needle: needle,
                             meter: meter.map { DrawnLive.Meter(level: $0.level, peak: $0.peak) },
                             phase: phase == DrawnPhase.unknown ? nil : phase,
                             time: time.map { DrawnLive.Time(elapsed: $0.elapsed, length: $0.length) }, look: look)
        return DrawnPreviewImage(content: content, live: live)
    }

    /// The player type the renderer reads its badge and untitled words from: a track's or an empty deck's own, else
    /// the untitled words the host sent (they say the kind, as JogDisplayWords does), else the kind's name.
    static func playerType(_ player: DrawnDisplay.Player, words: String) -> String? {
        switch player {
        case .empty: "empty"
        case .track: "track"
        case .oscClip: words.isEmpty ? "osc" : words
        case .midiClip: words.isEmpty ? "midi" : words
        case .sequencer: words.isEmpty ? "sequencer" : words
        case .other: words.isEmpty ? nil : words
        }
    }

    /// Windows-1252 codes as text; the box (0x81) as U+FFFD.
    static func string(_ codes: [UInt8]) -> String {
        String(codes.map { code -> Character in
            if code == 0x81 { return "\u{FFFD}" }
            return String(data: Data([code]), encoding: .windowsCP1252)?.first ?? "\u{FFFD}"
        })
    }
}

/// The Diagnostics preview's drawn side (#465): each deck's drawn state from the driver's events, and when its time
/// last changed (the warning's blink starts there, as on the chip). Empty while the previews show images.
public struct DrawnPreviews: Equatable, Sendable {
    private var states: [Int: DrawnDisplayState] = [:]
    private var timeAt: [Int: Double] = [:]

    public init() {}

    public mutating func apply(_ event: JogDisplayEvent, at now: Double) {
        switch event {
        case .drawnPreview(let state):
            guard let deck = state.deck?.number else { return }
            if states[deck]?.time.map({ [$0.elapsed, $0.length] }) != state.time.map({ [$0.elapsed, $0.length] }) {
                timeAt[deck] = now
            }
            states[deck] = state
        case .drawnPreviewsEnded:
            states.removeAll()
            timeAt.removeAll()
        default: break
        }
    }

    /// Whether any deck's preview is drawn.
    public var drawing: Bool { !states.isEmpty }

    /// What the deck's preview draws with drawnImage at `now`; nil to draw today's image preview instead.
    public func image(deck: Int, now: Double) -> DrawnPreviewImage? {
        states[deck]?.preview(now: now, timeAt: timeAt[deck])
    }
}
