import Foundation
import Network

/// ``ConnectivityMonitor`` backed by `NWPathMonitor`.
///
/// Each call to ``updates()`` owns its own monitor, which is cancelled when the stream terminates,
/// so there is no shared state to synchronise.
public struct NetworkPathMonitor: ConnectivityMonitor {
    public init() {}

    public func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            // NWPathMonitor delivers on a dispatch queue; the stream turns that into async values.
            monitor.start(queue: DispatchQueue(label: "OnAir.NetworkPathMonitor", qos: .utility))
        }
    }
}
