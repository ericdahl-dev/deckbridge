import CoreMIDI
import DeviceFinder

/// The MIDI sources' and destinations' display names, as DeckBridge reads them. No client, no port: nothing is sent.
struct CoreMIDINames: MIDIPorts {
    func names() async -> [String] {
        let sources = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
        let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
        return (sources + destinations).compactMap { endpoint in
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr else { return nil }
            return name?.takeRetainedValue() as String?
        }
    }
}
