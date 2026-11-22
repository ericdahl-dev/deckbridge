// The display feed (#490, #616): the deck in front, as plain OSC, for a display other than the jog display, such as
// the panel. One value per address under one prefix; only changes go out, and a full snapshot when the deck in front
// changes and each time the destination opens (turned on, a new address, a wake). It only sends (ADR 0011).

final class DisplayFeed {
    /// Every address starts with this.
    static let prefix = "/DeckBridge/Display/"

    /// What the feed shows of the deck in front.
    struct Deck: Equatable {
        /// Syndicate's deck number, 1-4.
        var number: Int
        /// The deck color in use, [r, g, b] 0-255: the ring's and the app badge's.
        var color: [Int]
        /// A track is loaded. False is the empty state: every other field empty.
        var loaded = false
        /// "" while the deck is empty.
        var title = ""
        var artist = ""
        /// In Settings' key notation, as the jog display writes it.
        var key = ""
        /// The live BPM, else the track's; 0 unknown.
        var bpm = 0.0
        /// The change from the track's BPM, in percent; 0 when the track's is unknown.
        var tempo = 0.0
        var playing = false
        /// The deck's CUE button is held.
        var cue = false
        var sync = false
        /// Syndicate's tempo master: synced, with its tempo slider enabled, as the Master LED shows it.
        var master = false
        var loop = false
        /// The loop's length in beats, fractions too; 0 with no loop.
        var loopLength = 0.0
        /// Syndicate's master clock beat, 1-4, the same on every deck; 0 for none.
        var beat = 0
        /// Syndicate's master clock BPM, the clock `beat` follows (#674); 0 whenever `beat` is 0.
        var clockBpm = 0.0
        /// The track time in whole seconds, as the drawn display counts it; remaining is 0 with no known length.
        var elapsed = 0
        var remaining = 0
        /// Through the track, 0-1.
        var progress = 0.0
        /// Against the master, 0-1, 0.5 in phase; -1 unknown (stopped, or no offset yet).
        var phase = -1.0
        /// The deck's mixer meter, 0-1, as the drawn meter shows it.
        var level = 0.0

        /// The full snapshot, in the feed's order. #617 adds its fields here.
        var messages: [OSCMessage] {
            let rgb = color.count == 3 ? color.map { Int32(max(0, min(255, $0))) } : [255, 255, 255]
            return [
                OSCMessage(DisplayFeed.prefix + "deck", [.int(Int32(number))]),
                OSCMessage(DisplayFeed.prefix + "color", [.int(rgb[0] << 16 | rgb[1] << 8 | rgb[2])]),
                OSCMessage(DisplayFeed.prefix + "loaded", [.int(loaded ? 1 : 0)]),
                OSCMessage(DisplayFeed.prefix + "title", [.string(DisplayFeed.capped(title))]),
                OSCMessage(DisplayFeed.prefix + "artist", [.string(DisplayFeed.capped(artist))]),
                OSCMessage(DisplayFeed.prefix + "key", [.string(DisplayFeed.capped(key))]),
                // To 2 decimals, so a BPM wobbling in Syndicate's last digits isn't a change.
                OSCMessage(DisplayFeed.prefix + "bpm", [.float(Float((bpm * 100).rounded() / 100))]),
                OSCMessage(DisplayFeed.prefix + "tempo", [.float(Float((tempo * 100).rounded() / 100))]),
                OSCMessage(DisplayFeed.prefix + "playing", [.int(playing ? 1 : 0)]),
                OSCMessage(DisplayFeed.prefix + "cue", [.int(cue ? 1 : 0)]),
                OSCMessage(DisplayFeed.prefix + "sync", [.int(sync ? 1 : 0)]),
                OSCMessage(DisplayFeed.prefix + "master", [.int(master ? 1 : 0)]),
                OSCMessage(DisplayFeed.prefix + "loop", [.int(loop ? 1 : 0)]),
                OSCMessage(DisplayFeed.prefix + "loopLength", [.float(Float(loopLength))]),
                OSCMessage(DisplayFeed.prefix + "beat", [.int(Int32(beat))]),
                OSCMessage(DisplayFeed.prefix + "clockBpm", [.float(Float((clockBpm * 100).rounded() / 100))]),
                OSCMessage(DisplayFeed.prefix + "elapsed", [.int(Int32(elapsed))]),
                OSCMessage(DisplayFeed.prefix + "remaining", [.int(Int32(remaining))]),
                OSCMessage(DisplayFeed.prefix + "progress", [.float(Float(progress))]),
                OSCMessage(DisplayFeed.prefix + "phase", [.float(Float(phase))]),
                OSCMessage(DisplayFeed.prefix + "level", [.float(Float(level))]),
            ]
        }
    }

    private var sender: (any OSCSender)?
    private var settings = DisplayFeedSettings()
    /// The destination is open at the setting's address: turning the feed on or a new address waits for it, since
    /// until then a send would be dropped or reach the old address. The one snapshot goes when it opens (#617).
    private var open = false
    /// Once the destination opens, the first snapshot waits until Syndicate's answer makes the deck known, at most
    /// until this time, so a panel never flashes a default color or an empty deck at launch (#617).
    private var holdUntil: Double?
    static let holdSeconds = 1.0
    /// A full snapshot goes out this long after the last (#617): it heals a send the queue dropped, and a destination
    /// that opened before the setting came. It doesn't wait for the destination or for Syndicate.
    static let keepaliveSeconds = 2.0
    private var lastSnapshot = 0.0
    /// The fast fields, every one that can follow Syndicate's feedback rate, go out at most once per `fastInterval`
    /// each (#617): a change inside it waits, and the next
    /// update after it sends the value then, so the latest wins and nothing queues. A snapshot sends them at once.
    static let fastAddresses: Set<String> = [
        prefix + "bpm", prefix + "tempo", prefix + "progress", prefix + "phase", prefix + "level", prefix + "clockBpm",
    ]
    /// clockBpm coming from 0, the clock starting, goes at once (#674): with the clock's first beat, so a display
    /// times its first beat right, not a slot later.
    static func waitsForSlot(_ message: OSCMessage, after sent: [OSCArgument]?) -> Bool {
        guard fastAddresses.contains(message.address) else { return false }
        return !(message.address == prefix + "clockBpm" && (sent == nil || sent == [.float(0)]))
    }
    static let fastInterval = 1.0 / 30
    /// When the fast fields may next go out: one slot every `fastInterval` that they all share (#636), so a playing
    /// deck sends one bundle of them per slot, about 30 a second, not one per field drifting onto every tick. Kept on
    /// its cadence so updates that land between slots still average about 30 a second, never bursting to catch up.
    private var fastDue: Double?
    /// What each address carried last, as sent; empty means the next update is a full snapshot.
    private var sent: [String: [OSCArgument]] = [:]
    /// The deck number the last update was for: another deck in front is a full snapshot.
    private var sentDeck: Int?
    /// The Debug trace (#636): the setting, the destination opening, the hold and each full snapshot, one line each.
    var trace: TraceSink?
    /// Why the next full snapshot goes, for its trace line.
    private var snapshotReason = "destination open"
    /// The hold's line went out for this hold.
    private var holdSaid = false

    /// The USB cable's feed (#667): its trace lines start "cable: ", and it has a port, not a host and port.
    let overTheCable: Bool

    init(overTheCable: Bool = false) {
        self.overTheCable = overTheCable
    }

    private func say(_ text: String) { trace?(.displayFeed, overTheCable ? "cable: " + text : text) }

    /// Where the feed's OSC goes. The app's sender is the display's own UDP destination, off the event path.
    func attach(_ sender: any OSCSender) {
        self.sender = sender
        sent = [:]
    }

    /// Title, artist and key are at most this many UTF-8 bytes (#636), so even a snapshot of all three fits one
    /// bundle under `bundleCeiling`. A panel shows far fewer characters anyway.
    static let textCap = 255

    /// `text` cut to `textCap` UTF-8 bytes at a character boundary, never inside one.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > textCap else { return text }
        var out = "", bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= textCap else { break }
            out.append(character)
            bytes += size
        }
        return out
    }

    /// A bundle at most this many bytes (#636), well under Wi-Fi's MTU, so one never goes out in IP fragments.
    static let bundleCeiling = 1200

    /// The messages as bundles of at most `bundleCeiling` bytes each, in order. With text capped at `textCap`, no one
    /// message comes near the ceiling, so it holds for every bundle.
    static func bundles(_ messages: [OSCMessage]) -> [[OSCMessage]] {
        let header = 16, sizeField = 4
        var out: [[OSCMessage]] = [], current: [OSCMessage] = [], size = header
        for message in messages {
            let added = sizeField + message.encoded().count
            if !current.isEmpty, size + added > bundleCeiling {
                out.append(current)
                current = []
                size = header
            }
            current.append(message)
            size += added
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The feed's sequence number (#750): first in every bundle, so a display can count the datagrams it never got. A
    /// display that doesn't know the address ignores it (ADR 0011). An OSC int carries the UInt32's bit pattern.
    static func seq(_ number: UInt32) -> OSCMessage { OSCMessage(prefix + "seq", [.int(Int32(bitPattern: number))]) }
    /// The last bundle's number: 0 before the first.
    private var seq: UInt32 = 0

    /// Sends one bundle, numbered.
    private func send(_ bundle: [OSCMessage], to sender: any OSCSender) {
        seq &+= 1
        sender.send(bundle: [Self.seq(seq)] + bundle)
    }

    /// The goodbye (#651): DeckBridge is quitting or the feed was turned off; a display shows its own idle look.
    static let goodbye = OSCMessage(prefix + "goodbye", [.int(1)])
    /// A datagram has gone out since the destination opened: there's a display to say goodbye to.
    private var greeted = false

    /// Says goodbye, as the last datagram, if anything went out since the destination opened; nothing follows it until
    /// the destination opens again or the feed is turned on.
    func goodbye() {
        guard greeted, let sender else { return }
        send([Self.goodbye], to: sender)
        say("goodbye")
        greeted = false
        open = false
        sent = [:]
        lastSnapshot = .greatestFiniteMagnitude
    }

    /// Waits for the sends to leave (the app exits after a quit).
    func flush() {
        (sender as? any OSCFlushing)?.flush(timeout: 0.5)
    }

    /// Seconds as a trace line writes them: 1, not 1.0.
    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }

    /// Gives up the sender and the setting, for another Coordinator to take (the demo, #625); this one sends nothing
    /// until it gets them back.
    func release() -> (sender: any OSCSender, settings: DisplayFeedSettings, greeted: Bool)? {
        guard let sender else { return nil }
        self.sender = nil
        sent = [:]
        defer { greeted = false }
        return (sender, settings, greeted)
    }

    /// The display heard from whoever had the feed before (#651): it gets the goodbye even if this one sent nothing yet.
    func carryGreeting(_ greeted: Bool) {
        self.greeted = self.greeted || greeted
    }

    /// The setting. Turning it on, or a new host or port, waits for the destination to open.
    func set(_ new: DisplayFeedSettings, at now: Double = 0) {
        if new.enabled && (!settings.enabled || new.host != settings.host || new.port != settings.port) {
            sent = [:]
            open = false
            lastSnapshot = now
            say(overTheCable ? "on, waiting for its port" : "on: \(new.host):\(new.port), waiting for its destination")
        } else if !new.enabled && settings.enabled {
            say("off")
            goodbye()
        }
        settings = new
    }

    /// The setting is on (Syndicate's subscriptions for it are asked for).
    var enabled: Bool { settings.enabled }

    /// Turned on with somewhere to send: worth building the deck for.
    var on: Bool { settings.enabled && sender != nil }

    /// The destination opened (or opened again, after a wake) at `now`: the next update is a full snapshot.
    func resend(at now: Double) {
        sent = [:]
        open = true
        // A display starts counting again here (#750): this bundle is 1, never a gap after the last destination's.
        seq = 0
        holdUntil = now + Self.holdSeconds
        holdSaid = false
        snapshotReason = "destination open"
        say("destination open")
    }

    /// Sends what changed about the deck in front: everything when it's another deck. `known`: Syndicate has
    /// answered for it (its color and its deck), which ends the hold on the first snapshot.
    func update(_ deck: Deck?, known: Bool = true, at now: Double = 0) {
        guard settings.enabled, let sender, let deck else { return }
        if now - lastSnapshot >= Self.keepaliveSeconds - 1e-9 {
            sent = [:]
            open = true
            holdUntil = nil
            snapshotReason = "keepalive"
        }
        guard open else { return }
        if let until = holdUntil {
            guard known || now >= until else {
                if !holdSaid {
                    holdSaid = true
                    say("holding the first snapshot until Syndicate answers for deck \(deck.number), at most \(Self.format(Self.holdSeconds)) s")
                }
                return
            }
            holdUntil = nil
            if !known { snapshotReason = "no answer from Syndicate in \(Self.format(Self.holdSeconds)) s" }
        }
        if let sentDeck, deck.number != sentDeck { snapshotReason = "deck \(deck.number) in front" }
        if deck.number != sentDeck { sent = [:] }
        sentDeck = deck.number
        let snapshot = sent.isEmpty
        if snapshot { lastSnapshot = now }
        var changes: [OSCMessage] = []
        // A hair of slack, so an update on the slot isn't lost to rounding.
        let fastOpen = snapshot || fastDue.map { now >= $0 - 1e-9 } ?? true
        var fastSent = false
        for message in deck.messages where sent[message.address] != message.arguments {
            if Self.waitsForSlot(message, after: sent[message.address]) {
                guard fastOpen else { continue }
                fastSent = true
            }
            changes.append(message)
            sent[message.address] = message.arguments
        }
        // One datagram for the update (#636): a panel drains a few a frame, and one per address was about 111 a second
        // with a deck playing, each snapshot a burst of 20.
        if fastSent { fastDue = (fastDue.map { max($0, now - Self.fastInterval) } ?? now) + Self.fastInterval }
        let bundles = Self.bundles(changes)
        for bundle in bundles { send(bundle, to: sender) }
        if !bundles.isEmpty { greeted = true }
        let count = changes.count
        if snapshot {
            say("snapshot (\(snapshotReason)): deck \(deck.number), loaded \(deck.loaded ? 1 : 0), \"\(deck.title)\", clockBpm \(Self.format((deck.clockBpm * 100).rounded() / 100)), \(count) messages in \(bundles.count) bundle\(bundles.count == 1 ? "" : "s")")
        }
    }
}
