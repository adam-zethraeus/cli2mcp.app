import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct JSONSchemaArrayItem: Codable, Equatable, Sendable {
    public var type: String
    public var `enum`: [String]?

    public init(type: String, enum: [String]? = nil) {
        self.type = type
        self.enum = `enum`
    }
}

public struct JSONSchemaProperty: Codable, Equatable, Sendable {
    public var type: String
    public var description: String?
    public var `enum`: [String]?
    public var items: JSONSchemaArrayItem?

    public init(
        type: String,
        description: String? = nil,
        enum: [String]? = nil,
        items: JSONSchemaArrayItem? = nil
    ) {
        self.type = type
        self.description = description
        self.enum = `enum`
        self.items = items
    }
}

public struct JSONSchema: Codable, Equatable, Sendable {
    public var type: String
    public var properties: [String: JSONSchemaProperty]
    public var additionalProperties: Bool
    var propertyOrder: [String]

    public init(
        type: String = "object",
        properties: [String: JSONSchemaProperty],
        additionalProperties: Bool = false,
        propertyOrder: [String]? = nil
    ) {
        self.type = type
        self.properties = properties
        self.additionalProperties = additionalProperties
        self.propertyOrder = propertyOrder ?? Array(properties.keys)
    }

    public static func == (lhs: JSONSchema, rhs: JSONSchema) -> Bool {
        lhs.type == rhs.type
            && lhs.properties == rhs.properties
            && lhs.additionalProperties == rhs.additionalProperties
    }

    enum CodingKeys: String, CodingKey {
        case type
        case properties
        case additionalProperties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        properties = try container.decode([String: JSONSchemaProperty].self, forKey: .properties)
        additionalProperties = try container.decode(Bool.self, forKey: .additionalProperties)
        propertyOrder = Array(properties.keys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(properties, forKey: .properties)
        try container.encode(additionalProperties, forKey: .additionalProperties)
    }
}

public enum InputSchemaBuilder {
    public static func schema(for shape: CLIShape) -> JSONSchema {
        var properties: [String: JSONSchemaProperty] = [:]
        var order: [String] = []

        for flag in shape.flags {
            properties[flag.long] = buildFlagProperty(flag)
            order.append(flag.long)
        }

        if !shape.positionals.isEmpty {
            properties["args"] = JSONSchemaProperty(type: "array", items: JSONSchemaArrayItem(type: "string"))
            order.append("args")
        }

        properties["stdin"] = JSONSchemaProperty(
            type: "string",
            description: "Text piped to the child process via standard input."
        )
        order.append("stdin")

        return JSONSchema(properties: properties, additionalProperties: false, propertyOrder: order)
    }
}

private extension InputSchemaBuilder {
    static func buildFlagProperty(_ flag: FlagSpec) -> JSONSchemaProperty {
        if flag.repeatable {
            return JSONSchemaProperty(
                type: "array",
                description: flag.description.nilIfEmpty,
                items: arrayItem(for: flag)
            )
        }

        return scalarProperty(for: flag)
    }

    static func scalarProperty(for flag: FlagSpec) -> JSONSchemaProperty {
        switch flag.type {
        case .boolean:
            return JSONSchemaProperty(type: "boolean", description: flag.description.nilIfEmpty)
        case .number:
            return JSONSchemaProperty(type: "number", description: flag.description.nilIfEmpty)
        case .string:
            return JSONSchemaProperty(type: "string", description: flag.description.nilIfEmpty)
        case .choice(let choices):
            return JSONSchemaProperty(type: "string", description: flag.description.nilIfEmpty, enum: choices)
        }
    }

    static func arrayItem(for flag: FlagSpec) -> JSONSchemaArrayItem {
        switch flag.type {
        case .boolean:
            return JSONSchemaArrayItem(type: "boolean")
        case .number:
            return JSONSchemaArrayItem(type: "number")
        case .string:
            return JSONSchemaArrayItem(type: "string")
        case .choice(let choices):
            return JSONSchemaArrayItem(type: "string", enum: choices)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
