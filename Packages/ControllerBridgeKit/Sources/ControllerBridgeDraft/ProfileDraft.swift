import ControllerBridgeCapture
import ControllerBridgeCore
import Foundation

/// A draft controller profile from a capture (#189): what the capture shows, set; what it doesn't, listed as a TODO
/// for a person to fill in. Nothing is guessed.
public struct ProfileDraft: Sendable {
    /// The profile file: id, name, device_hints, exclude_hints and the mapping body.
    public var profile: DraftJSON
    /// Keys the draft leaves out, each with how to find its value.
    public var todos: [Todo]
    /// Keys the docs filled, with their source.
    public var fromDocs: [FromDocs] = []
    /// Where the capture and the docs disagree. The capture's value is kept.
    public var conflicts: [Conflict] = []
    /// Keys a profile file must have that neither the capture nor the docs gave, filled from the LC6000's mapping so
    /// the draft loads (#310). Each is for a person to check; the controller-specific ones keep their TODO.
    public var placeholders: [FromDocs] = []
    /// False for a draft from the docs alone (#280), before any capture.
    public var fromCapture = true

    public struct FromDocs: Equatable, Sendable {
        public var key: String
        public var value: DraftJSON
        public var source: String?
    }

    public struct Conflict: Equatable, Sendable {
        public var key: String
        public var capture: DraftJSON
        public var docs: DraftJSON
        public var source: String?
    }

    public struct Todo: Equatable, Sendable {
        /// The key path in the profile ("mapping.notes.play").
        public var key: String
        public var how: String
    }

    public static func make(capture: CaptureFile, docs: DocsFacts = DocsFacts()) -> ProfileDraft {
        var draft = ProfileDraft(profile: .object([]), todos: [])
        draft.identity(capture)
        draft.buttons(capture)
        draft.noise(capture)
        draft.pads(capture)
        draft.layers(capture)
        draft.jog(capture)
        draft.pitch(capture)
        draft.needle(capture)
        draft.browse(capture)
        draft.shifted(capture)
        draft.merge(docs)
        draft.unknowns()
        draft.fill()
        return draft
    }

    /// A draft from the docs alone (#280), before any owner has captured the controller: the identity from the device
    /// name, the docs' keys with their sources, and a TODO for the owner's capture for everything else.
    public static func make(device: String, docs: DocsFacts) -> ProfileDraft {
        var draft = ProfileDraft(profile: .object([]), todos: [])
        draft.fromCapture = false
        draft.set("id", .string(slug(device)))
        draft.set("name", .string(device))
        draft.set("device_hints", .array([.string(device)]))
        draft.set("exclude_hints", .array([]))
        draft.set("mapping.midi.input", .string(device))
        draft.set("mapping.midi.output", .string(device))
        // Noise notes come only from a capture's hands-off step.
        draft.set("mapping.midi.ignore_notes", .array([]))
        draft.todo("mapping.midi.ignore_notes", "Notes the controller sends by itself (a heartbeat) come from the owner's capture: its hands-off step.")
        draft.merge(docs)
        let capturable: [(key: String, what: String)] = [
            ("mapping.midi.channel", "the deck's channel"), ("mapping.notes.pads", "the hot cue pads' notes"),
            ("mapping.midi.layers", "the deck layers' channels"), ("mapping.jog", "the jog's messages"),
            ("mapping.notes.platter_touch", "the platter's touch note"), ("mapping.pitch", "the pitch fader's CCs and direction"),
            ("mapping.needle", "the needle strip"), ("mapping.browse.select_turn_cc", "the browse knob's CC"),
            ("mapping.midi.encoder_format", "the relative encoder format"),
        ]
        for (key, what) in capturable where draft.profile.value(at: key) == nil {
            draft.todo(key, "Not in the docs. The owner's capture, or MIDI Monitor, gives \(what). Leave it out if the controller has no such control.")
        }
        if draft.profile.value(at: "mapping.jog.counts_per_rev") == nil {
            draft.todo("mapping.jog.counts_per_rev", "Not in the docs. In the owner's capture or MIDI Monitor: mark the platter, turn it exactly once, and count.")
        }
        draft.unknowns()
        draft.fill()
        return draft
    }

    mutating func set(_ path: String, _ value: DraftJSON) { profile.set(path, value) }

    /// What the profile check says about the draft's mapping as a new controller's own profile (#251): its keys
    /// against each other, never against the LC6000's. Empty means it passes as written.
    public var problems: [String] {
        guard let mapping = file["mapping"] else { return [] }
        let json = Data(mapping.text().utf8)
        // The decoder's own shape rules (a jog needs a pair or relative_cc, a cycling pad mode needs its button)
        // aren't in the check, so decode too and add what it throws (#310).
        var shape: [String] = []
        do { _ = try JSONDecoder().decode(Mapping.self, from: json) } catch let error as Mapping.JogError {
            shape.append(error.description)
        } catch let error as Mapping.ShapeError {
            shape.append(error.description)
        } catch {}
        return Mapping.problems(in: json, whole: true) + shape
    }

    mutating func todo(_ key: String, _ how: String) {
        if !todos.contains(where: { $0.key == key }) { todos.append(Todo(key: key, how: how)) }
    }

    /// The device names the profile; any input port that carried no control is another port of the same unit, such as
    /// the LC6000's display port, and is excluded so the profile never runs on it.
    private mutating func identity(_ capture: CaptureFile) {
        set("id", .string(Self.slug(capture.device)))
        set("name", .string(capture.device))
        set("device_hints", .array([.string(capture.device)]))
        let used = Set(capture.steps.flatMap { $0.messages.map(\.port) })
        let others = capture.ports.input.indices.filter { !used.contains($0) }.map { DraftJSON.string(capture.ports.input[$0]) }
        set("exclude_hints", .array(others))
        set("mapping.midi.input", .string(capture.device))
        set("mapping.midi.output", .string(capture.device))
    }

    /// The control a step found, or a TODO for `key` saying why there's none.
    mutating func control(_ capture: CaptureFile, _ prompt: String, for key: String) -> ControlFacts? {
        controls(capture, prompt, for: key)?.first
    }

    /// Every control a step found, in the order they came, or nil and a TODO for `key` saying why there's none.
    mutating func controls(_ capture: CaptureFile, _ prompt: String, for key: String) -> [ControlFacts]? {
        guard let step = capture.steps.first(where: { $0.prompt == prompt }) else {
            todo(key, "The capture has no \"\(prompt)\" step. Run the capture again with the current prompt list.")
            return nil
        }
        guard step.status == .confirmed else {
            todo(key, "The owner skipped \"\(prompt)\". Ask them to run that step again, or read it from the docs.")
            return nil
        }
        guard !step.controls.isEmpty else {
            todo(key, "\"\(prompt)\" was confirmed but found no control (only noise came in). Run that step again.")
            return nil
        }
        return step.controls
    }

    /// The buttons a profile names, by the capture prompt that finds each.
    static let buttons: [(prompt: String, name: String)] = [
        ("deck1.play", "play"), ("deck1.cue", "cue"), ("deck1.sync", "sync"), ("deck1.loop_in", "loop_in"),
        ("deck1.loop_out", "loop_out"), ("deck1.auto_loop", "auto_loop"), ("deck1.browse.press", "select_press"),
        ("deck1.shift", "shift"),
    ]

    /// Each button step's note. The deck's channel is Play's; a button on another channel can't be expressed yet.
    private mutating func buttons(_ capture: CaptureFile) {
        var channel: Int?
        for (prompt, name) in Self.buttons {
            let key = "mapping.notes.\(name)"
            guard let control = control(capture, prompt, for: key) else { continue }
            guard control.kind == .note, let note = control.number else {
                let sends = control.kind == .cc ? "CC \(control.number ?? 0)" : "pitch bend"
                todo(key, "\"\(prompt)\" sends \(sends), not a note; profiles take buttons as notes. Needs a new profile key.")
                continue
            }
            if channel == nil {
                channel = control.channel
                set("mapping.midi.channel", .int(control.channel))
            } else if control.channel != channel {
                todo(key, "\"\(prompt)\" is on channel \(control.channel), not the deck's \(channel!). Profiles put buttons on one channel.")
            }
            set(key, .int(note))
        }
    }

    /// Hot cue pads 1–8, in order. Pads on a channel other than the deck's set pads.channel (#224). The capture only
    /// records Hot Cue mode, so per-mode notes (#225) and how the mode is chosen (#198) are always TODOs.
    private mutating func pads(_ capture: CaptureFile) {
        let key = "mapping.notes.pads"
        // As many pads as the capture's prompt list asks hot cues for (1–16, #196, #310).
        let count = max(1, min(16, capture.prompts.filter { $0.id.hasPrefix("deck1.hotcue") && $0.shiftedOf == nil }.count))
        let controls = (1...count).map { control(capture, "deck1.hotcue\($0)", for: "\(key)[\($0 - 1)]") }
        todos.removeAll { $0.key.hasPrefix("\(key)[") }
        let missing = (1...count).filter { controls[$0 - 1]?.kind != .note }
        if missing.isEmpty, case let pads = controls.compactMap({ $0 }) {
            set(key, .array(pads.map { .int($0.number ?? 0) }))
            let channels = Set(pads.map(\.channel))
            let deck = profile.value(at: "mapping.midi.channel")
            if channels.count > 1 {
                todo("mapping.pads.channel", "The pads came on channels \(channels.sorted()); profiles put all pads on one.")
            } else if let channel = channels.first, deck != .int(channel) {
                set("mapping.pads.channel", .int(channel))
            }
        } else {
            todo(key, "No note for \(missing.map { "deck1.hotcue\($0)" }.joined(separator: ", ")). Run those steps again; notes.pads needs all \(count).")
        }
        todo("mapping.pads.mode_notes", "Only if the pads send other notes in Roll, Loop and Slicer modes (#225): press each pad in each mode and list them. The capture only records Hot Cue mode.")
        todo("mapping.pads.mode_select", "Four mode buttons (\"buttons\") or one that cycles (\"cycle\", #198)? From the manual, or by pressing the mode buttons in MIDI Monitor.")
    }

    /// The docs fill what the capture didn't set; where both say something, the capture wins and it's listed.
    private mutating func merge(_ docs: DocsFacts) {
        for (key, value) in docs.facts {
            let source = docs.sources[key]
            if let captured = profile.value(at: key) {
                if captured != value { conflicts.append(Conflict(key: key, capture: captured, docs: value, source: source)) }
            } else {
                set(key, value)
                fromDocs.append(FromDocs(key: key, value: value, source: source))
                todos.removeAll { $0.key == key || $0.key.hasPrefix(key + ".") || key.hasPrefix($0.key + ".") }
            }
        }
    }

    /// The profile file to write and load: what the capture and the docs gave (`profile`), then the placeholders.
    public var file: DraftJSON {
        var file = profile
        for placeholder in placeholders { file.set(placeholder.key, placeholder.value) }
        return file
    }

    /// Every key a whole profile needs that the draft lacks, from the LC6000's mapping, so the file loads (#310).
    /// Buttons are never filled (a profile has only its own), nor an absolute jog pair beside a relative jog.
    private mutating func fill() {
        guard let data = try? Mapping.defaultMappingJSON(),
              let text = String(data: data, encoding: .utf8),
              let defaults = try? DocsFacts(json: Data(#"{"mapping": \#(text)}"#.utf8)) else { return }
        let relativeJog = profile.value(at: "mapping.jog.relative_cc") != nil
        let sevenBitPitch = profile.value(at: "mapping.pitch.bits") == .int(7)
        // A control the draft has nothing for is left out, not filled (#341): the section is optional, as for a
        // controller without one, and its TODO says so.
        let absent = ["needle", "jog", "pitch", "browse"].filter { profile.value(at: "mapping.\($0)") == nil }
        for (key, value) in defaults.facts where profile.value(at: key) == nil {
            if key.hasPrefix("mapping.notes."), key != "mapping.notes.pads" { continue }
            // Optional and controller-specific: the LC6000's layer note would read as a layer switch elsewhere (#280).
            if key == "mapping.midi.layer_note" { continue }
            // Denon's color message (#530): the LC6000's would send Denon's SysEx to another controller's LEDs.
            if key.hasPrefix("mapping.leds.color_message") { continue }
            if absent.contains(where: { key.hasPrefix("mapping.\($0).") }) { continue }
            if relativeJog, ["mapping.jog.msb_cc", "mapping.jog.lsb_cc"].contains(key) { continue }
            if sevenBitPitch, key == "mapping.pitch.lsb_cc" { continue }
            placeholders.append(FromDocs(key: key, value: value, source: "the LC6000's value, a placeholder"))
        }
    }

    /// What neither the capture nor the docs set and a controller must say for itself: its other buttons and its
    /// LEDs. Everything else a profile file needs (OSC, timings, tolerances) is a listed placeholder (`fill`, #310).
    private mutating func unknowns() {
        guard let data = try? Mapping.defaultMappingJSON(),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for section in ["notes", "leds"] {
            for key in ((schema[section] as? [String: Any]) ?? [:]).keys.sorted() where key != "pads" && key != "shifted" && key != "color_message" {
                let path = "mapping.\(section).\(key)"
                guard profile.value(at: path) == nil, !todos.contains(where: { $0.key == path }) else { continue }
                todo(path, section == "notes"
                     ? "Not in the capture or the docs. Press it in MIDI Monitor, or find it in the MIDI chart; leave it out if the controller has no such button."
                     : "Not in the capture or the docs. LEDs need the controller's MIDI chart or a probe with the owner (the capture's LED answers are free text).")
            }
        }
        // Controller-specific keys the capture can't show (#310): placeholders so the file loads, never quiet values.
        if profile.value(at: "mapping.pads.roll_sizes") == nil {
            todo("mapping.pads.roll_sizes", "Which slip-loop size each pad plays in Roll mode, shortest first, from the manual or the pads' printed labels.")
        }
        if profile.value(at: "mapping.jog.require_touch") == nil {
            todo("mapping.jog.require_touch", "Whether the jog should act only while its top is touched: true if the platter has a touch sensor and should ignore a spin of its edge.")
        }
        if profile.value(at: "mapping.needle.require_touch") == nil {
            todo("mapping.needle.require_touch", "Whether the needle strip should act only while touched: true if it sends a touch note (needle.touch_note).")
        }
        if profile.value(at: "mapping.mixer") == nil {
            todo("mapping.mixer", "Mixer controls (mapping.mixer, #207) aren't captured yet. Note the faders, EQ, filter, cue/mute/solo and VU meter from the MIDI chart.")
        }
    }

    /// Steps repeated with Shift held. The shifted control is the step's first (the held Shift note is already left out).
    /// The same note and channel as unshifted means the app does Shift. A button's own note on the deck's channel is
    /// Shift in hardware: notes.shifted (#226). Anything else (another channel, a pad) is a TODO naming what it sent.
    private mutating func shifted(_ capture: CaptureFile) {
        for step in capture.steps where step.status == .confirmed {
            guard let base = capture.prompts.first(where: { $0.id == step.prompt })?.shiftedOf,
                  let shifted = step.controls.first,
                  let unshifted = capture.steps.first(where: { $0.prompt == base && $0.status == .confirmed })?.controls.first
            else { continue }
            guard shifted.kind != unshifted.kind || shifted.number != unshifted.number || shifted.channel != unshifted.channel
            else { continue }
            let button = Self.buttons.first { $0.prompt == base }?.name
            let name = button ?? (base.hasPrefix("deck1.hotcue") ? "pads" : base)
            if let button, shifted.kind == .note, let note = shifted.number, profile.value(at: "mapping.midi.channel") == .int(shifted.channel) {
                set("mapping.notes.shifted.\(button)", .int(note))
                todo("mapping.leds.mirror_shifted", "Shift is done in hardware. Hold Shift and look: if the shifted button lights on its own note, set true.")
                continue
            }
            let sends = "\(shifted.kind == .note ? "note" : "CC") \(shifted.number ?? 0) on channel \(shifted.channel)"
            todo("mapping.notes.shifted.\(name)", "With Shift held, \"\(base)\" sends \(sends). notes.shifted takes a button's note on the deck's channel, so this needs a new profile key.")
        }
    }

    /// Deck layers: deck 2's Play on its own channel means the left side switches channels. The note the controller
    /// sends on deck 2's channel as it switches is the layer note. Only decks 1 and 2 are captured.
    private mutating func layers(_ capture: CaptureFile) {
        let key = "mapping.midi.layers"
        guard case .int(let deck1)? = profile.value(at: "mapping.midi.channel"),
              let play2 = control(capture, "deck2.play", for: key) else { return }
        guard play2.channel != deck1 else {
            todo(key, "Deck 2's Play came on deck 1's channel (\(deck1)), so the side doesn't switch channels. If it switches decks some other way, that needs a new profile key.")
            return
        }
        let layer = { (channel: Int, deck: Int) in DraftJSON.object([.init(key: "channel", value: .int(channel)), .init(key: "deck", value: .int(deck))]) }
        set(key, .array([layer(deck1, 1), layer(play2.channel, 2)]))
        todo(key, "Only decks 1 and 2 were captured. For a 4-deck controller, add decks 3 and 4: switch to each and press Play in MIDI Monitor.")
        let announce = capture.steps.first { $0.prompt == "layer2.select" && $0.status == .confirmed }?
            .controls.first { $0.kind == .note && $0.channel == play2.channel }
        if let note = announce?.number {
            set("mapping.midi.layer_note", .int(note))
        } else {
            todo("mapping.midi.layer_note", "No note came on deck 2's channel as the side switched. Leave it out if the controller doesn't announce its layer.")
        }
    }

    /// The jog: an absolute 14-bit pair (the LC6000) or a relative CC (#204), the edge's own CC when it has one, and the
    /// note held while the top is touched. Counts per turn need a measured full turn, so they're always a TODO.
    private mutating func jog(_ capture: CaptureFile) {
        let key = "mapping.jog"
        todo("\(key).counts_per_rev", "Mark the platter, turn it exactly one full turn in MIDI Monitor, and count: position counts for an absolute pair, ticks for a relative jog.")
        guard let top = controls(capture, "deck1.jog.touch", for: key) else { return }
        if let touch = top.first(where: { $0.kind == .note })?.number {
            set("mapping.notes.platter_touch", .int(touch))
        } else {
            todo("mapping.notes.platter_touch", "No note came while the top was touched. If the platter has no touch sensor, jog.require_touch must be false.")
        }
        guard let wheel = top.first(where: { $0.kind == .cc }), let number = wheel.number else {
            todo(key, "The jog didn't send a CC. Check it in MIDI Monitor.")
            return
        }
        let edge = capture.steps.first { $0.prompt == "deck1.jog.edge" && $0.status == .confirmed }?.controls.first { $0.kind == .cc }
        if let lsb = wheel.lsb {
            set("\(key).msb_cc", .int(number))
            set("\(key).lsb_cc", .int(lsb))
            if let edge, edge.number != number {
                todo("\(key).relative_edge_cc", "The edge sent CC \(edge.number ?? 0), apart from the top's pair. Profiles have an edge CC only for a relative jog.")
            }
        } else if wheel.encoding == .absolute {
            todo(key, "The jog sent one absolute 7-bit CC (\(number)); profiles take a 14-bit pair or a relative CC.")
        } else {
            set("\(key).relative_cc", .int(number))
            if let edge, let edgeNumber = edge.number, edgeNumber != number { set("\(key).relative_edge_cc", .int(edgeNumber)) }
            encoderFormat(wheel.encoding, from: "deck1.jog.touch")
        }
    }

    /// The pitch fader, moved top to bottom: a 14-bit pair or one 7-bit CC (#195), inverted when the top gave the
    /// high value (the LC6000's top is 0).
    private mutating func pitch(_ capture: CaptureFile) {
        let key = "mapping.pitch"
        guard let control = control(capture, "deck1.pitch", for: key) else { return }
        guard control.kind == .cc, let msb = control.number else {
            todo(key, "The pitch fader sends pitch bend; profiles take a CC (pitch bend was dropped from v1.2, #199).")
            return
        }
        set("\(key).bits", .int(control.lsb == nil ? 7 : 14))
        set("\(key).msb_cc", .int(msb))
        if let lsb = control.lsb { set("\(key).lsb_cc", .int(lsb)) }
        set("\(key).invert", .bool(control.first > control.last))
    }

    /// The needle strip: its 14-bit pair and the note held while it's touched.
    private mutating func needle(_ capture: CaptureFile) {
        let key = "mapping.needle"
        guard let controls = controls(capture, "deck1.needle", for: key) else { return }
        guard let strip = controls.first(where: { $0.kind == .cc }), let msb = strip.number, let lsb = strip.lsb else {
            todo(key, "The needle strip didn't send a 14-bit CC pair. Check it in MIDI Monitor; profiles need msb_cc and lsb_cc.")
            return
        }
        set("\(key).msb_cc", .int(msb))
        set("\(key).lsb_cc", .int(lsb))
        if let touch = controls.first(where: { $0.kind == .note })?.number {
            set("\(key).touch_note", .int(touch))
        } else {
            todo("\(key).touch_note", "No note came while the strip was touched. If it has no touch sensor, needle.require_touch must be false.")
        }
    }

    /// The browse knob's CC, and from its turn the relative encoder format (#193) unless the jog already set it.
    private mutating func browse(_ capture: CaptureFile) {
        todo("mapping.browse.auto_loop_size_cc", "The capture has no step for the auto loop size encoder. Turn it in MIDI Monitor, or find it in the MIDI chart.")
        guard let control = control(capture, "deck1.browse.turn", for: "mapping.browse.select_turn_cc") else { return }
        guard control.kind == .cc, let number = control.number else {
            todo("mapping.browse.select_turn_cc", "The browse knob didn't send a CC. Check it in MIDI Monitor.")
            return
        }
        set("mapping.browse.select_turn_cc", .int(number))
        encoderFormat(control.encoding, from: "deck1.browse.turn")
    }

    /// The profile's one relative encoder format. A turn that couldn't tell (one way only) or an absolute knob is a TODO.
    mutating func encoderFormat(_ encoding: ControlEncoding?, from prompt: String) {
        let key = "mapping.midi.encoder_format"
        switch encoding {
        case .twosComplement, .offset64, .signMagnitude:
            todos.removeAll { $0.key == key }
            if profile.value(at: key) == nil { set(key, .string(encoding!.rawValue)) }
        case .absolute:
            todo(key, "\"\(prompt)\" sent absolute values, not relative steps. Check whether it's an endless encoder.")
        case nil:
            if profile.value(at: key) == nil {
                todo(key, "\"\(prompt)\" turned only one way, so its format can't be told. Run it again, right then left.")
            }
        }
    }

    /// Notes that came in with hands off (a heartbeat) are ignored, so they never press anything.
    private mutating func noise(_ capture: CaptureFile) {
        let notes = capture.noise.compactMap { key -> Int? in
            key.count == 2 && key[0] & 0xF0 == 0x90 ? Int(key[1]) : nil
        }
        set("mapping.midi.ignore_notes", .array(notes.map(DraftJSON.int)))
    }

    /// Lowercase letters and digits, runs of anything else as one hyphen.
    static func slug(_ name: String) -> String {
        name.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.joined(separator: "-")
    }
}
