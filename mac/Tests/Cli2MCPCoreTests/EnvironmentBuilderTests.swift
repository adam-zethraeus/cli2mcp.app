import XCTest
@testable import Cli2MCPCore

final class EnvironmentBuilderTests: XCTestCase {
    func testAllPassthroughForwardsEveryParentValueAndOverridesWin() {
        let parent = [
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "AWS_SECRET_ACCESS_KEY": "leak-me"
        ]

        let env = EnvironmentBuilder.build(
            passthrough: .all,
            overrides: ["EXTRA": "1", "PATH": "/override"],
            parent: parent
        )

        XCTAssertEqual(env["PATH"], "/override")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["AWS_SECRET_ACCESS_KEY"], "leak-me")
        XCTAssertEqual(env["EXTRA"], "1")
    }

    func testNonePassthroughForwardsOnlyOverrides() {
        let parent = [
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "AWS_SECRET_ACCESS_KEY": "leak-me"
        ]

        let env = EnvironmentBuilder.build(
            passthrough: .none,
            overrides: ["EXTRA": "1"],
            parent: parent
        )

        XCTAssertEqual(env, ["EXTRA": "1"])
    }

    func testSafePassthroughForwardsEssentialsAndLCDynamicKeys() {
        let parent = [
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "USER": "me",
            "LOGNAME": "me",
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
            "TZ": "UTC",
            "LANG": "en_US.UTF-8",
            "LANGUAGE": "en",
            "TMPDIR": "/tmp/dir",
            "TMP": "/tmp",
            "TEMP": "/tmp",
            "PWD": "/work",
            "LC_ALL": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "AWS_SECRET_ACCESS_KEY": "leak-me",
            "GITHUB_TOKEN": "ghp_leak",
            "OPENAI_API_KEY": "sk-leak"
        ]

        let env = EnvironmentBuilder.build(
            passthrough: .safe,
            overrides: [:],
            parent: parent
        )

        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["USER"], "me")
        XCTAssertEqual(env["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(env["LC_CTYPE"], "UTF-8")
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(env["GITHUB_TOKEN"])
        XCTAssertNil(env["OPENAI_API_KEY"])
    }

    func testSafePassthroughAppliesOverridesAfterFiltering() {
        let env = EnvironmentBuilder.build(
            passthrough: .safe,
            overrides: ["GITHUB_TOKEN": "operator-supplied", "PATH": "/custom/bin"],
            parent: ["PATH": "/usr/bin", "GITHUB_TOKEN": "drop-me"]
        )

        XCTAssertEqual(env["PATH"], "/custom/bin")
        XCTAssertEqual(env["GITHUB_TOKEN"], "operator-supplied")
    }

    func testParseEnvPairsSplitsOnFirstEqualsDropsEmptyKeysAndPreservesEqualsInValues() {
        let env = EnvironmentBuilder.parseEnvPairs([
            "FOO=bar",
            "=drop",
            "NO_EQUALS",
            "URL=https://example.test?a=b&c=d",
            "EMPTY=",
            "FOO=last"
        ])

        XCTAssertEqual(env["FOO"], "last")
        XCTAssertEqual(env["URL"], "https://example.test?a=b&c=d")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertNil(env[""])
        XCTAssertNil(env["NO_EQUALS"])
    }

    func testShellEnvironmentParserParsesNULDelimitedEntries() {
        let data = Data("PATH=/usr/bin\0HOME=/Users/me\0LANG=C.UTF-8\0".utf8)

        XCTAssertEqual(
            ShellEnvironmentCapture.parseEnvOutput(data),
            [
                "PATH": "/usr/bin",
                "HOME": "/Users/me",
                "LANG": "C.UTF-8"
            ]
        )
    }

    func testShellEnvironmentParserFiltersGarbageAndInvalidKeys() {
        let data = Data(
            "Welcome to my shell!\nGOOD=ok\0BAD KEY=nope\0BAD-KEY=nope\01BAD=nope\0VALID_2=ok\0_AlsoValid=ok\0".utf8
        )

        XCTAssertEqual(
            ShellEnvironmentCapture.parseEnvOutput(data),
            [
                "GOOD": "ok",
                "VALID_2": "ok",
                "_AlsoValid": "ok"
            ]
        )
    }

    func testShellEnvironmentParserPreservesValuesContainingEqualsAndNewlines() {
        let data = Data("TOKEN=value=with=equals\0MULTILINE=line1\nline2\nline3\0NEXT=ok\0".utf8)

        XCTAssertEqual(ShellEnvironmentCapture.parseEnvOutput(data)["TOKEN"], "value=with=equals")
        XCTAssertEqual(ShellEnvironmentCapture.parseEnvOutput(data)["MULTILINE"], "line1\nline2\nline3")
        XCTAssertEqual(ShellEnvironmentCapture.parseEnvOutput(data)["NEXT"], "ok")
    }
}
