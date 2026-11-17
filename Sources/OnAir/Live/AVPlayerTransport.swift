import AVFoundation

/// ``AudioTransport`` backed by `AVPlayer`.
///
/// Every ``start(_:attempt:)`` builds a new `AVPlayer` and `AVPlayerItem`: for live radio a
/// reconnection is a new connection, and a fresh player also recovers from a media services reset.
/// A live stream that "ends" (the server closed it) is reported as a failure so the player reconnects.
public final class AVPlayerTransport: AudioTransport {
    public let events: AsyncStream<AudioTransportEvent>
    private let continuation: AsyncStream<AudioTransportEvent>.Continuation
    private let configuresAudioSession: Bool

    private var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []

    /// - Parameter configuresAudioSession: On iOS, set the `.playback` category and activate the
    ///   session on start, and deactivate it on stop. Pass `false` if your app manages the session.
    ///   Ignored on macOS.
    public init(configuresAudioSession: Bool = true) {
        (events, continuation) = AsyncStream.makeStream()
        self.configuresAudioSession = configuresAudioSession
    }

    deinit {
        tearDown()
        continuation.finish()
    }

    public func start(_ url: URL, attempt: Int) {
        tearDown()
        let continuation = self.continuation
        let send: @Sendable (AudioTransportEvent.Kind) -> Void = { kind in
            continuation.yield(AudioTransportEvent(attempt: attempt, kind: kind))
        }

        #if os(iOS)
        if configuresAudioSession {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                send(.failed(PlaybackError(error.localizedDescription)))
                return
            }
        }
        #endif

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)

        observations = [
            item.observe(\.status, options: [.new]) { item, _ in
                guard item.status == .failed else { return }
                send(.failed(PlaybackError(item.error?.localizedDescription ?? "The stream failed to load.")))
            },
            player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                switch player.timeControlStatus {
                case .playing: send(.playing)
                case .waitingToPlayAtSpecifiedRate: send(.buffering)
                default: break
                }
            },
        ]

        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { _ in
                send(.failed(PlaybackError("The stream ended.")))
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil) { _ in
                send(.failed(PlaybackError("The stream dropped.")))
            },
        ]

        self.player = player
        player.play()
    }

    public func stop() {
        let wasActive = player != nil
        tearDown()
        #if os(iOS)
        if configuresAudioSession, wasActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func tearDown() {
        observations.forEach { $0.invalidate() }
        observations = []
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens = []
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
