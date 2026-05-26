import XCTest
@testable import Cli2MCPCore

final class ArgvBuilderTests: XCTestCase {
    func testBooleanTrueBecomesFlag() {
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: ["verbose": .bool(true)]), ["--verbose"])
    }

    func testBooleanFalseIsOmitted() {
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: ["verbose": .bool(false)]), [])
    }

    func testStringFlagBecomesFlagValuePair() {
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: ["output": .string("out.txt")]), ["--output", "out.txt"])
    }

    func testNumberFlagBecomesFlagValuePair() {
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: ["count": .number(5)]), ["--count", "5"])
    }

    func testChoiceFlagBecomesFlagValuePair() {
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: ["format": .string("json")]), ["--format", "json"])
    }

    func testRepeatableStringArrayBecomesMultipleFlagValuePairs() {
        XCTAssertEqual(
            ArgvBuilder.build(shape: Self.baseShape, input: ["include": .array([.string("*.ts"), .string("*.js")])]),
            ["--include", "*.ts", "--include", "*.js"]
        )
    }

    func testRepeatableBooleanArrayEmitsFlagForEachTrueValue() {
        let shape = CLIShape(
            description: "",
            flags: [FlagSpec(long: "verbose", type: .boolean, description: "", repeatable: true)],
            positionals: Self.baseShape.positionals
        )

        XCTAssertEqual(
            ArgvBuilder.build(shape: shape, input: ["verbose": .array([.bool(true), .bool(false), .bool(true)])]),
            ["--verbose", "--verbose"]
        )
    }

    func testPositionalArgsArrayIsAppendedAfterSeparator() {
        XCTAssertEqual(
            ArgvBuilder.build(shape: Self.baseShape, input: ["verbose": .bool(true), "args": .array([.string("a.txt"), .string("b.txt")])]),
            ["--verbose", "--", "a.txt", "b.txt"]
        )
    }

    func testFlagsComeBeforePositionalsInShapeOrder() {
        XCTAssertEqual(
            ArgvBuilder.build(shape: Self.baseShape, input: ["args": .array([.string("x")]), "output": .string("o.txt")]),
            ["--output", "o.txt", "--", "x"]
        )
    }

    func testSeparatorPreventsFlagInjectionThroughPositionals() {
        XCTAssertEqual(
            ArgvBuilder.build(
                shape: Self.baseShape,
                input: ["args": .array([.string("--checkpoint-action=exec=sh"), .string("f.tar")])]
            ),
            ["--", "--checkpoint-action=exec=sh", "f.tar"]
        )
    }

    func testNoSeparatorEmittedWhenPositionalsAreEmptyOrAbsent() {
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: ["verbose": .bool(true)]), ["--verbose"])
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: ["verbose": .bool(true), "args": .array([])]), ["--verbose"])
    }

    func testEmptyInputYieldsEmptyArgv() {
        XCTAssertEqual(ArgvBuilder.build(shape: Self.baseShape, input: [:]), [])
    }

    func testUnknownInputKeysAreIgnored() {
        XCTAssertEqual(
            ArgvBuilder.build(shape: Self.baseShape, input: ["bogus": .string("x"), "verbose": .bool(true)]),
            ["--verbose"]
        )
    }

    private static let baseShape = CLIShape(
        description: "",
        flags: [
            FlagSpec(long: "verbose", type: .boolean, description: "", repeatable: false),
            FlagSpec(long: "output", short: "o", type: .string, description: "", repeatable: false),
            FlagSpec(long: "count", type: .number, description: "", repeatable: false),
            FlagSpec(long: "format", type: .choice(["json", "text"]), description: "", repeatable: false),
            FlagSpec(long: "include", type: .string, description: "", repeatable: true)
        ],
        positionals: [PositionalSpec(name: "files", description: "", variadic: true)]
    )
}
