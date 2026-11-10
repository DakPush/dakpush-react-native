import Foundation

/// The JSON the SDK sends and saves: the device state compares by value, and
/// a null stays a null (a plain Swift dictionary drops it).
enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    /// A number with a fraction (in-app trigger values); whole numbers are
    /// [int].
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(_ value: String?) {
        self = value.map { .string($0) } ?? .null
    }

    init(_ value: Int?) {
        self = value.map { .int($0) } ?? .null
    }

    init(_ tags: [String: String]) {
        self = .object(tags.mapValues { .string($0) })
    }

    /// From what JSONSerialization reads. Whole numbers are [int], others
    /// [double].
    init(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                if d.isFinite, d.rounded() == d, abs(d) < 9.0e15 { self = .int(Int(d)) } else { self = .double(d) }
            } else {
                self = .int(n.intValue)
            }
        case let list as [Any]: self = .array(list.map(JSON.init(any:)))
        case let map as [String: Any]: self = .object(map.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let n): return n
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .array(let list): return list.map(\.any)
        case .object(let map): return map.mapValues(\.any)
        }
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var int: Int? {
        if case .int(let n) = self { return n }
        return nil
    }

    /// A whole number or one with a fraction.
    var number: Double? {
        switch self {
        case .int(let n): return Double(n)
        case .double(let d): return d
        default: return nil
        }
    }

    var array: [JSON]? {
        if case .array(let list) = self { return list }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let map) = self { return map }
        return nil
    }

    /// An object's string values; others are skipped.
    var stringMap: [String: String] {
        (object ?? [:]).compactMapValues(\.string)
    }

    static func encode(_ object: [String: JSON]) -> Data {
        // Only JSON values go in, so this cannot fail.
        (try? JSONSerialization.data(withJSONObject: JSON.object(object).any, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The object in [data], or nil when it is not a JSON object.
    static func decodeObject(_ data: Data) -> [String: JSON]? {
        guard let any = try? JSONSerialization.jsonObject(with: data), any is [String: Any] else { return nil }
        return JSON(any: any).object
    }
}
