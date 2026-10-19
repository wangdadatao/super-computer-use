import CoreGraphics
import Testing

@testable import SCUNative
@testable import SCUWire

/// 按键解析：键名、修饰键顺序、Shift 符号与拒绝语义（ADR-0016）。
@Suite struct InputTests {
    @Test func modifiersAreOrderIndependent() throws {
        let a = try AXBackend.parseKey("cmd+shift+t")
        let b = try AXBackend.parseKey("shift+cmd+t")
        #expect(a == b)
        #expect(a.code == 17)  // t
        #expect(a.flags.contains(.maskCommand))
        #expect(a.flags.contains(.maskShift))
    }

    @Test func commonKeysMapToVirtualCodes() throws {
        #expect(try AXBackend.parseKey("Return").code == 36)
        #expect(try AXBackend.parseKey("enter").code == 36)
        #expect(try AXBackend.parseKey("tab").code == 48)
        #expect(try AXBackend.parseKey("escape").code == 53)
    }

    @Test func plusRequiresShift() throws {
        let plus = try AXBackend.parseKey("cmd+plus")
        #expect(plus.code == 24)
        #expect(plus.flags.contains(.maskShift))
        #expect(plus.flags.contains(.maskCommand))
    }

    @Test func unknownKeyIsRefusedInsteadOfGuessed() {
        #expect(throws: WireError.self) { _ = try AXBackend.parseKey("cmd+unknownkey") }
    }

    @Test func multipleMainKeysAreRefused() {
        #expect(throws: WireError.self) { _ = try AXBackend.parseKey("a+b") }
    }

    @Test func emptyKeyIsRefused() {
        #expect(throws: WireError.self) { _ = try AXBackend.parseKey("   ") }
    }
}
