/// One guided capture (#185): it walks the prompt list, credits each message to the current step, and moves on when
/// the owner confirms, redoes or skips. The app and the tests feed it raw MIDI bytes, so it needs no CoreMIDI.
///
/// Noise, such as the LC6000's note 52 heartbeat in host mode, isn't credited to a step. The prompt list starts with
/// an `idle` prompt (hands off), and what arrives then is noise from that point on. A capture without one falls back,
/// when it ends, to calling noise what came in every one of three or more confirmed steps.
///
/// Tails aren't credited either (#186): a release whose press came before the step, and, for half a second after
/// the step starts, anything from the controls of the take before it (a jog still spinning). They stay in the step's
/// messages, marked as tails (#229), and count for nothing.
public struct CaptureSession: Sendable {
    public let appVersion: String
    public let device: String
    public let ports: CapturePorts
    public let prompts: [CapturePrompt]
    /// The owner's optional note, the only free text in the file.
    public var note: String?

    typealias Take = [(time: Double, port: Int, bytes: [UInt8], tail: Bool)]

    private var index = 0
    private var finished: [(prompt: CapturePrompt, status: StepStatus, take: Take, leds: [LEDAnswer])] = []
    /// The current take: each message with the host time it arrived, in seconds.
    private var take: Take = []
    private var leds: [LEDAnswer] = []
    /// When the current step started, if the app said (confirm, redo and skip take a time).
    private var stepStart: Double?
    /// The controls of the take before this one, whose tails are dropped just after the step starts.
    private var tailKeys: Set<[UInt8]> = []
    /// Notes pressed in this take, so a release without its press is known for a tail.
    private var pressed: Set<[UInt8]> = []

    /// How long after a step starts the previous take's controls are taken for tails, in seconds.
    static let tailWindow = 0.5

    public init(appVersion: String, device: String, ports: CapturePorts, prompts: [CapturePrompt]) {
        self.appVersion = appVersion
        self.device = device
        self.ports = ports
        self.prompts = prompts
    }

    /// How many prompts are behind: the current one's index.
    public var finishedCount: Int { index }

    /// The prompt being captured, or nil when the list is done.
    public var current: CapturePrompt? { prompts.indices.contains(index) ? prompts[index] : nil }

    /// Whether anything but clock and noise has arrived in the current take.
    public var hasTake: Bool {
        let noise = Set(idleNoise)
        return take.contains {
            !$0.tail && !Inference.isRealtime($0.bytes) && !(Inference.noiseKey($0.bytes).map(noise.contains) ?? false)
        }
    }

    /// For a step repeated with Shift held, how its control differs from the step it repeats, so far (#229).
    /// On a layer step (#217), what the layers say so far, with the current take counted as if confirmed.
    public var currentLayer: LayerFacts? {
        guard let current, let layer = current.layer else { return nil }
        let finished = file.steps
        let preview = Self.step(current, .confirmed, take, noise: Set(idleNoise), before: finished)
        return CaptureLayers.infer(prompts: prompts, steps: finished + [preview]).first { $0.layer == layer }
    }

    public var currentShift: ShiftLayer? {
        guard let current, current.shiftedOf != nil else { return nil }
        return Self.step(current, .confirmed, take, noise: Set(idleNoise), before: file.steps).shift
    }

    /// What the current take has detected so far, for showing live.
    public var currentControls: [ControlFacts] {
        guard let current else { return [] }
        return Self.step(current, .confirmed, take, noise: Set(idleNoise), before: []).controls
    }

    /// One raw MIDI message, at any host clock in seconds, from an input port (an index into `ports.input`). Ignored
    /// once the list is done.
    public mutating func receive(_ bytes: [UInt8], at time: Double, port: Int = 0) {
        guard current != nil else { return }
        var tail = false
        if let key = Inference.noiseKey(bytes), !Inference.isRealtime(bytes) {
            let portKey = [UInt8(truncatingIfNeeded: port)] + key
            let note = key[0] & 0xF0 == 0x90
            let release = note && (bytes[0] & 0xF0 == 0x80 || bytes[2] == 0)
            if release, !pressed.contains(portKey) { tail = true }
            if let stepStart, time - stepStart < Self.tailWindow, tailKeys.contains(portKey) { tail = true }
            if note, !release, !tail { pressed.insert(portKey) }
        }
        take.append((time, port, bytes, tail))
    }

    /// The owner's answer to one LED probe message during the current step. The probe itself (what's safe to send)
    /// lives in the app; the session only keeps the answers.
    public mutating func answerLED(_ answer: LEDAnswer) {
        guard current != nil else { return }
        leds.append(answer)
    }

    /// The owner's answer to an LED probe about a finished step's control (#187), kept with that step. Ignored for a
    /// step that isn't in the capture.
    public mutating func answerLED(_ answer: LEDAnswer, forStep id: String) {
        guard let index = finished.lastIndex(where: { $0.prompt.id == id }) else { return }
        finished[index].leds.append(answer)
    }

    /// Keeps the current take and moves to the next prompt, which starts at `time` (host seconds) when given.
    public mutating func confirm(at time: Double? = nil) {
        let kept = take
        finish(.confirmed)
        startStep(at: time, after: kept)
    }

    /// Throws the current take away and listens again, from `time` when given.
    public mutating func redo(at time: Double? = nil) {
        let discarded = take
        take = []
        leds = []
        startStep(at: time, after: discarded)
    }

    /// Records the prompt as skipped, with nothing captured, and moves on.
    public mutating func skip(at time: Double? = nil) {
        let discarded = take
        take = []
        leds = []
        finish(.skipped)
        startStep(at: time, after: discarded)
    }

    private mutating func startStep(at time: Double?, after previous: Take) {
        stepStart = time
        tailKeys = Set(previous.compactMap { message in
            Inference.noiseKey(message.bytes).map { [UInt8(truncatingIfNeeded: message.port)] + $0 }
        })
        pressed = []
    }

    /// The capture so far.
    public var file: CaptureFile {
        let noise = unique(idleNoise + repeatedNoise + realtimeNoise)
        var steps: [CaptureStep] = []
        for recorded in finished {
            var recordedStep = Self.step(recorded.prompt, recorded.status, recorded.take, noise: Set(noise), before: steps)
            recordedStep.leds = recorded.leds
            steps.append(recordedStep)
        }
        return CaptureFile(
            appVersion: appVersion, device: device, ports: ports, note: note, prompts: prompts, noise: noise, steps: steps,
            layers: CaptureLayers.infer(prompts: prompts, steps: steps)
        )
    }

    /// Noise keys heard during confirmed idle steps, in the order first heard.
    private var idleNoise: [[UInt8]] {
        unique(finished.filter { $0.status == .confirmed && $0.prompt.gesture == .idle }.flatMap {
            $0.take.filter { !$0.tail }.compactMap { Inference.noiseKey($0.bytes) }
        })
    }

    /// Real-time messages (clock, active sensing) heard anywhere: never credited to a step.
    private var realtimeNoise: [[UInt8]] {
        unique(finished.flatMap(\.take).map(\.bytes).filter(Inference.isRealtime))
    }

    /// Noise keys heard in every confirmed step, for a capture without a confirmed idle step. It takes three steps at
    /// least, since two steps can share a real control (jog touch and jog edge both send the jog's CCs). A step
    /// repeated with Shift held doesn't count: it repeats its control on purpose.
    private var repeatedNoise: [[UInt8]] {
        guard !finished.contains(where: { $0.status == .confirmed && $0.prompt.gesture == .idle }) else { return [] }
        let takes = finished.filter { $0.status == .confirmed && $0.prompt.gesture != .idle && $0.prompt.shiftedOf == nil }
            .map { $0.take.filter { !$0.tail } }
        guard takes.count >= 3 else { return [] }
        let keys = takes.map { Set($0.compactMap { Inference.noiseKey($0.bytes) }) }
        let everywhere = keys.dropFirst().reduce(keys[0]) { $0.intersection($1) }
        return unique(takes[0].compactMap { Inference.noiseKey($0.bytes) }).filter(everywhere.contains)
    }

    private func unique(_ keys: [[UInt8]]) -> [[UInt8]] {
        var seen: Set<[UInt8]> = []
        return keys.filter { seen.insert($0).inserted }
    }

    /// A step as the file shows it: noise left out, the controls inferred, and the Shift layer against `before`.
    /// Static, so a file read back can run the same inference (`CaptureFile.inferred()`, #190).
    static func step(_ prompt: CapturePrompt, _ status: StepStatus, _ take: Take, noise: Set<[UInt8]>, before: [CaptureStep]) -> CaptureStep {
        let heard = take.filter { !Inference.isRealtime($0.bytes) }
        let kept = prompt.gesture == .idle ? heard : heard.filter { Inference.noiseKey($0.bytes).map { !noise.contains($0) } ?? true }
        let bytes = kept.filter { !$0.tail }.map { (port: $0.port, bytes: $0.bytes) }
        var controls = prompt.gesture == .idle ? [] : Inference.controls(in: bytes, gesture: prompt.gesture)
        var shift: ShiftLayer?
        if let base = prompt.shiftedOf {
            if let held = Inference.heldAround(bytes) {
                controls = Inference.removing(held, from: controls)
            }
            shift = shiftLayer(of: base, controls.first, before: before)
        }
        return CaptureStep(prompt: prompt.id, status: status, messages: messages(kept), controls: controls, shift: shift)
    }

    private static func messages(_ take: Take) -> [CaptureMessage] {
        guard let start = take.first?.time else { return [] }
        return take.map { CaptureMessage(t: Int((($0.time - start) * 1000).rounded()), port: $0.port, bytes: $0.bytes, tail: $0.tail) }
    }

    /// How a shifted control differs from the same control in the confirmed unshifted step.
    private static func shiftLayer(of base: String, _ control: ControlFacts?, before: [CaptureStep]) -> ShiftLayer? {
        guard let control,
            let unshifted = before.last(where: { $0.prompt == base && $0.status == .confirmed })?.controls.first,
            unshifted.kind == control.kind
        else { return nil }
        return ShiftLayer(
            of: base, channelOffset: control.channel - unshifted.channel,
            numberOffset: (control.number ?? 0) - (unshifted.number ?? 0)
        )
    }

    private mutating func finish(_ status: StepStatus) {
        guard let prompt = current else { return }
        finished.append((prompt, status, take, leds))
        take = []
        leds = []
        index += 1
    }
}
