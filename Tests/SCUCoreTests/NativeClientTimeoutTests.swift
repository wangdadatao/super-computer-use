import Testing

@testable import SCUCore
@testable import SCUWire

/// 超时语义按“请求是否可能已执行”区分：
/// 读失败可以立即重试；动作失败可能已经点击/输入，必须先重读状态。
@Suite struct NativeClientTimeoutTests {
    @Test func readTimeoutIsImmediatelyRetryable() {
        let e = NativeClient.timeoutError(actionMayHaveStarted: false, timeoutMs: 30_000)
        #expect(e.code == "platform_unavailable")
        #expect(e.layer == "platform")
        #expect(e.retry == "immediate")
    }

    @Test func actionTransportFailureAfterWriteIsOutcomeUnknown() {
        let e = NativeClient.transportError(
            .closed, actionMayHaveStarted: true, requestWasWritten: true)
        #expect(e.code == "action_outcome_unknown")
        #expect(e.retry == "after_refresh")
        #expect(e.message.contains("动作请求已写出"))
    }

    @Test func actionTransportFailureBeforeWriteIsImmediatelyRetryable() {
        let e = NativeClient.transportError(
            .closed, actionMayHaveStarted: true, requestWasWritten: false)
        #expect(e.code == "platform_unavailable")
        #expect(e.retry == "immediate")
    }

    @Test func actionTimeoutRequiresAFreshRead() {
        let e = NativeClient.timeoutError(actionMayHaveStarted: true, timeoutMs: 30_000)
        #expect(e.code == "action_outcome_unknown")
        #expect(e.layer == "platform")
        #expect(e.retry == "after_refresh")
        #expect(e.message.contains("可能已经执行"))
    }
}
