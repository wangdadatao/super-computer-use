import Foundation
import SCUCore
import SCUWire

extension ScuTool {
    static func objectArguments(_ v: JSONValue?) throws -> [String: JSONValue] {
        guard let v, v != .null else { return [:] }
        guard case .object(let o) = v else { throw ArgumentError(message: "arguments 必须是对象") }
        return o
    }

    /// 拒绝未声明的参数：拼错的参数名被静默忽略，调用方会以为生效了。
    static func requireNoExtra(_ args: [String: JSONValue], allowed: Set<String>) throws {
        let extra = Set(args.keys).subtracting(allowed).sorted()
        if !extra.isEmpty { throw ArgumentError(message: "未知参数：\(extra.joined(separator: "、"))") }
    }

    static func string(_ args: [String: JSONValue], _ name: String) throws -> String? {
        guard let v = args[name] else { return nil }
        guard let s = v.stringValue else { throw ArgumentError(message: "参数 \(name) 必须是字符串") }
        // 空串等价于未给出：模型常把"不需要的可选参数"填成空串。
        return s.isEmpty ? nil : s
    }

    /// 与 `string` 相同，但保留空串——设值的空串是"清空这个字段"，是有意义的值。
    static func stringAllowingEmpty(_ args: [String: JSONValue], _ name: String) throws -> String? {
        guard let v = args[name] else { return nil }
        guard let s = v.stringValue else { throw ArgumentError(message: "参数 \(name) 必须是字符串") }
        return s
    }

    static func bool(_ args: [String: JSONValue], _ name: String) throws -> Bool? {
        guard let v = args[name] else { return nil }
        guard case .bool(let b) = v else { throw ArgumentError(message: "参数 \(name) 必须是布尔值") }
        return b
    }

    static func int(
        _ args: [String: JSONValue], _ name: String, range: ClosedRange<Int>, required: Bool
    ) throws -> Int? {
        guard let v = args[name] else {
            if required { throw ArgumentError(message: "缺少参数 \(name)") }
            return nil
        }
        guard let n = v.intValue else { throw ArgumentError(message: "参数 \(name) 必须是整数") }
        guard range.contains(n) else {
            throw ArgumentError(message: "参数 \(name) 必须在 \(range.lowerBound)...\(range.upperBound)")
        }
        return n
    }
}
