// What the screen says when the updater asks DeckBridge for the panel's port (#710). Its own file, so UpdaterScreen.swift
// (#700, #726) is untouched.
import PortHandoff

extension UpdaterScreen {
    /// No answer from DeckBridge: the port isn't forced, so the owner frees it by hand.
    public static let deckBridgeNoAnswer = "DeckBridge didn't let go of the panel's USB cable. Turn off Send over the USB "
        + "cable in DeckBridge, or quit DeckBridge, then look again."

    /// The line for a borrow's outcome; nil when DeckBridge let go.
    public static func handoff(_ outcome: PortBorrow.Outcome) -> String? {
        switch outcome {
        case .lent: nil
        case .noAnswer: deckBridgeNoAnswer
        }
    }
}
