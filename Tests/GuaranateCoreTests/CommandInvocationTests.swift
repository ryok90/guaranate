import XCTest

@testable import GuaranateCore

final class CommandInvocationTests: XCTestCase {
    func testSplitsExecutableFromArguments() throws {
        let invocation = try CommandInvocation(argv: ["npm", "test", "--watch"])
        XCTAssertEqual(invocation.executable, "npm")
        XCTAssertEqual(invocation.arguments, ["test", "--watch"])
        XCTAssertEqual(invocation.argv, ["npm", "test", "--watch"])
    }

    /// The argument parser keeps a user-typed `--`; the child must never see it.
    func testStripsOneLeadingSeparator() throws {
        let invocation = try CommandInvocation(argv: ["--", "./build.sh", "--release"])
        XCTAssertEqual(invocation.executable, "./build.sh")
        XCTAssertEqual(invocation.argv, ["./build.sh", "--release"])
    }

    /// Only the *first* separator is ours; a second one belongs to the command.
    func testKeepsLaterSeparators() throws {
        let invocation = try CommandInvocation(argv: ["--", "git", "log", "--", "path"])
        XCTAssertEqual(invocation.argv, ["git", "log", "--", "path"])
    }

    func testRejectsEmptyCommand() {
        XCTAssertThrowsError(try CommandInvocation(argv: [])) { error in
            XCTAssertEqual(error as? CommandInvocationError, .empty)
        }
        XCTAssertThrowsError(try CommandInvocation(argv: ["--"])) { error in
            XCTAssertEqual(error as? CommandInvocationError, .empty)
        }
    }

    func testDisplayNameQuotesArgumentsContainingSpaces() throws {
        let invocation = try CommandInvocation(argv: ["sh", "-c", "echo hello"])
        XCTAssertEqual(invocation.displayName, "sh -c \"echo hello\"")
    }

    func testAssertionReasonNamesTheCommand() throws {
        let invocation = try CommandInvocation(argv: ["pnpm", "build"])
        XCTAssertEqual(invocation.assertionReason, "while: pnpm build")
    }

    /// Long build commands must not turn `pmset -g assertions` into a wall of text.
    func testAssertionReasonIsTruncated() throws {
        let invocation = try CommandInvocation(argv: ["cmd"] + Array(repeating: "argument", count: 40))
        let reason = invocation.assertionReason
        XCTAssertTrue(reason.hasPrefix("while: cmd argument"))
        XCTAssertTrue(reason.hasSuffix("…"))
        XCTAssertEqual(reason.count, "while: ".count + 96)
    }
}
