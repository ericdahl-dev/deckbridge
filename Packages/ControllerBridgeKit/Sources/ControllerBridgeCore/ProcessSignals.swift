// What the process does with signals (#653).
import Foundation

public enum ProcessSignals {
    /// A write to a pipe or socket whose reader is gone fails with EPIPE instead of killing the process.
    /// The app's log also goes to stdout (for the smoke script), and a launch can hand it a pipe whose reader has gone.
    public static func ignoreBrokenPipe() { signal(SIGPIPE, SIG_IGN) }
}
