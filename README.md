# OnAir

[![CI](https://github.com/donatogomez/OnAir/actions/workflows/ci.yml/badge.svg)](https://github.com/donatogomez/OnAir/actions/workflows/ci.yml)

A small Swift package that plays a **live audio stream** (internet radio, Icecast/Shoutcast, HLS audio) and keeps it alive. It reconnects with exponential backoff, waits for the network instead of burning retries, and yields to phone calls and Siri. State comes out as an `AsyncStream`.

It is extracted from the player of a 24/7 radio app on the App Store, with everything station-specific removed.

- Swift 6, strict concurrency, no third-party dependencies
- iOS 17+ and macOS 14+
- `AVPlayer`, `NWPathMonitor` and `AVAudioSession` sit behind protocols, so the whole state machine is tested without audio or network

## Installation

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/donatogomez/OnAir.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["OnAir"]),
]
```

In Xcode: **File → Add Package Dependencies…** and paste the repository URL.

For background playback on iOS, enable **Background Modes → Audio** in your target. `AVPlayerTransport` sets the `.playback` audio session category for you; pass `configuresAudioSession: false` if your app manages the session itself.

## Usage

```swift
import OnAir

let player = RadioPlayer()

Task {
    for await state in await player.states() {
        switch state {
        case .idle: print("Stopped")
        case .connecting: print("Connecting…")
        case .playing: print("On air")
        case .reconnecting(let attempt): print("Reconnecting (attempt \(attempt))…")
        case .waitingForNetwork: print("Offline, waiting for the network")
        case .interrupted: print("Interrupted, tap play to resume")
        case .failed(let error): print("Gave up: \(error)")
        }
    }
}

await player.play(URL(string: "https://ice1.somafm.com/groovesalad-128-mp3")!)
// later
await player.stop()
```

`states()` yields the current state first and then every change. Each call returns an independent stream, so a view, a Now Playing updater and a logger can all subscribe.

### Configuration

```swift
let player = RadioPlayer(configuration: .init(
    reconnect: ReconnectPolicy(initialDelay: .seconds(2), multiplier: 2, maxDelay: .seconds(60), maxAttempts: 10),
    resumesAfterInterruption: true
))
```

| Option | Default | Meaning |
|---|---|---|
| `reconnect` | `.default`: 1 s, ×2, up to 30 s, forever | Backoff between attempts. `.never` fails on the first error. |
| `resumesAfterInterruption` | `false` | Restart after a call or Siri if the system says it should. By default the listener decides. |

### Example app

`Examples/OnAirDemo` is a macOS command-line player:

```bash
swift run --package-path Examples/OnAirDemo OnAirDemo
```

It plays SomaFM's Groove Salad (or the URL you pass as an argument) and prints every state change.

## Design

```
            play / stop                    states()
UI  ───────────────────────►  RadioPlayer  ───────────►  UI, Now Playing, logs
                               (actor)
          ┌─────────────────────┼─────────────────────┐
   AudioTransport      ConnectivityMonitor    AudioSessionEventSource    Clock
   AVPlayerTransport   NetworkPathMonitor     AudioSessionNotifications  ContinuousClock
```

**Why an actor.** A live player receives inputs from many places at once: the user's taps, `AVPlayer` KVO callbacks on arbitrary threads, network path changes, audio session notifications and backoff timers. Inside the actor these are applied one at a time, and the compiler checks that nothing touches the state from outside. Without it you need locks or a serial queue, and nothing stops a callback from forgetting to use them.

**Why `AsyncStream`.** States are a sequence of values over time, and `for await` is the native way to consume one: it works from SwiftUI's `.task`, cancels with the task, and needs no Combine or delegate. All three inputs reach the actor the same way, as streams.

**Stale events.** Every transport start gets an attempt number, and every event the transport emits carries it. When the player restarts or stops, it bumps the number, so a late `AVPlayer` callback from a previous connection is recognised and dropped instead of flipping the state back to `playing`.

**Intent vs. technical state.** `play` and `stop` express what the listener wants; transport events never change that. So `stop()` always wins, even in the middle of connecting or a backoff.

**Live radio specifics.**
- Every reconnection builds a new `AVPlayerItem`. Resuming a paused live buffer would play stale audio, so an interruption releases the stream and the next `play` goes back to the live edge.
- When a live stream "ends" (the server closed the connection), it is treated as a failure and reconnected.
- Offline time does not consume retries. When the path comes back, the player reconnects immediately with a fresh backoff.
- Unplugging headphones or losing the Bluetooth/CarPlay route stops playback, as Apple's guidelines recommend.

**Testing.** Every system dependency is a protocol, and the backoff uses an injected `Clock`. Tests drive the player with in-memory doubles and a manual clock, then wait on the player's own outputs. There are no sleeps, timeouts or network calls, so the suite runs in milliseconds and gives the same result every time. The backoff deadline is fixed *before* `.reconnecting` is published, so a test that advances the clock in response to that state never races the sleeping task.

## Limitations

- **No metadata.** ICY "now playing" titles, artwork and history are out of scope; most stations expose them through their own API.
- **No Now Playing or remote commands.** Wire `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` to `states()` in your app; their content is product-specific.
- **One stream at a time**, no pause/seek or DVR: this is a live player.
- **macOS has no audio session**, so interruptions and route changes are handled on iOS only.
- **The live adapters are not unit tested.** `AVPlayerTransport`, `NetworkPathMonitor` and `AudioSessionNotifications` are thin wrappers over system frameworks; the logic they feed is covered by the tests, and the example app exercises them end to end.
- Buffering mid-playback is reported as `.connecting` rather than a separate state.

## License

MIT. See [LICENSE](LICENSE).
