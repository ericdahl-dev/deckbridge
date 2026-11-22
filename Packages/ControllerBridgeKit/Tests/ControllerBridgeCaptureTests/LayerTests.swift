import ControllerBridgeCapture
import Foundation
import Testing

/// Deck layer variants (#217): the layer button, the indicator the controller sends, and how deck 2's controls differ
/// from deck 1's. Hand-built from the confirmed LC6000 layer behavior (#79, #120). HAND-BUILT, REPLACE WITH #213'S
/// RECORDING.
@Suite("Capture layers")
struct LayerTests {
    static let prompts = [
        CapturePrompt(id: "deck1.play", text: "Press Play on deck 1.", gesture: .press),
        CapturePrompt(id: "layer2.select", text: "Switch to deck 2.", gesture: .press, layer: 2),
        CapturePrompt(id: "deck2.play", text: "Press Play on deck 2.", gesture: .press, layer: 2, layerOf: "deck1.play"),
    ]

    /// Shift + deck select on the LC6000: Shift (note 26) held, deck select (ch16 note 55) pressed and let go, then
    /// note 51 at 0 on the old channel and at 127 on the new one, then Shift let go.
    static let lc6000Select: [[UInt8]] = [
        [0x90, 26, 0x7F], [0x9F, 55, 0x7F], [0x8F, 55, 0x00], [0x90, 51, 0x00], [0x91, 51, 0x7F], [0x80, 26, 0x00],
    ]

    static func file(select: [[UInt8]]?, deck2Play: [[UInt8]]?) -> CaptureFile {
        var session = CaptureSession(appVersion: "1.2.0", device: "Test", ports: CapturePorts(input: [], output: []), prompts: prompts)
        var now = 0.0
        func take(_ messages: [[UInt8]]?) {
            if let messages {
                for bytes in messages { session.receive(bytes, at: now); now += 0.1 }
                session.confirm(at: now + 1)
            } else {
                session.skip(at: now + 1)
            }
            now += 2
        }
        take([[0x90, 1, 0x7F], [0x80, 1, 0x00]])
        take(select)
        take(deck2Play)
        return session.file
    }

    static func note(_ channel: Int, _ number: Int, _ release: NoteRelease?) -> ControlFacts {
        ControlFacts(kind: .note, channel: channel, number: number, release: release, first: 127, last: 127, min: 127, max: 127)
    }

    @Test("LC6000, multi-channel state: Shift + note 55 on ch 16 selects layer 2, note 51 on ch 2 marks it, deck 2 is channel +1")
    func lc6000MultiChannel() {
        let layers = CaptureLayers.infer(
            prompts: Self.prompts, steps: Self.file(select: Self.lc6000Select, deck2Play: [[0x91, 1, 0x7F], [0x81, 1, 0x00]]).steps
        )
        #expect(layers == [LayerFacts(
            layer: 2, select: Self.note(16, 55, .noteOff), withShift: true, indicator: Self.note(2, 51, nil),
            channelOffset: 1, numberOffset: 0
        )])
    }

    @Test("LC6000, normal state: deck 2's Play still comes on ch 1, so the offset is 0 and only the indicator tells layers apart")
    func lc6000Normal() {
        let layers = CaptureLayers.infer(
            prompts: Self.prompts, steps: Self.file(select: Self.lc6000Select, deck2Play: [[0x90, 1, 0x7F], [0x80, 1, 0x00]]).steps
        )
        #expect(layers.first?.channelOffset == 0)
        #expect(layers.first?.numberOffset == 0)
        #expect(layers.first?.indicator == Self.note(2, 51, nil))
    }

    @Test("A plain deck button: no Shift, no indicator; deck 2 moves its notes up 64")
    func plainButton() {
        let layers = CaptureLayers.infer(
            prompts: Self.prompts,
            steps: Self.file(select: [[0x90, 70, 0x7F], [0x80, 70, 0x00]], deck2Play: [[0x90, 65, 0x7F], [0x80, 65, 0x00]]).steps
        )
        #expect(layers == [LayerFacts(
            layer: 2, select: Self.note(1, 70, .noteOff), withShift: false, indicator: nil, channelOffset: 0, numberOffset: 64
        )])
    }

    @Test("Skipped steps leave their part unknown rather than guessed")
    func skipped() {
        let noSelect = CaptureLayers.infer(prompts: Self.prompts, steps: Self.file(select: nil, deck2Play: [[0x91, 1, 0x7F]]).steps)
        #expect(noSelect == [LayerFacts(layer: 2, select: nil, withShift: false, indicator: nil, channelOffset: 1, numberOffset: 0)])
        let noPlay = CaptureLayers.infer(prompts: Self.prompts, steps: Self.file(select: Self.lc6000Select, deck2Play: nil).steps)
        #expect(noPlay.first?.channelOffset == nil)
        #expect(noPlay.first?.numberOffset == nil)
    }

    @Test("The file carries a layers block, pinned by a literal; a capture with no layer steps leaves the key out")
    func fileBlock() throws {
        let file = Self.file(select: Self.lc6000Select, deck2Play: [[0x91, 1, 0x7F], [0x81, 1, 0x00]])
        let object = try #require(try JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        let layers = object["layers"] as? NSArray
        let literal = try JSONSerialization.jsonObject(with: Data("""
            [{ "layer": 2, "with_shift": true, "channel_offset": 1, "number_offset": 0,
               "select": { "kind": "note", "port": 0, "channel": 16, "number": 55, "release": "note_off",
                           "first": 127, "last": 127, "min": 127, "max": 127 },
               "indicator": { "kind": "note", "port": 0, "channel": 2, "number": 51,
                              "first": 127, "last": 127, "min": 127, "max": 127 } }]
            """.utf8)) as? NSArray
        #expect(layers != nil)
        #expect(layers == literal)
        #expect(try CaptureFile.decode(file.encoded()).layers == file.layers)

        var plain = CaptureSession(appVersion: "1.2.0", device: "Test", ports: CapturePorts(input: [], output: []), prompts: [Self.prompts[0]])
        plain.skip()
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plain.file.encoded()) as? [String: Any])
        #expect(plainObject["layers"] == nil)
    }

    @Test("Readouts for the layer steps, as the window shows them")
    func readouts() {
        let lc6000 = LayerFacts(
            layer: 2, select: Self.note(16, 55, .noteOff), withShift: true, indicator: Self.note(2, 51, nil),
            channelOffset: 1, numberOffset: 0
        )
        #expect(lc6000.selectReadout == "Layer 2: Shift + Note 55 on ch 16 · indicator Note 51 on ch 2")
        #expect(lc6000.offsetReadout == "Layer 2: channel +1")
        let plain = LayerFacts(layer: 2, select: Self.note(1, 70, .noteOff), withShift: false, indicator: nil, channelOffset: 0, numberOffset: 0)
        #expect(plain.selectReadout == "Layer 2: Note 70 on ch 1 · no indicator")
        #expect(plain.offsetReadout == "Layer 2: same message as deck 1")
        let unknown = LayerFacts(layer: 2, select: nil, withShift: false, indicator: nil, channelOffset: nil, numberOffset: nil)
        #expect(unknown.selectReadout == nil)
        #expect(unknown.offsetReadout == nil)
    }

    @Test("A file written without layers (the web capture's) gets them on read, the same as the app's (#190)")
    func inferredFillsLayers() {
        let app = Self.file(select: Self.lc6000Select, deck2Play: [[0x91, 1, 0x7F], [0x81, 1, 0x00]])
        var web = app
        web.layers = []
        #expect(web.inferred().layers == app.layers)
        #expect(!app.layers.isEmpty)
    }

    @Test("The window shows the layer readout live on each layer step, and VoiceOver hears it with the detection")
    func liveReadout() {
        var flow = CaptureFlow(prompts: Self.prompts, appVersion: "1.2.0")
        flow.start(device: "LC6000 PRIME", ports: CapturePorts(input: [], output: []), at: 0)
        flow.receive([0x90, 1, 0x7F], at: 1)
        flow.receive([0x80, 1, 0x00], at: 1.2)
        flow.next(at: 2)
        #expect(flow.layerReadout == nil)
        for (i, bytes) in Self.lc6000Select.enumerated() { flow.receive(bytes, at: 3 + Double(i) * 0.2) }
        flow.tick(at: 5)
        #expect(flow.layerReadout == "Layer 2: Shift + Note 55 on ch 16 · indicator Note 51 on ch 2")
        flow.next(at: 6)
        _ = flow.takeAnnouncement()
        flow.receive([0x91, 1, 0x7F], at: 7)
        #expect(flow.layerReadout == "Layer 2: channel +1")
        #expect(flow.takeAnnouncement() == "Detected: Note 1 on channel 2. Layer 2: channel +1.")
    }

    // MARK: #325

    @Test("A plain layer button still down when the indicator arrives is the select button, not Shift")
    func indicatorWhileHeld() {
        let layers = CaptureLayers.infer(
            prompts: Self.prompts,
            steps: Self.file(select: [[0x90, 70, 0x7F], [0x91, 51, 0x7F], [0x80, 70, 0x00]], deck2Play: [[0x91, 1, 0x7F]]).steps
        )
        #expect(layers.first?.select == Self.note(1, 70, .noteOff))
        #expect(layers.first?.withShift == false)
        #expect(layers.first?.indicator == Self.note(2, 51, nil))
    }

    @Test("LC6000 with Shift still held from the step before: its release in this step says Shift was held")
    func shiftHeldFromBefore() {
        let prompts = [
            CapturePrompt(id: "deck1.play", text: "Play.", gesture: .press),
            CapturePrompt(id: "deck1.shift", text: "Shift.", gesture: .press),
            CapturePrompt(id: "layer2.select", text: "Deck 2.", gesture: .press, layer: 2),
        ]
        var session = CaptureSession(appVersion: "1.2.0", device: "Test", ports: CapturePorts(input: [], output: []), prompts: prompts)
        session.receive([0x90, 1, 0x7F], at: 0); session.receive([0x80, 1, 0x00], at: 0.1); session.confirm(at: 1)
        session.receive([0x90, 26, 0x7F], at: 2); session.confirm(at: 3)   // Shift pressed, still held
        for (i, bytes) in [[0x9F, 55, 0x7F], [0x8F, 55, 0x00], [0x90, 51, 0x00], [0x91, 51, 0x7F], [0x80, 26, 0x00]].enumerated() {
            session.receive(bytes.map(UInt8.init), at: 4 + Double(i) * 0.1)
        }
        session.confirm(at: 5)
        let layer = CaptureLayers.infer(prompts: prompts, steps: session.file.steps).first
        #expect(layer?.withShift == true)
        #expect(layer?.select == Self.note(16, 55, .noteOff))
        #expect(layer?.indicator == Self.note(2, 51, nil))
    }
}
