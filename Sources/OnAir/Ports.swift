import Foundation

// The three seams between `RadioPlayer` and the system. Production code uses the live
// implementations in `Live/`; tests replace them with in-memory doubles.

/// Moves audio bytes from a URL to the speaker. ``AVPlayerTransport`` is the live implementation.
///
/// A transport is owned by one ``RadioPlayer`` and only called from inside that actor,
/// so it does not need to be `Sendable`.
public protocol AudioTransport: AnyObject {
    /// Every event the transport produces, for every attempt, in order.
    /// Read once by the player; it is never finished while the transport is alive.
    var events: AsyncStream<AudioTransportEvent> { get }

    /// Drops whatever is loaded and opens `url` from scratch. Events caused by this call must carry `attempt`.
    func start(_ url: URL, attempt: Int)

    /// Stops output and releases the stream.
    func stop()
}

/// Something the transport observed, tagged with the attempt that caused it so late events can be discarded.
public struct AudioTransportEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Loading or stalled, no audio coming out.
        case buffering
        /// Audio is coming out.
        case playing
        /// The stream can't continue: it failed to load, dropped, or the server closed it.
        case failed(PlaybackError)
    }

    public var attempt: Int
    public var kind: Kind

    public init(attempt: Int, kind: Kind) {
        self.attempt = attempt
        self.kind = kind
    }
}

/// Reports whether the device has a usable network path. ``NetworkPathMonitor`` is the live implementation.
public protocol ConnectivityMonitor: Sendable {
    /// `true` when online, `false` when offline. The first value should describe the current path.
    func updates() -> AsyncStream<Bool>
}

/// System audio events the player must react to. ``AudioSessionNotifications`` is the live implementation (iOS only).
public protocol AudioSessionEventSource: Sendable {
    func events() -> AsyncStream<AudioSessionEvent>
}

public enum AudioSessionEvent: Sendable, Equatable {
    /// Another session took the audio (call, Siri, alarm).
    case interruptionBegan
    /// The interruption is over. `shouldResume` is the system's hint.
    case interruptionEnded(shouldResume: Bool)
    /// The active output went away (headphones unplugged, Bluetooth or CarPlay disconnected).
    case outputDeviceLost
    /// The media server restarted; every audio object is orphaned.
    case mediaServicesReset
}
