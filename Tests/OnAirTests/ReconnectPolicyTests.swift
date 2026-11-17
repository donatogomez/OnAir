import Testing
import OnAir

@Suite("ReconnectPolicy")
struct ReconnectPolicyTests {
    @Test func defaultPolicyDoublesFromOneSecond() {
        let delays = (1...5).map { ReconnectPolicy.default.delay(forAttempt: $0) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
    }

    @Test func delayIsCappedAtMaxDelay() {
        let policy = ReconnectPolicy.default
        #expect(policy.delay(forAttempt: 6) == .seconds(30))
        #expect(policy.delay(forAttempt: 10_000) == .seconds(30))
    }

    @Test func customInitialDelayAndMultiplier() {
        let policy = ReconnectPolicy(initialDelay: .milliseconds(500), multiplier: 3, maxDelay: .seconds(10))
        let delays = (1...4).map { policy.delay(forAttempt: $0) }
        #expect(delays == [.milliseconds(500), .milliseconds(1500), .milliseconds(4500), .seconds(10)])
    }

    @Test func givesUpAfterMaxAttempts() {
        let policy = ReconnectPolicy(maxAttempts: 2)
        #expect(policy.delay(forAttempt: 2) == .seconds(2))
        #expect(policy.delay(forAttempt: 3) == nil)
    }

    @Test func neverPolicyGivesUpImmediately() {
        #expect(ReconnectPolicy.never.delay(forAttempt: 1) == nil)
    }
}
