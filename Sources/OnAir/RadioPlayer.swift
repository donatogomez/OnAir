import Foundation

/// Plays a live audio stream and keeps it alive: it reconnects with backoff, waits for the
/// network instead of burning retries, and yields to system interruptions.
///
/// All state lives inside the actor, so `play`, `stop`, transport events, connectivity
/// changes and session events are applied one at a time, in order.
///
/// ```swift
/// let player = RadioPlayer()
/// Task {
///     for await state in await player.states() {
///         print(state)
///     }
/// }
/// await player.play(URL(string: "https://example.com/stream.mp3")!)
/// ```
public actor RadioPlayer {
    public struct Configuration: Sendable {
        public var reconnect: ReconnectPolicy
        /// When `true`, playback restarts after an interruption if the system says it should.
        /// Defaults to `false`: for live radio the listener decides.
        public var resumesAfterInterruption: Bool

        public init(reconnect: ReconnectPolicy = .default, resumesAfterInterruption: Bool = false) {
            self.reconnect = reconnect
            self.resumesAfterInterruption = resumesAfterInterruption
        }
    }

    /// The current state. Use ``states()`` to observe changes.
    public private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            for subscriber in subscribers.values { subscriber.yield(state) }
        }
    }

    private let configuration: Configuration
    private let transport: any AudioTransport
    private let connectivity: (any ConnectivityMonitor)?
    private let sessionEvents: (any AudioSessionEventSource)?
    /// Fixes a deadline `delay` from now and returns a sleep until it. Splitting the two lets the
    /// deadline be taken *before* `.reconnecting` is published, so a test clock advanced in response
    /// to that state always wakes the sleeper, whether or not it is already waiting.
    private let makeBackoffSleep: @Sendable (Duration) -> @Sendable () async throws -> Void

    /// What to play. Non-`nil` while the listener wants audio, including while interrupted.
    private var url: URL?
    /// Identifies the current transport attempt. Bumped on every start and stop, so events from an
    /// earlier attempt are recognisably stale.
    private var attempt = 0
    /// Consecutive failures, fed to the ``ReconnectPolicy``. Reset when audio plays.
    private var failedAttempts = 0
    private var isOnline = true
    private var reconnectTask: Task<Void, Never>?
    private var listeners: [Task<Void, Never>] = []
    private var subscribers: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]

    /// A player backed by `AVPlayer`, `NWPathMonitor` and, on iOS, `AVAudioSession` notifications.
    public init(configuration: Configuration = .init()) {
        #if os(iOS)
        let sessionEvents: (any AudioSessionEventSource)? = AudioSessionNotifications()
        #else
        let sessionEvents: (any AudioSessionEventSource)? = nil
        #endif
        self.init(
            configuration: configuration,
            transport: AVPlayerTransport(),
            connectivity: NetworkPathMonitor(),
            sessionEvents: sessionEvents,
            clock: ContinuousClock()
        )
    }

    /// A player with every dependency injected. Use it to swap the audio engine or to test without a network.
    public init(
        configuration: Configuration = .init(),
        transport: sending some AudioTransport,
        connectivity: (any ConnectivityMonitor)? = nil,
        sessionEvents: (any AudioSessionEventSource)? = nil,
        clock: some Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.connectivity = connectivity
        self.sessionEvents = sessionEvents
        self.makeBackoffSleep = { delay in
            let deadline = clock.now.advanced(by: delay)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    deinit {
        reconnectTask?.cancel()
        listeners.forEach { $0.cancel() }
        subscribers.values.forEach { $0.finish() }
    }

    // MARK: - Public API

    /// Starts playing `url`. Calling it again with the same URL while connecting or playing does nothing.
    public func play(_ url: URL) {
        if url == self.url, state == .connecting || state == .playing { return }
        self.url = url
        startListeningIfNeeded()
        connectFresh()
    }

    /// Stops playback and cancels any pending reconnection.
    public func stop() {
        url = nil
        haltTransport()
        state = .idle
    }

    /// The current state, then every change. Each call returns an independent stream.
    public func states() -> AsyncStream<PlaybackState> {
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(state)
        return stream
    }

    // MARK: - Transport

    private func connectFresh() {
        failedAttempts = 0
        state = .connecting
        startTransport()
    }

    private func startTransport() {
        guard let url else { return }
        cancelReconnect()
        attempt += 1
        transport.start(url, attempt: attempt)
    }

    private func haltTransport() {
        cancelReconnect()
        attempt += 1
        transport.stop()
    }

    private func handle(_ event: AudioTransportEvent) {
        guard event.attempt == attempt, url != nil else { return }
        switch event.kind {
        case .buffering:
            if state == .playing { state = .connecting }
        case .playing:
            failedAttempts = 0
            state = .playing
        case .failed(let error):
            scheduleReconnect(after: error)
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect(after error: PlaybackError) {
        guard reconnectTask == nil else { return }
        guard isOnline else {
            state = .waitingForNetwork
            return
        }
        failedAttempts += 1
        guard let delay = configuration.reconnect.delay(forAttempt: failedAttempts) else {
            url = nil
            haltTransport()
            state = .failed(error)
            return
        }
        let sleep = makeBackoffSleep(delay)
        state = .reconnecting(attempt: failedAttempts)
        reconnectTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            await self?.reconnectAfterBackoff()
        }
    }

    private func reconnectAfterBackoff() {
        // `stop()` or a fresh connection cancels the task; this runs on that task, so a sleep that
        // finished just before the cancellation still can't start a stale attempt.
        guard !Task.isCancelled, case .reconnecting = state else { return }
        reconnectTask = nil
        startTransport()
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Connectivity

    private func handleConnectivity(online: Bool) {
        isOnline = online
        guard url != nil else { return }
        switch (online, state) {
        case (false, .connecting), (false, .reconnecting):
            // Loading or retrying without a network only wastes attempts and battery.
            haltTransport()
            state = .waitingForNetwork
        case (true, .waitingForNetwork), (true, .reconnecting):
            // Network is back: reconnect now, with a fresh backoff, instead of waiting out the delay.
            connectFresh()
        default:
            // While playing, a short outage may be covered by the buffer; a real failure arrives as `.failed`.
            break
        }
    }

    // MARK: - Audio session

    private func handleSessionEvent(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            guard url != nil, state != .interrupted else { return }
            // Release the stream: resuming a paused live buffer would play stale audio.
            haltTransport()
            state = .interrupted
        case .interruptionEnded(let shouldResume):
            guard state == .interrupted, configuration.resumesAfterInterruption, shouldResume else { return }
            connectFresh()
        case .outputDeviceLost, .mediaServicesReset:
            guard url != nil else { return }
            stop()
        }
    }

    // MARK: - Plumbing

    /// Starts consuming the three input streams on the first `play`. Each task holds the actor weakly
    /// and resolves it per element, so the player can be deallocated while they wait.
    private func startListeningIfNeeded() {
        guard listeners.isEmpty else { return }
        let transportEvents = transport.events
        listeners.append(Task { [weak self] in
            for await event in transportEvents { await self?.handle(event) }
        })
        if let updates = connectivity?.updates() {
            listeners.append(Task { [weak self] in
                for await online in updates { await self?.handleConnectivity(online: online) }
            })
        }
        if let events = sessionEvents?.events() {
            listeners.append(Task { [weak self] in
                for await event in events { await self?.handleSessionEvent(event) }
            })
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
