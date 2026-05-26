import Foundation

public struct MCPServerInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPServerCapabilities: Codable, Equatable, Sendable {
    public var tools: [String: JSONValue]?

    public init(tools: [String: JSONValue]? = [:]) {
        self.tools = tools
    }
}

public struct MCPInitializeResult: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var capabilities: MCPServerCapabilities
    public var serverInfo: MCPServerInfo

    public init(
        protocolVersion: String,
        capabilities: MCPServerCapabilities,
        serverInfo: MCPServerInfo
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

public struct MCPTool: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONSchema

    public init(name: String, description: String, inputSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPListToolsResult: Codable, Equatable, Sendable {
    public var tools: [MCPTool]

    public init(tools: [MCPTool]) {
        self.tools = tools
    }
}

public struct MCPTextContentBlock: Codable, Equatable, Sendable {
    public var type: String
    public var text: String

    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

public struct MCPCallToolResult: Codable, Equatable, Sendable {
    public var content: [MCPTextContentBlock]
    public var isError: Bool?

    public init(content: [MCPTextContentBlock], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }
}
