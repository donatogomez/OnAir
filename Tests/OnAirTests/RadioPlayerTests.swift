import Foundation
import Testing
import OnAir

private let stream = URL(string: "https://radio.example/live")!
private let otherStream = URL(string: "https://radio.example/other")!
private let dropped = PlaybackError("dropped")

/// Every test drives the player through in-memory doubles and a manual clock, and waits on the
/// player's own output streams (`states()` and the transport's commands). No sleeps, no network.
/// Each input source is a FIFO, so "nothing else happened" is checked by sending a later event
/// through the same source and asserting it is the next thing observed.
@Suite("RadioPlayer", .timeLimit(.minutes(1)))
struct RadioPlayerTests {
    struct Harness {
        let transport = FakeTransport()
        let connectivity = FakeConnectivity()
        let session = FakeSessionEvents()
        let clock = TestClock()
        let player: RadioPlayer

        init(_ configuration: RadioPlayer.Configuration = .init()) {
            player = RadioPlayer(
                configuration: configuration,
                transport: transport,
                connectivity: connectivity,
                sessionEvents: session,
                clock: clock
            )
        }
    }

    // MARK: - Basic playback

    @Test func startsIdle() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()

        #expect(await states.next() == .idle)
        #expect(await h.player.state == .idle)
    }

    @Test func playStartsTheTransportAndConnects() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()

        await h.player.play(stream)

        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
    }

    @Test func transportPlayingPublishesPlaying() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        await h.player.play(stream)

        h.transport.send(.playing, attempt: 1)

        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .playing)
    }

    @Test func stallWhilePlayingShowsConnectingUntilAudioResumes() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        await h.player.play(stream)

        h.transport.send(.playing, attempt: 1)
        h.transport.send(.buffering, attempt: 1)
        h.transport.send(.playing, attempt: 1)

        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .playing)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .playing)
    }

    @Test func playingTheSameURLAgainDoesNotRestart() async {
        let h = Harness()
        var commands = h.transport.commands.makeAsyncIterator()

        await h.player.play(stream)
        await h.player.play(stream)
        await h.player.stop()

        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
    }

    @Test func playingAnotherURLRestartsWithANewAttempt() async {
        let h = Harness()
        var commands = h.transport.commands.makeAsyncIterator()

        await h.player.play(stream)
        await h.player.play(otherStream)

        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .start(otherStream, attempt: 2))
    }

    @Test func stopStopsTheTransportAndGoesIdle() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)

        await h.player.stop()

        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .idle)
    }

    // MARK: - Stale events

    @Test func eventsFromAReplacedAttemptAreIgnored() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        await h.player.play(stream)
        await h.player.play(otherStream)

        h.transport.send(.failed(dropped), attempt: 1)
        h.transport.send(.playing, attempt: 2)

        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .playing)
    }

    @Test func eventsFromBeforeStopAreIgnored() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        await h.player.play(stream)
        await h.player.stop()
        await h.player.play(otherStream)

        h.transport.send(.failed(dropped), attempt: 1)
        h.transport.send(.playing, attempt: 3)

        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .playing)
    }

    // MARK: - Reconnection

    @Test func failureReconnectsAfterTheBackoff() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        #expect(await commands.next() == .start(stream, attempt: 1))

        h.transport.send(.failed(dropped), attempt: 1)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .reconnecting(attempt: 1))

        h.clock.advance(by: .seconds(1))
        #expect(await commands.next() == .start(stream, attempt: 2))

        h.transport.send(.playing, attempt: 2)
        #expect(await states.next() == .playing)
    }

    @Test func consecutiveFailuresCountUpAndPlayingResetsTheCount() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await commands.next() == .start(stream, attempt: 1))

        h.transport.send(.failed(dropped), attempt: 1)
        #expect(await states.next() == .reconnecting(attempt: 1))
        h.clock.advance(by: .seconds(1))
        #expect(await commands.next() == .start(stream, attempt: 2))

        h.transport.send(.failed(dropped), attempt: 2)
        #expect(await states.next() == .reconnecting(attempt: 2))
        h.clock.advance(by: .seconds(2))
        #expect(await commands.next() == .start(stream, attempt: 3))

        h.transport.send(.playing, attempt: 3)
        #expect(await states.next() == .playing)

        h.transport.send(.failed(dropped), attempt: 3)
        #expect(await states.next() == .reconnecting(attempt: 1))
    }

    @Test func failsWhenThePolicyRunsOutOfAttempts() async {
        let h = Harness(.init(reconnect: ReconnectPolicy(maxAttempts: 1)))
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)

        #expect(await commands.next() == .start(stream, attempt: 1))

        h.transport.send(.failed(dropped), attempt: 1)
        #expect(await states.next() == .reconnecting(attempt: 1))
        h.clock.advance(by: .seconds(1))
        #expect(await commands.next() == .start(stream, attempt: 2))
        h.transport.send(.failed(dropped), attempt: 2)

        #expect(await states.next() == .failed(dropped))
        #expect(await commands.next() == .stop)
    }

    @Test func neverPolicyFailsOnTheFirstError() async {
        let h = Harness(.init(reconnect: .never))
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)

        h.transport.send(.failed(dropped), attempt: 1)

        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .failed(dropped))
        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
    }

    @Test func stopDuringTheBackoffCancelsTheReconnection() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        h.transport.send(.failed(dropped), attempt: 1)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .reconnecting(attempt: 1))

        await h.player.stop()
        h.clock.advance(by: .seconds(60))
        await h.player.play(otherStream)

        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
        #expect(await commands.next() == .start(otherStream, attempt: 3))
    }

    // MARK: - Connectivity

    @Test func goingOfflineDuringTheBackoffWaitsForTheNetwork() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        h.transport.send(.failed(dropped), attempt: 1)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .reconnecting(attempt: 1))

        h.connectivity.send(online: false)
        #expect(await states.next() == .waitingForNetwork)
        h.clock.advance(by: .seconds(60))

        h.connectivity.send(online: true)
        #expect(await states.next() == .connecting)
        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
        #expect(await commands.next() == .start(stream, attempt: 3))

        // The backoff starts over after the network comes back.
        h.transport.send(.failed(dropped), attempt: 3)
        #expect(await states.next() == .reconnecting(attempt: 1))
    }

    @Test func goingOfflineWhileConnectingWaitsForTheNetwork() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)

        h.connectivity.send(online: false)
        #expect(await states.next() == .waitingForNetwork)
        h.connectivity.send(online: true)
        #expect(await states.next() == .connecting)

        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
        #expect(await commands.next() == .start(stream, attempt: 3))
    }

    // MARK: - Audio session

    @Test func interruptionReleasesTheStreamAndWaitsForTheListener() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        h.transport.send(.playing, attempt: 1)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .playing)

        h.session.send(.interruptionBegan)
        #expect(await states.next() == .interrupted)

        // Default configuration: the end of the interruption does not resume playback.
        h.session.send(.interruptionEnded(shouldResume: true))
        h.session.send(.outputDeviceLost)
        #expect(await states.next() == .idle)

        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
        #expect(await commands.next() == .stop)
    }

    @Test func playAfterAnInterruptionStartsAFreshConnection() async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        h.session.send(.interruptionBegan)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .interrupted)

        await h.player.play(stream)

        #expect(await states.next() == .connecting)
        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
        #expect(await commands.next() == .start(stream, attempt: 3))
    }

    @Test func resumesAfterAnInterruptionWhenConfigured() async {
        let h = Harness(.init(resumesAfterInterruption: true))
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        h.session.send(.interruptionBegan)
        h.session.send(.interruptionEnded(shouldResume: true))

        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .interrupted)
        #expect(await states.next() == .connecting)
        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
        #expect(await commands.next() == .start(stream, attempt: 3))
    }

    @Test func doesNotResumeWithoutTheSystemHint() async {
        let h = Harness(.init(resumesAfterInterruption: true))
        var states = await h.player.states().makeAsyncIterator()
        await h.player.play(stream)
        h.session.send(.interruptionBegan)
        h.session.send(.interruptionEnded(shouldResume: false))
        h.session.send(.outputDeviceLost)

        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .interrupted)
        #expect(await states.next() == .idle)
    }

    @Test(arguments: [AudioSessionEvent.outputDeviceLost, .mediaServicesReset])
    func losingTheOutputOrTheMediaServerStopsPlayback(event: AudioSessionEvent) async {
        let h = Harness()
        var states = await h.player.states().makeAsyncIterator()
        var commands = h.transport.commands.makeAsyncIterator()
        await h.player.play(stream)
        h.transport.send(.playing, attempt: 1)
        #expect(await states.next() == .idle)
        #expect(await states.next() == .connecting)
        #expect(await states.next() == .playing)

        h.session.send(event)

        #expect(await states.next() == .idle)
        #expect(await commands.next() == .start(stream, attempt: 1))
        #expect(await commands.next() == .stop)
    }

    // MARK: - Subscriptions

    @Test func everySubscriberReceivesTheStates() async {
        let h = Harness()
        var first = await h.player.states().makeAsyncIterator()
        var second = await h.player.states().makeAsyncIterator()

        await h.player.play(stream)

        #expect(await first.next() == .idle)
        #expect(await first.next() == .connecting)
        #expect(await second.next() == .idle)
        #expect(await second.next() == .connecting)
    }

    @Test func aLateSubscriberStartsWithTheCurrentState() async {
        let h = Harness()
        var early = await h.player.states().makeAsyncIterator()
        await h.player.play(stream)
        h.transport.send(.playing, attempt: 1)
        #expect(await early.next() == .idle)
        #expect(await early.next() == .connecting)
        #expect(await early.next() == .playing)

        var late = await h.player.states().makeAsyncIterator()

        #expect(await late.next() == .playing)
    }
}
