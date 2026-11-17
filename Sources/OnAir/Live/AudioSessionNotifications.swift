#if os(iOS)
import AVFoundation

/// ``AudioSessionEventSource`` backed by `AVAudioSession` notifications. iOS only:
/// macOS has no `AVAudioSession`.
public struct AudioSessionNotifications: AudioSessionEventSource {
    public init() {}

    public func events() -> AsyncStream<AudioSessionEvent> {
        AsyncStream { continuation in
            let task = Task {
                let center = NotificationCenter.default
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await note in center.notifications(named: AVAudioSession.interruptionNotification) {
                            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                            switch type.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
                            case .began:
                                continuation.yield(.interruptionBegan)
                            case .ended:
                                let resume = AVAudioSession.InterruptionOptions(rawValue: options ?? 0).contains(.shouldResume)
                                continuation.yield(.interruptionEnded(shouldResume: resume))
                            default:
                                break
                            }
                        }
                    }
                    group.addTask {
                        for await note in center.notifications(named: AVAudioSession.routeChangeNotification) {
                            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                            // Only losing the active output stops playback; new routes and our own
                            // category changes are ignored.
                            if reason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable {
                                continuation.yield(.outputDeviceLost)
                            }
                        }
                    }
                    group.addTask {
                        for await _ in center.notifications(named: AVAudioSession.mediaServicesWereResetNotification) {
                            continuation.yield(.mediaServicesReset)
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
