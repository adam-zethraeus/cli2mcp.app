import XCTest
@testable import Cli2MCPCore

final class HelpParserTests: XCTestCase {
    func testEmptyInputReturnsShapeWithVariadicArgsPositional() {
        let shape = HelpParser.extractShape("")

        XCTAssertEqual(shape.flags, [])
        XCTAssertEqual(shape.positionals, [PositionalSpec(name: "args", description: "", variadic: true)])
        XCTAssertEqual(shape.description, "")
    }

    func testUnparseableHelpReturnsVariadicArgsFallback() {
        let shape = HelpParser.extractShape("@@@ %%% !!!\n\n...")

        XCTAssertEqual(shape.positionals, [PositionalSpec(name: "args", description: "", variadic: true)])
    }

    func testBooleanFlagWithoutValueHint() throws {
        let help = [
            "my-tool - does things",
            "",
            "Usage: my-tool [options]",
            "",
            "Options:",
            "  -v, --verbose         print verbose output"
        ].joined(separator: "\n")

        let flag = try XCTUnwrap(HelpParser.extractShape(help).flags.first { $0.long == "verbose" })
        XCTAssertEqual(flag.short, "v")
        XCTAssertEqual(flag.type, .boolean)
        XCTAssertTrue(flag.description.localizedCaseInsensitiveContains("verbose"))
        XCTAssertFalse(flag.repeatable)
    }

    func testFlagWithAngleValueHintGetsNonBooleanType() throws {
        let shape = HelpParser.extractShape("Options:\n      --config <path>     path to config file")
        let flag = try XCTUnwrap(shape.flags.first { $0.long == "config" })

        XCTAssertEqual(flag.type, .string)
    }

    func testFlagWithEqualsValueStylePairsShortAndLong() throws {
        let shape = HelpParser.extractShape("Options:\n    -f PATTERNFILE, --file=PATTERNFILE    pattern file")
        let flag = try XCTUnwrap(shape.flags.first { $0.long == "file" })

        XCTAssertEqual(flag.short, "f")
        XCTAssertEqual(flag.type, .string)
    }

    func testRepeatableDetectedFromDescriptionWording() throws {
        let help = "Options:\n  -e, --regexp <pat>    pattern; can be provided multiple times"
        let flag = try XCTUnwrap(HelpParser.extractShape(help).flags.first { $0.long == "regexp" })

        XCTAssertTrue(flag.repeatable)
    }

    func testSameLineDescriptionDropsLaterAlignedColumns() throws {
        let help = "Options:\n  --format <kind>    output format    default: text"
        let flag = try XCTUnwrap(HelpParser.extractShape(help).flags.first { $0.long == "format" })

        XCTAssertEqual(flag.description, "output format")
    }

    func testDescriptionIsFirstNarrativeLine() {
        let help = [
            "Usage: foo [options]",
            "",
            "Foo frobs the widgets and returns them.",
            "",
            "Options:",
            "  --x   do x"
        ].joined(separator: "\n")

        XCTAssertEqual(HelpParser.extractShape(help).description, "Foo frobs the widgets and returns them.")
    }

    func testPositionalsExtractedFromUsageLine() {
        let help = [
            "Usage: jq [options] <filter> [file...]",
            "",
            "Options:",
            "  -n  null input"
        ].joined(separator: "\n")

        let shape = HelpParser.extractShape(help)
        XCTAssertTrue(shape.positionals.contains(PositionalSpec(name: "filter", description: "", variadic: false)))
        XCTAssertTrue(shape.positionals.contains(PositionalSpec(name: "file", description: "", variadic: true)))
    }

    func testCRLFLineEndingsAreNormalized() throws {
        let help = "Usage: x [opts]\r\n\r\nOptions:\r\n  -v, --verbose   be loud\r\n"
        let flag = try XCTUnwrap(HelpParser.extractShape(help).flags.first { $0.long == "verbose" })

        XCTAssertEqual(flag.short, "v")
    }

    func testJqHelpFixture() throws {
        let shape = HelpParser.extractShape(try fixture("jq"))

        XCTAssertTrue(shape.description.localizedCaseInsensitiveContains("JSON"))

        let longs = Set(shape.flags.map(\.long))
        for expected in [
            "null-input",
            "raw-input",
            "slurp",
            "compact-output",
            "raw-output",
            "sort-keys",
            "tab",
            "indent",
            "arg",
            "argjson",
            "exit-status",
            "version",
            "help"
        ] {
            XCTAssertTrue(longs.contains(expected), "missing flag --\(expected)")
        }

        XCTAssertEqual(shape.flags.first { $0.long == "slurp" }?.short, "s")
        XCTAssertEqual(shape.flags.first { $0.long == "slurp" }?.type, .boolean)
        XCTAssertNotEqual(shape.flags.first { $0.long == "indent" }?.type, .boolean)
    }

    func testRgHelpFixture() throws {
        let shape = HelpParser.extractShape(try fixture("rg"))

        let longs = Set(shape.flags.map(\.long))
        for expected in ["regexp", "file", "ignore-case", "invert-match", "files"] {
            XCTAssertTrue(longs.contains(expected), "missing flag --\(expected)")
        }

        XCTAssertEqual(shape.flags.first { $0.long == "regexp" }?.short, "e")
        XCTAssertNotEqual(shape.flags.first { $0.long == "regexp" }?.type, .boolean)
        XCTAssertEqual(shape.flags.first { $0.long == "regexp" }?.repeatable, true)
    }

    func testCurlHelpFixture() throws {
        let shape = HelpParser.extractShape(try fixture("curl"))

        let longs = Set(shape.flags.map(\.long))
        for expected in ["append", "basic", "cacert", "cert", "compressed", "cookie"] {
            XCTAssertTrue(longs.contains(expected), "missing flag --\(expected)")
        }

        XCTAssertEqual(shape.flags.first { $0.long == "append" }?.short, "a")
        XCTAssertEqual(shape.flags.first { $0.long == "append" }?.type, .boolean)
        XCTAssertNotEqual(shape.flags.first { $0.long == "cacert" }?.type, .boolean)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/Help"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
