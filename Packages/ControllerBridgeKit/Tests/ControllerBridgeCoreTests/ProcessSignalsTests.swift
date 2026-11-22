import ControllerBridgeCore
import Darwin
import Testing

/// #653: launched with stdout on a pipe whose reader had gone (an agent's tool shell), the app's first log print killed
/// it with SIGPIPE about 0.4 s in, with no crash report. Writes to a closed pipe must fail, not kill.
@Suite("Process signals")
struct ProcessSignalsTests {
    @Test("After ignoreBrokenPipe, a write to a pipe with no reader fails with EPIPE and the process lives")
    func brokenPipeIsAnError() {
        ProcessSignals.ignoreBrokenPipe()
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        close(ends[0])  // no reader
        let byte: [UInt8] = [0x41]
        let written = write(ends[1], byte, 1)
        let code = errno
        close(ends[1])
        #expect(written == -1)
        #expect(code == EPIPE)
    }
}
