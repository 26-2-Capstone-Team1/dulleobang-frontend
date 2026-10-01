import Foundation

// 백엔드(Spring 등)가 ID 를 숫자(12)로 주든 문자열("12")로 주든 받아들이기 위한 property wrapper.
// 앱 안에서는 항상 String 으로 다룬다. 인코딩할 때는 문자열로 보낸다 (Jackson 은 "12" 를 Long 으로 자동 변환).

@propertyWrapper
struct FlexibleID: Codable, Hashable {
    var wrappedValue: String
    init(wrappedValue: String) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { wrappedValue = s; return }
        if let i = try? c.decode(Int64.self) { wrappedValue = String(i); return }
        if let d = try? c.decode(Double.self) { wrappedValue = FlexibleID.string(d); return }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath,
                                                            debugDescription: "ID 는 문자열 또는 숫자여야 합니다"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }

    static func string(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 9e15 ? String(Int64(d)) : String(d)
    }
}

@propertyWrapper
struct FlexibleOptionalID: Codable, Hashable {
    var wrappedValue: String?
    init(wrappedValue: String?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil; return }
        if let s = try? c.decode(String.self) { wrappedValue = s; return }
        if let i = try? c.decode(Int64.self) { wrappedValue = String(i); return }
        if let d = try? c.decode(Double.self) { wrappedValue = FlexibleID.string(d); return }
        wrappedValue = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
    }
}

/// ID 배열 (예: removedObjectIds). 숫자·문자열 섞여 와도 [String] 으로 받는다. 키가 없거나 null 이면 [].
@propertyWrapper
struct FlexibleIDs: Codable, Hashable {
    var wrappedValue: [String]
    init(wrappedValue: [String]) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = []; return }
        wrappedValue = try c.decode([FlexibleID].self).map(\.wrappedValue)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// 키가 아예 없어도 nil 로 받는다 (synthesized Codable 은 wrapper 타입에 decodeIfPresent 를 쓰지 않으므로 보완).
    func decode(_ type: FlexibleOptionalID.Type, forKey key: Key) throws -> FlexibleOptionalID {
        try decodeIfPresent(type, forKey: key) ?? FlexibleOptionalID(wrappedValue: nil)
    }

    func decode(_ type: FlexibleIDs.Type, forKey key: Key) throws -> FlexibleIDs {
        try decodeIfPresent(type, forKey: key) ?? FlexibleIDs(wrappedValue: [])
    }
}

extension KeyedEncodingContainer {
    /// nil 이면 키를 아예 쓰지 않는다
    mutating func encode(_ value: FlexibleOptionalID, forKey key: Key) throws {
        if let v = value.wrappedValue { try encode(v, forKey: key) }
    }
}

/// 목록 응답을 너그럽게 받는다: `[T]`, `{"listings":[T]}`, `{"data":[T]}`, `{"data":{"content":[T]}}`(Spring Page) 등.
/// 배열을 찾았는데 원소 디코딩이 실패하면 그 오류를 그대로 던져서 어느 필드가 문제인지 보이게 한다.
struct FlexibleList<T: Decodable>: Decodable {
    let items: [T]

    static var preferredKeys: [String] {
        ["data", "content", "items", "results", "listings", "furniture", "chats", "rooms",
         "objects", "placements", "messages", "scraps", "notifications"]
    }

    init(from decoder: Decoder) throws {
        if (try? decoder.unkeyedContainer()) != nil {
            items = try [T](from: decoder)
            return
        }
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let preferred = Self.preferredKeys
        for name in preferred {
            guard let k = AnyCodingKey(stringValue: name), c.contains(k) else { continue }
            if (try? c.decodeNil(forKey: k)) == true { items = []; return }
            if (try? c.nestedUnkeyedContainer(forKey: k)) != nil {
                items = try c.decode([T].self, forKey: k)
                return
            }
            if let nested = try? c.decode(FlexibleList<T>.self, forKey: k) { items = nested.items; return }
        }
        for k in c.allKeys where !preferred.contains(k.stringValue) {
            if let arr = try? c.decode([T].self, forKey: k) { items = arr; return }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "응답에서 목록을 찾지 못했습니다"))
    }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
