import Foundation
import OnAir

/// Records what the player asks for and lets the test emit transport events.
/// Everything goes through `AsyncStream`s, so it is `Sendable` without locks.
final class FakeTransport: AudioTransport, Sendable {
    enum Command: Equatable, Sendable {
        case start(URL, attempt: Int)
        case stop
    }

    let events: AsyncStream<AudioTransportEvent>
    let commands: AsyncStream<Command>
    private let eventsContinuation: AsyncStream<AudioTransportEvent>.Continuation
    private let commandsContinuation: AsyncStream<Command>.Continuation

    init() {
        (events, eventsContinuation) = AsyncStream.makeStream()
        (commands, commandsContinuation) = AsyncStream.makeStream()
    }

    func start(_ url: URL, attempt: Int) {
        commandsContinuation.yield(.start(url, attempt: attempt))
    }

    func stop() {
        commandsContinuation.yield(.stop)
    }

    func send(_ kind: AudioTransportEvent.Kind, attempt: Int) {
        eventsContinuation.yield(AudioTransportEvent(attempt: attempt, kind: kind))
    }
}

struct FakeConnectivity: ConnectivityMonitor {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func updates() -> AsyncStream<Bool> { stream }

    func send(online: Bool) {
        continuation.yield(online)
    }
}

struct FakeSessionEvents: AudioSessionEventSource {
    private let stream: AsyncStream<AudioSessionEvent>
    private let continuation: AsyncStream<AudioSessionEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<AudioSessionEvent> { stream }

    func send(_ event: AudioSessionEvent) {
        continuation.yield(event)
    }
}
