import ControllerBridgeCore
import Testing

/// The jog display's MIDI as Universal MIDI Packets (#309), as CoreMIDI sends and delivers them, worked by hand from
/// the UMP spec: SysEx7 is type 3, two words, status (0 whole, 1 start, 2 continue, 3 end) and byte count in word 0,
/// then up to six data bytes; a channel voice message is type 2, one word, group 0.
@Suite("Jog display UMP packing")
struct JogDisplayUMPTests {
    @Test("A short SysEx in one packet: F0 00 20 7F 01 F7 (the hello's second frame)")
    func whole() {
        #expect(UMP.sysex7([0xF0, 0x00, 0x20, 0x7F, 0x01, 0xF7]) == [[0x3004_0020, 0x7F01_0000]])
    }

    @Test("Twelve bytes in two: start and end, six each (the hello's first frame)")
    func startEnd() {
        let hello = [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x60, 0x00, 0x04, 0x04, 0x01, 0x01, 0x00, 0xF7] as [UInt8]
        #expect(UMP.sysex7(hello) == [[0x3016_0002, 0x0B7F_1060], [0x3036_0004, 0x0401_0100]])
    }

    @Test("Thirteen bytes in three: start, continue, and an end with one byte")
    func continued() {
        let message = [0xF0] + (1...13).map(UInt8.init) + [0xF7]
        #expect(UMP.sysex7(message) == [[0x3016_0102, 0x0304_0506], [0x3026_0708, 0x090A_0B0C], [0x3031_0D00, 0x0000_0000]])
    }

    @Test("An empty SysEx (F0 F7) is one packet with no bytes")
    func empty() {
        #expect(UMP.sysex7([0xF0, 0xF7]) == [[0x3000_0000, 0x0000_0000]])
    }

    @Test("Pitch bend E0 00 10 and note 90 01 7F as one word each")
    func voice() {
        #expect(UMP.voice([0xE0, 0x00, 0x10]) == 0x20E0_0010)
        #expect(UMP.voice([0x90, 0x01, 0x7F]) == 0x2090_017F)
    }
}

/// The WD port's answers, rebuilt from packets (#309).
@Suite("Jog display SysEx reassembly")
struct SysExReassemblyTests {
    static let hello = [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x60, 0x00, 0x04, 0x04, 0x01, 0x01, 0x00, 0xF7] as [UInt8]

    @Test("Start and end packets give back the whole message, across two deliveries too")
    func across() {
        var assembler = SysExReassembler()
        #expect(assembler.feed([0x3016_0002, 0x0B7F_1060, 0x3036_0004, 0x0401_0100]) == [Self.hello])
        #expect(assembler.feed([0x3016_0002, 0x0B7F_1060]) == [])
        #expect(assembler.feed([0x3036_0004, 0x0401_0100]) == [Self.hello])
    }

    @Test("A one-word voice packet between SysEx packets is skipped without losing step")
    func voiceBetween() {
        var assembler = SysExReassembler()
        #expect(assembler.feed([0x2090_017F, 0x3004_0020, 0x7F01_0000]) == [[0xF0, 0x00, 0x20, 0x7F, 0x01, 0xF7]])
    }

    @Test("A new start drops an unfinished message")
    func restart() {
        var assembler = SysExReassembler()
        _ = assembler.feed([0x3016_0002, 0x0B7F_1060])
        #expect(assembler.feed([0x3004_0020, 0x7F01_0000]) == [[0xF0, 0x00, 0x20, 0x7F, 0x01, 0xF7]])
    }
}
