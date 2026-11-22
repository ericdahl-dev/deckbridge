// What a controller's lights show right now (#554), one per output: the layers sharing a unit's port share it.
//
// The model, from agent2's reading of the LC6000's top panel firmware (#481): the unit has ONE set of light values. A
// note-on takes effect only on the current deck's channel, and a layer change writes no light: the lights keep
// showing the old deck until the host repaints them. So a light is known by its note (and whether it's a pad on the
// pads' own channel), not by the channel it was sent on; only the layer in front writes (Bridge.layerShown), on its
// channel, so every write recorded here is one the unit took. On the unit the last write to a light wins, whatever its
// kind (#541): a note-on and a color message to the same light replace each other here too.

/// One output's lights, as last sent.
final class LEDShown {
    /// A physical light: a button's note, or a pad's on the pads' own channel (#224).
    struct Light: Hashable, Sendable {
        var note: Int
        var onPads: Bool
    }

    /// What a light shows: a note-on's velocity, or a color message's RGB (#530).
    enum Value: Equatable, Sendable {
        case velocity(UInt8)
        case color([UInt8])
    }

    private var values: [Light: Value] = [:]

    /// Whether `value` on `light` should go out: true, and remembered, when the light doesn't show it already.
    func write(_ light: Light, _ value: Value) -> Bool {
        guard values[light] != value else { return false }
        values[light] = value
        return true
    }

    /// Forget every light, so the next paint sends them all: the unit forgot them (start, a reboot, the hello, LEDs
    /// on, the end of a sweep or capture, a layer change the unit made).
    func flush() { values.removeAll() }

    /// Every light shown, in note order.
    func shown(onPads: Bool) -> [(note: Int, value: Value)] {
        values.filter { $0.key.onPads == onPads }.sorted { $0.key.note < $1.key.note }.map { ($0.key.note, $0.value) }
    }
}
