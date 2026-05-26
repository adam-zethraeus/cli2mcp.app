import Foundation

public enum JSONRPCID: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or integer id")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var method: String
    public var params: JSONValue?

    public init(
        jsonrpc: String = "2.0",
        id: JSONRPCID,
        method: String,
        params: JSONValue? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var method: String
    public var params: JSONValue?

    public init(jsonrpc: String = "2.0", method: String, params: JSONValue? = nil) {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
    }
}

public struct JSONRPCErrorObject: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID?
    public var result: JSONValue?
    public var error: JSONRPCErrorObject?

    public init(
        jsonrpc: String = "2.0",
        id: JSONRPCID?,
        result: JSONValue? = nil,
        error: JSONRPCErrorObject? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: JSONRPCID, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result)
    }

    public static func failure(id: JSONRPCID?, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCErrorObject(code: code, message: message))
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        if try container.decodeNil(forKey: .id) {
            id = nil
        } else {
            id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        }
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

public enum JSONRPCIncomingMessage: Equatable, Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
}

extension JSONRPCIncomingMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.id), (try? container.decodeNil(forKey: .id)) != true {
            self = .request(try JSONRPCRequest(from: decoder))
        } else {
            self = .notification(try JSONRPCNotification(from: decoder))
        }
    }
}

public extension JSONValue {
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else {
            return nil
        }
        return object
    }

    var stringValue: String? {
        guard case .string(let string) = self else {
            return nil
        }
        return string
    }
}
