// scripts/syndicate_deck (#680): drives a Syndicate deck over OSC for on-hardware tests. A thin shell over
// SyndicateDeck: parse, find Syndicate, send DeckBridge's own messages, then say whether the deck is playing if
// Syndicate's feedback can be heard. Reads DeckBridge's settings, never writes them; never opens MIDI.
import Foundation
import SyndicateDeck

let call: Call
do {
    call = try Call.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}

let preferences = FileManager.default.contents(atPath: Destination.preferencesPath(home: NSHomeDirectory()))
let place = Destination.resolve(preferences: preferences, host: call.host, port: call.port)
let deck: Int = switch call.command {
case .play(let deck, _), .pause(let deck), .toggle(let deck): deck
}
let source = switch place.from {
case .commandLine: "from the command line"
case .settings: "from DeckBridge's settings"
case .defaults: "Syndicate's defaults"
}

// Listening first, so the feedback to these very messages is heard.
let listener = Playing.Listener(port: place.feedbackPort)
let messages = Deck.messages(for: call.command)
do {
    try UDP.send(messages, host: place.host, port: place.port)
} catch {
    FileHandle.standardError.write(Data("syndicate_deck: \(error)\n".utf8))
    exit(1)
}
for message in messages { print("sent \(message.address) \(message.arguments)") }
print("to \(place.host):\(place.port) (\(source))")

if let listener {
    defer { listener.close() }
    switch listener.wait(deck: deck, seconds: 1) {
    case true?: print("deck \(deck): playing")
    case false?: print("deck \(deck): stopped")
    case nil: print("deck \(deck): no feedback on port \(place.feedbackPort) within 1 s; can't tell")
    }
} else {
    print("deck \(deck): can't tell while DeckBridge holds the feedback port \(place.feedbackPort); "
          + "check its trace or the deck panel's perf line (docs/agents/syndicate-deck.md)")
}
