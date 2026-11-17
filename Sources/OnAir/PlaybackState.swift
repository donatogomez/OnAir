/// What a ``RadioPlayer`` is doing right now.
///
/// Subscribe with ``RadioPlayer/states()`` to drive a UI.
public enum PlaybackState: Sendable, Equatable {
    /// Nothing is playing: never started, stopped by the user, or the output device went away.
    case idle
    /// Opening the stream, or re-buffering after a stall.
    case connecting
    /// Audio is coming out.
    case playing
    /// The stream failed and the player is waiting out the backoff before trying again.
    /// `attempt` starts at 1 and counts consecutive failures.
    case reconnecting(attempt: Int)
    /// The device is offline. No retries are spent; the player reconnects as soon as the network is back.
    case waitingForNetwork
    /// Another audio session took over (a phone call, Siri, an alarm).
    /// The player waits for ``RadioPlayer/play(_:)`` unless
    /// ``RadioPlayer/Configuration/resumesAfterInterruption`` is enabled.
    case interrupted
    /// The player gave up: the ``ReconnectPolicy`` ran out of attempts.
    case failed(PlaybackError)
}

/// A playback failure, reduced to a message so ``PlaybackState`` stays `Equatable` and `Sendable`.
public struct PlaybackError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
