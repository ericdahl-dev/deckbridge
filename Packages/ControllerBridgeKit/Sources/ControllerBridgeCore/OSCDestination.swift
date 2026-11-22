import Foundation
import Synchronization

/// One open socket to Syndicate: it sends a datagram, and throws when the send fails (EHOSTUNREACH and the like).
public protocol DatagramSink: Sendable {
    func send(_ bytes: [UInt8]) throws
}

/// Turns a host name into an IPv4 address, off the caller's thread: a `.local` lookup can take seconds.
public protocol HostResolver: Sendable {
    func resolve(_ host: String) async throws -> String
}

/// Where the bridge's OSC goes (#84, #109): Syndicate's host by IPv4 address or by name. `send` never waits: until a
/// destination is open, messages are dropped. A new destination opens before the old one is let go, so a bad host
/// or a name that can't be found leaves the old one working.
public final class OSCDestination: OSCSender {
    public typealias Open = @Sendable (_ ipv4: String, _ port: Int) throws -> any DatagramSink

    private struct State {
        var sink: (any DatagramSink)?
        var onReady: (@Sendable () -> Void)?
        var lastError: String?
        var connectProblem: String?
        var sendsFailing = false
        var address = ""
        var onSendFailure: (@Sendable () -> Void)?
        var lastFailureReport: Double?
        /// The host and port asked for last, kept for re-resolving.
        var target: (host: String, port: Int)?
        var reresolving = false
        /// Counts connects (#135): only the latest may install its destination or report a failure.
        var generation = 0
    }

    private let resolver: any HostResolver
    private let open: Open
    private let clock: any Clock
    private let state = Mutex(State())
    private let lookupTimeout: Duration

    /// `lookupTimeout`: a hung mDNS lookup gives up after this, with the same "Can't find" as a failed one.
    public init(resolver: any HostResolver, open: @escaping Open, clock: any Clock, lookupTimeout: Duration = .seconds(5)) {
        self.resolver = resolver
        self.open = open
        self.clock = clock
        self.lookupTimeout = lookupTimeout
    }

    /// Called when sends start failing (such as EHOSTUNREACH after the host's address changed), at most once a second.
    /// The app re-resolves the name then.
    public var onSendFailure: (@Sendable () -> Void)? {
        get { state.withLock { $0.onSendFailure } }
        set { state.withLock { $0.onSendFailure = newValue } }
    }

    /// A destination is open: sends go out.
    public var isReady: Bool { state.withLock { $0.sink != nil } }

    /// Why the last connect, or the last send, failed; nil once a destination opens and sends work.
    public var lastError: String? { state.withLock { $0.lastError } }

    /// Why the latest connect failed; nil once one opens. Unlike `lastError`, a failing send doesn't set it (#618).
    public var connectProblem: String? { state.withLock { $0.connectProblem } }

    /// The last send failed: true until a send works again (#618). `lastError` is untouched by a send that works.
    public var sendsFailing: Bool { state.withLock { $0.sendsFailing } }

    /// Called each time a destination opens, so the app can ask Syndicate to resend its state: anything sent while
    /// there was no destination was dropped.
    public var onReady: (@Sendable () -> Void)? {
        get { state.withLock { $0.onReady } }
        set { state.withLock { $0.onReady = newValue } }
    }

    /// Points the destination at `host`, an IPv4 address or a name resolved off the caller. Returns why it couldn't,
    /// with the old destination still in use; nil when the new one is open.
    /// A connect that a newer one overtook changes nothing and returns nil: the newer one owns the destination (#135).
    public func connect(host: String, port: Int) async -> String? {
        let generation = state.withLock { state -> Int in
            state.target = (host, port)
            state.generation += 1
            return state.generation
        }
        let address: String
        if BridgeSettings.isIPv4(host) {
            address = host
        } else {
            guard let resolved = await lookUp(host) else { return failed("Can't find \(host) on the network", generation) }
            address = resolved
        }
        guard isLatest(generation) else { return nil }
        do {
            let sink = try open(address, port)
            let ready = state.withLock { state -> (@Sendable () -> Void)?? in
                guard state.generation == generation else { return .none }
                state.sink = sink
                state.address = "\(address):\(port)"
                state.lastError = nil
                state.connectProblem = nil
                return .some(state.onReady)
            }
            if case .some(let callback) = ready { callback?() }
            return nil
        } catch {
            return failed("Couldn't send OSC to \(address):\(port)", generation)
        }
    }

    private func isLatest(_ generation: Int) -> Bool { state.withLock { $0.generation == generation } }

    /// Records why the latest connect failed and returns it; the old destination, if any, stays. An overtaken
    /// connect's failure is nobody's business: nil.
    private func failed(_ problem: String, _ generation: Int) -> String? {
        state.withLock { state -> String? in
            guard state.generation == generation else { return nil }
            state.lastError = problem
            state.connectProblem = problem
            return problem
        }
    }

    /// Looks the current host up again and moves there (on failing sends, or after wake): a `.local` Mac can rejoin the
    /// network with a new address. One at a time; a request while one runs returns at once. An IPv4 host just reopens.
    public func reresolve() async {
        let target = state.withLock { state -> (host: String, port: Int)? in
            guard !state.reresolving, let target = state.target else { return nil }
            state.reresolving = true
            return target
        }
        guard let target else { return }
        _ = await connect(host: target.host, port: target.port)
        state.withLock { $0.reresolving = false }
    }

    /// The resolver's answer, or nil if it fails or takes longer than the timeout. The lookup isn't awaited past the
    /// timeout: a hung one is left behind, since a resolver may not stop when canceled.
    private func lookUp(_ host: String) async -> String? {
        let resolver = self.resolver, timeout = lookupTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resumed = Mutex(false)
            let finish: @Sendable (String?) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task { finish(try? await resolver.resolve(host)) }
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    public func send(_ message: OSCMessage) {
        send(bytes: message.encoded())
    }

    /// One datagram for the whole bundle (#636).
    public func send(bundle messages: [OSCMessage]) {
        send(bytes: OSCPacket.bundle(messages))
    }

    private func send(bytes: [UInt8]) {
        guard let sink = state.withLock({ $0.sink }) else { return }
        do {
            try sink.send(bytes)
            state.withLock { $0.sendsFailing = false }
        } catch {
            let now = clock.now
            let report = state.withLock { state -> (@Sendable () -> Void)? in
                state.lastError = "Couldn't send OSC to \(state.address)"
                state.sendsFailing = true
                if let last = state.lastFailureReport, now - last < 1 { return nil }
                state.lastFailureReport = now
                return state.onSendFailure
            }
            report?()
        }
    }
}
