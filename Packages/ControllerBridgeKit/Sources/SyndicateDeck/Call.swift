// The command line of scripts/syndicate_deck (#680): what to do to which deck, and where Syndicate is if not where
// DeckBridge's settings say.

/// What to do to a deck.
public enum Command: Equatable, Sendable {
    /// Start the deck: from hot cue `cue` (1-8) if given, else where it is.
    case play(deck: Int, cue: Int?)
    /// Stop it.
    case pause(deck: Int)
    /// The Play button: playing stops, stopped plays.
    case toggle(deck: Int)
}

/// A command line that doesn't say a command: nothing is sent.
public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public struct Call: Equatable, Sendable {
    public var command: Command
    /// Overrides for DeckBridge's settings; nil takes them.
    public var host: String?
    public var port: Int?

    public static let usage = """
        usage: scripts/syndicate_deck play <deck> [--cue <1-8>] | pause <deck> | toggle <deck> [--host <h>] [--port <p>]
          deck 1-4. Syndicate's host and port come from DeckBridge's settings unless given.
        """

    public static func parse(_ arguments: [String]) throws -> Call {
        var words = arguments[...]
        guard let verb = words.popFirst(), let deckWord = words.popFirst() else { throw UsageError(description: usage) }
        guard let deck = Int(deckWord), (1...4).contains(deck) else {
            throw UsageError(description: "deck \(deckWord): Syndicate's decks are 1-4\n" + usage)
        }
        var cue: Int?
        var host: String?
        var port: Int?
        while let flag = words.popFirst() {
            guard let value = words.popFirst() else { throw UsageError(description: "\(flag) needs a value\n" + usage) }
            switch flag {
            case "--cue" where verb == "play":
                guard let n = Int(value), (1...8).contains(n) else {
                    throw UsageError(description: "hot cue \(value): a deck's hot cues are 1-8\n" + usage)
                }
                cue = n
            case "--host":
                host = value
            case "--port":
                guard let n = Int(value), (1...65535).contains(n) else {
                    throw UsageError(description: "port \(value): 1-65535\n" + usage)
                }
                port = n
            default:
                throw UsageError(description: "\(flag): not an option here\n" + usage)
            }
        }
        let command: Command
        switch verb {
        case "play": command = .play(deck: deck, cue: cue)
        case "pause": command = .pause(deck: deck)
        case "toggle": command = .toggle(deck: deck)
        default: throw UsageError(description: "\(verb): play, pause or toggle\n" + usage)
        }
        return Call(command: command, host: host, port: port)
    }
}
