import Foundation
import OnAir

// Plays a public test stream (SomaFM Groove Salad) or the URL passed as the first argument,
// prints every state change, and stops when you press Return.
//
//   swift run --package-path Examples/OnAirDemo OnAirDemo [stream-url]

let defaultStream = "https://ice1.somafm.com/groovesalad-128-mp3"
guard let url = URL(string: CommandLine.arguments.dropFirst().first ?? defaultStream) else {
    print("Invalid URL")
    exit(1)
}

let player = RadioPlayer()

let printer = Task {
    for await state in await player.states() {
        print("state: \(state)")
    }
}

print("Playing \(url.absoluteString). Press Return to stop.")
await player.play(url)

for try await _ in FileHandle.standardInput.bytes.lines { break }

await player.stop()
printer.cancel()
