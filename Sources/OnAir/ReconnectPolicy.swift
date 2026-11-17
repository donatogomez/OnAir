import Foundation

/// How long to wait before each reconnection attempt, and when to give up.
///
/// The delay grows exponentially from ``initialDelay`` by ``multiplier`` and is capped at ``maxDelay``.
public struct ReconnectPolicy: Sendable, Equatable {
    public var initialDelay: Duration
    public var multiplier: Double
    public var maxDelay: Duration
    /// `nil` retries forever, which suits a 24/7 station. `0` never retries.
    public var maxAttempts: Int?

    public init(
        initialDelay: Duration = .seconds(1),
        multiplier: Double = 2,
        maxDelay: Duration = .seconds(30),
        maxAttempts: Int? = nil
    ) {
        precondition(initialDelay >= .zero, "initialDelay must not be negative")
        precondition(multiplier >= 1, "multiplier must be at least 1")
        precondition(maxAttempts.map { $0 >= 0 } ?? true, "maxAttempts must not be negative")
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// 1 s, 2 s, 4 s… up to 30 s, forever.
    public static let `default` = ReconnectPolicy()

    /// Fail on the first error.
    public static let never = ReconnectPolicy(maxAttempts: 0)

    /// The wait before reconnection attempt `attempt` (1-based), or `nil` when the policy gives up.
    public func delay(forAttempt attempt: Int) -> Duration? {
        precondition(attempt >= 1, "attempt is 1-based")
        if let maxAttempts, attempt > maxAttempts { return nil }
        let seconds = initialDelay.seconds * pow(multiplier, Double(attempt - 1))
        return seconds >= maxDelay.seconds ? maxDelay : .seconds(seconds)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
