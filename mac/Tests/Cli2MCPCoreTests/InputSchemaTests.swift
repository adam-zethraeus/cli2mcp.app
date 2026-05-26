import XCTest
@testable import Cli2MCPCore

final class InputSchemaTests: XCTestCase {
    func testBooleanStringAndNumberFlagsMapToSchemaProperties() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeFlags)

        XCTAssertEqual(schema.type, "object")
        XCTAssertFalse(schema.additionalProperties)
        XCTAssertEqual(schema.properties["verbose"], JSONSchemaProperty(type: "boolean", description: "Enable verbose output"))
        XCTAssertEqual(schema.properties["output"], JSONSchemaProperty(type: "string", description: "Output file path"))
        XCTAssertEqual(schema.properties["count"], JSONSchemaProperty(type: "number", description: "Number of results"))
        XCTAssertNil(schema.properties["args"])
    }

    func testStdinPropertyIsAlwaysPresentAsOptionalString() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeFlags)

        XCTAssertEqual(
            schema.properties["stdin"],
            JSONSchemaProperty(
                type: "string",
                description: "Text piped to the child process via standard input."
            )
        )
        XCTAssertTrue(InputValidator.validate(["stdin": .string("hello")], against: schema).ok)
        XCTAssertTrue(InputValidator.validate([:], against: schema).ok)
    }

    func testChoiceAndRepeatableFlagsMapToSchemaProperties() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeChoiceRepeat)

        XCTAssertEqual(
            schema.properties["format"],
            JSONSchemaProperty(
                type: "string",
                description: "Output format",
                enum: ["json", "text", "csv"]
            )
        )
        XCTAssertEqual(
            schema.properties["include"],
            JSONSchemaProperty(
                type: "array",
                description: "Include pattern",
                items: JSONSchemaArrayItem(type: "string")
            )
        )
        XCTAssertEqual(
            schema.properties["args"],
            JSONSchemaProperty(type: "array", items: JSONSchemaArrayItem(type: "string"))
        )

        XCTAssertTrue(InputValidator.validate(["format": .string("json"), "include": .array([.string("*.ts")]), "args": .array([.string("a.txt")])], against: schema).ok)
        XCTAssertFalse(InputValidator.validate(["format": .string("invalid")], against: schema).ok)
    }

    func testRepeatableChoicePreservesEnumValidationForEachArrayItem() {
        let schema = InputSchemaBuilder.schema(
            for: CLIShape(
                description: "",
                flags: [
                    FlagSpec(
                        long: "format",
                        type: .choice(["json", "text"]),
                        description: "Output format",
                        repeatable: true
                    )
                ],
                positionals: []
            )
        )

        XCTAssertEqual(
            schema.properties["format"],
            JSONSchemaProperty(
                type: "array",
                description: "Output format",
                items: JSONSchemaArrayItem(type: "string", enum: ["json", "text"])
            )
        )
        XCTAssertTrue(InputValidator.validate(["format": .array([.string("json"), .string("text")])], against: schema).ok)
        XCTAssertFalse(InputValidator.validate(["format": .array([.string("yaml")])], against: schema).ok)
    }

    func testFallbackPositionalsProduceArgsArray() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeFallback)

        XCTAssertEqual(
            schema.properties["args"],
            JSONSchemaProperty(type: "array", items: JSONSchemaArrayItem(type: "string"))
        )
        XCTAssertTrue(InputValidator.validate(["args": .array([.string(".")])], against: schema).ok)
        XCTAssertTrue(InputValidator.validate([:], against: schema).ok)
    }

    func testSchemaEncodingPreservesPublishedShapeWithoutRequired() throws {
        let schema = InputSchemaBuilder.schema(for: Self.shapeChoiceRepeat)
        let data = try JSONEncoder().encode(schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "object")
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        XCTAssertNotNil(object["properties"])
        XCTAssertNil(object["required"])
    }

    private static let shapeFlags = CLIShape(
        description: "A CLI tool",
        flags: [
            FlagSpec(long: "verbose", type: .boolean, description: "Enable verbose output", repeatable: false),
            FlagSpec(long: "output", short: "o", type: .string, description: "Output file path", repeatable: false),
            FlagSpec(long: "count", type: .number, description: "Number of results", repeatable: false)
        ],
        positionals: []
    )

    private static let shapeChoiceRepeat = CLIShape(
        description: "Another tool",
        flags: [
            FlagSpec(long: "format", type: .choice(["json", "text", "csv"]), description: "Output format", repeatable: false),
            FlagSpec(long: "include", type: .string, description: "Include pattern", repeatable: true)
        ],
        positionals: [PositionalSpec(name: "files", description: "Input files", variadic: true)]
    )

    private static let shapeFallback = CLIShape(
        description: "",
        flags: [],
        positionals: [PositionalSpec(name: "args", description: "", variadic: true)]
    )
}
