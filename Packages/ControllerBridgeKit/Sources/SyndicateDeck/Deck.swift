import ControllerBridgeCore

/// What the tool sends Syndicate (#680): DeckBridge's own messages for the same buttons, encoded by Core.
public enum Deck {
    /// A deck's address, as the Bridge builds it: `/Syndicate/Deck/<n>/<path>`.
    static func address(_ deck: Int, _ path: String) -> String { "/Syndicate/Deck/\(deck)/" + path }

    public static func messages(for command: Command) -> [OSCMessage] {
        switch command {
        case .play(let deck, let cue):
            // The hot cue pad's press and release, then Playing 1, which sets the deck playing (as Play with Cue held
            // does, #360) whether the cue started it or not: a set, so it never stops a playing deck.
            let pad = cue.map { [OSCMessage(address(deck, "HotCue"), [.int(Int32($0)), .int(1)]),
                                 OSCMessage(address(deck, "HotCue"), [.int(Int32($0)), .int(0)])] } ?? []
            return pad + [OSCMessage(address(deck, "Playing"), [.int(1)])]
        case .pause(let deck):
            return [OSCMessage(address(deck, "Playing"), [.int(0)])]
        case .toggle(let deck):
            return [OSCMessage(address(deck, "PlayPause"), [.int(1)])]
        }
    }
}
