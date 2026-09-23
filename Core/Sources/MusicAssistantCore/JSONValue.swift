import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = try .object(c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public func merging(_ fields: [String: JSONValue]) -> JSONValue {
        guard case let .object(values) = self else { return self }
        return .object(values.merging(fields) { _, new in new })
    }

    public subscript(_ key: String) -> JSONValue {
        if case let .object(v) = self {
            v[key] ?? .null
        } else {
            .null
        }
    }

    public var string: String? {
        if case let .string(v) = self {
            v
        } else {
            nil
        }
    }

    public var double: Double? {
        if case let .number(v) = self {
            v
        } else {
            nil
        }
    }

    public var bool: Bool? {
        if case let .bool(v) = self {
            v
        } else {
            nil
        }
    }

    public var array: [JSONValue] {
        if case let .array(v) = self {
            v
        } else {
            []
        }
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

public enum MAError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case let .message(text): text }
    }
}
