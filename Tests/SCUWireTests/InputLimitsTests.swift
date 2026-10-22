import Testing

@testable import SCUWire

/// 输入上限与客户端等待上限必须来自同一组常量：历史上两者各写各的，
/// 10,000 字符在 30 秒超时下必然被截断。
@Suite struct InputLimitsTests {
    @Test func typeTextTimeoutUsesThePerCharacterCost() {
        // 短输入受下限保护，不因为字符少就过早超时。
        #expect(scuTypeTextTimeoutMs(characterCount: 0) == Int32(scuInputTimeoutFloorMs))
        #expect(scuTypeTextTimeoutMs(characterCount: 100) == Int32(scuInputTimeoutFloorMs))

        // 上限字符数必须覆盖逐字间隔，且不超过上限。
        let atLimit = scuTypeTextTimeoutMs(characterCount: scuMaxInputTextLength)
        #expect(atLimit >= Int32(scuMaxInputTextLength * scuInputPerCharacterMs))
        #expect(atLimit <= Int32(scuInputTimeoutCeilingMs))

        // 异常/超大输入被夹到上限，负数按 0 处理。
        #expect(scuTypeTextTimeoutMs(characterCount: 1_000_000) == Int32(scuInputTimeoutCeilingMs))
        #expect(scuTypeTextTimeoutMs(characterCount: -5) == Int32(scuInputTimeoutFloorMs))
    }
}
