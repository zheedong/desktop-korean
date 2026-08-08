import Foundation

// JSON-RPC 2.0 프로토콜 타입입니다(https://www.jsonrpc.org/specification).
//
// 설계 판단:
// - params / result는 임의의 JSON이며, 서드파티 AnyCodable을 들이지 않도록 이 파일의 `JSONValue`로 표현합니다.
// - id는 규격에 따라 int / string / null을 허용합니다. 이 클라이언트는 int만 직접 사용하지만 string/null도 해석할 수 있습니다.
// - batch 호출은 구분하지 않습니다(아직 필요하지 않음). 지원이 필요해지면 `[JSONRPCResponse]` 디코딩 분기를 추가하면 됩니다.

public enum JSONRPC {
    public static let version = "2.0"
}

// MARK: - JSONValue

/// 임의의 JSON 값입니다.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        // Int을 Double보다 먼저 시도합니다. 순수한 정수는 .int로 해석됩니다.
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    /// 임의의 Encodable을 JSONValue로 변환합니다(JSONEncoder/Decoder를 한 번 거칩니다).
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// JSONValue를 구체적인 타입으로 디코딩합니다.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - ID

/// JSON-RPC id입니다. 규격에서 Number / String / Null을 허용합니다.
public enum JSONRPCID: Hashable, Sendable {
    case int(Int)
    case string(String)
    case null
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "JSON-RPC id must be number, string, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - Request / Notification

/// 발신 요청입니다. `id == nil`이면 Notification을 뜻하며, 규격에 따라 `id` 필드 자체를 인코딩하지 않습니다.
public struct JSONRPCRequest: Encodable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?
    public let id: JSONRPCID?

    public init(method: String, params: JSONValue?, id: JSONRPCID?) {
        self.jsonrpc = JSONRPC.version
        self.method = method
        self.params = params
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params, id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(method, forKey: .method)
        if let params { try c.encode(params, forKey: .params) }
        if let id { try c.encode(id, forKey: .id) }
    }
}

// MARK: - Response

public struct JSONRPCResponse: Decodable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCError?
}

public struct JSONRPCError: Codable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public extension JSONRPCError {
    // 규격에서 예약한 오류 코드입니다. -32000..-32099는 구현별 사용자 정의용으로 남겨져 있습니다.
    static let parseError      = -32700
    static let invalidRequest  = -32600
    static let methodNotFound  = -32601
    static let invalidParams   = -32602
    static let internalError   = -32603
}

// MARK: - 클라이언트 측 오류

public enum PluginClientError: Error, Sendable {
    /// 자식 프로세스가 시작되지 않았거나 이미 종료되었습니다.
    case notRunning
    /// 자식 프로세스가 예기치 않게 종료되었으며, 종료 코드가 함께 전달됩니다.
    case processTerminated(Int32)
    /// 응답 id가 대기 중인 어떤 요청과도 일치하지 않습니다.
    case unknownResponseID(JSONRPCID?)
    /// call 한 건의 대기 시간이 초과되었습니다.
    case timeout
    /// 디코딩에 실패했습니다.
    case decodingFailed(String)
}
