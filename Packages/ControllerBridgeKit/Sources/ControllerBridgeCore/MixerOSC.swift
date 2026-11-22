// Syndicate's mixer over OSC (#207). The feedback addresses are from a real Resend capture (on #207).
//
// The input addresses are the feedback addresses, confirmed on Syndicate by the #207 spike (2026-11-17): Volume,
// EQ Low, filter cut and Mute each set the value (0-1; Mute a 0/1 switch) and echoed it back, as User Guide 14.9 says.
// Not yet confirmed: Cue, which did nothing in the spike (perhaps no headphone output was set up). If an address
// turns out different, this table is the only place to change.

/// One of a mixer channel's values.
public enum MixerValue: CaseIterable, Equatable, Sendable {
    case volume, trim, eqLow, eqMid, eqHigh, filterCut, filterRes, filterWidth, cue, mute, solo, meter
}

public enum MixerOSC {
    /// The address of a value on mixer channel `channel` (1-4), under the OSC root ("/Syndicate/").
    public static func address(_ value: MixerValue, channel: Int, root: String) -> String {
        let mixer = root + "Mixer/"
        return switch value {
        case .volume: mixer + "CH\(channel)/Volume"
        case .trim: mixer + "CH\(channel)/Trim"
        case .eqLow: mixer + "CH\(channel)/EQ/Low"
        case .eqMid: mixer + "CH\(channel)/EQ/Mid"
        case .eqHigh: mixer + "CH\(channel)/EQ/High"
        case .filterCut: mixer + "filter\(channel).cut"
        case .filterRes: mixer + "filter\(channel).res"
        case .filterWidth: mixer + "filter\(channel).width"
        case .cue: mixer + "CH\(channel)/Cue"
        case .mute: mixer + "CH\(channel)/Mute"
        case .solo: mixer + "CH\(channel)/Solo"
        case .meter: mixer + "CH\(channel)/Meter"
        }
    }

    public struct Parsed: Equatable, Sendable {
        public var channel: Int
        public var value: MixerValue

        public init(channel: Int, value: MixerValue) {
            self.channel = channel
            self.value = value
        }
    }

    /// The channel and value of a mixer feedback address, or nil for anything else.
    public static func parse(_ address: String, root: String) -> Parsed? {
        for channel in 1...4 {
            // Syndicate matches addresses without regard to case, so feedback is read the same way.
            for value in MixerValue.allCases where address.lowercased() == self.address(value, channel: channel, root: root).lowercased() {
                return Parsed(channel: channel, value: value)
            }
        }
        return nil
    }
}
