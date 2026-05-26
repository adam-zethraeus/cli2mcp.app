import XCTest
@testable import Cli2MCPCore

final class InputValidatorTests: XCTestCase {
    func testAcceptsValidGeneratedSchemaInput() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeFlags)
        let result = InputValidator.validate(
            ["verbose": .bool(true), "output": .string("out.txt"), "count": .number(5)],
            against: schema
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.errors, [])
    }

    func testRejectsAdditionalProperties() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeFlags)
        let result = InputValidator.validate(["unknown": .string("x")], against: schema)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.errors.first?.path, "(root)")
        XCTAssertEqual(result.errors.first?.message, "must NOT have additional properties (saw 'unknown')")
    }

    func testRejectsWrongScalarTypes() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeFlags)
        let result = InputValidator.validate(
            ["verbose": .string("not-a-boolean"), "output": .bool(false), "count": .string("5")],
            against: schema
        )

        XCTAssertEqual(
            result.errors,
            [
                ValidationFailure(path: "/verbose", message: "must be boolean"),
                ValidationFailure(path: "/output", message: "must be string"),
                ValidationFailure(path: "/count", message: "must be number")
            ]
        )
    }

    func testRejectsOutOfEnumChoiceValues() {
        let schema = InputSchemaBuilder.schema(for: Self.choiceShape)
        let result = InputValidator.validate(["format": .string("yaml")], against: schema)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.errors, [ValidationFailure(path: "/format", message: #"must be one of: "json", "text""#)])
    }

    func testRejectsOutOfEnumRepeatableChoiceValues() {
        let schema = InputSchemaBuilder.schema(
            for: CLIShape(
                description: "",
                flags: [FlagSpec(long: "format", type: .choice(["json", "text"]), description: "", repeatable: true)],
                positionals: []
            )
        )
        let result = InputValidator.validate(["format": .array([.string("yaml")])], against: schema)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.errors, [ValidationFailure(path: "/format/0", message: #"must be one of: "json", "text""#)])
    }

    func testRejectsWrongArrayAndArrayItemTypes() {
        let schema = InputSchemaBuilder.schema(for: Self.repeatableShape)

        XCTAssertEqual(
            InputValidator.validate(["include": .string("*.swift")], against: schema).errors,
            [ValidationFailure(path: "/include", message: "must be array")]
        )
        XCTAssertEqual(
            InputValidator.validate(["include": .array([.string("*.swift"), .bool(true)])], against: schema).errors,
            [ValidationFailure(path: "/include/1", message: "must be string")]
        )
    }

    func testRejectsNonObjectRoot() {
        let schema = InputSchemaBuilder.schema(for: Self.shapeFlags)
        let result = InputValidator.validate(.array([]), against: schema)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.errors, [ValidationFailure(path: "(root)", message: "must be object")])
    }

    func testFormatValidationErrorsMatchesPublishedOutput() {
        XCTAssertEqual(InputValidator.formatValidationErrors([]), "input did not match the published schema")
        XCTAssertEqual(
            InputValidator.formatValidationErrors([
                ValidationFailure(path: "(root)", message: "must NOT have additional properties (saw 'x')"),
                ValidationFailure(path: "/format", message: #"must be one of: "json", "text""#)
            ]),
            #"(root) must NOT have additional properties (saw 'x'); /format must be one of: "json", "text""#
        )
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

    private static let choiceShape = CLIShape(
        description: "",
        flags: [FlagSpec(long: "format", type: .choice(["json", "text"]), description: "", repeatable: false)],
        positionals: []
    )

    private static let repeatableShape = CLIShape(
        description: "",
        flags: [FlagSpec(long: "include", type: .string, description: "", repeatable: true)],
        positionals: []
    )
}
