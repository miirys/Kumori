import Foundation

/// A loose view over decoded JSON, for services whose answers change shape between versions.
struct J {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    init(data: Data) { self.init(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }

    init(text: String) { self.init(data: Data(text.utf8)) }

    subscript(key: String) -> J { J((raw as? [String: Any])?[key]) }

    subscript(index: Int) -> J {
        guard let a = raw as? [Any], a.indices.contains(index) else { return J(nil) }
        return J(a[index])
    }

    var exists: Bool { raw != nil }

    var isObject: Bool { raw is [String: Any] }

    var array: [J] { (raw as? [Any])?.map { J($0) } ?? [] }

    /// A string, or a number written out. Empty strings and "null" count as missing.
    var string: String? {
        let s: String?
        if let v = raw as? String { s = v } else if let n = raw as? NSNumber { s = n.stringValue } else { s = nil }
        guard let s, !s.isEmpty, s != "null" else { return nil }
        return s
    }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    var bool: Bool? { (raw as? NSNumber)?.boolValue }

    /// The first element when this is a list of strings, or the string itself.
    var firstString: String? { string ?? self[0].string }
}

func jsonData(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

func jsonString(_ object: Any) -> String { String(decoding: jsonData(object), as: UTF8.self) }
