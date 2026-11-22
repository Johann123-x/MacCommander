import AppKit
import Testing
@testable import MacCommander

@MainActor
final class CommandLineTests {
    let cmd = Commander(view: TerminalView(fontSize: 16))

    // `async` functions can suspend at `await` (≈ a non-blocking wait); while this test waits, the main thread
    // is free to run the output and termination callbacks that `execute` queues there.
    /// Runs `line` in the shell and waits until the Commander reports the command as finished.
    private func run(_ line: String, timeout: Double = 5) async throws -> [String] {
        cmd.execute(line)
        let start = Date()
        while cmd.running != nil && Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(cmd.running == nil, "command did not finish within \(timeout) s")
        // The console lines after the echoed command line.
        let echoed = try #require(cmd.console.lastIndex { $0.hasSuffix(">" + line) })
        return Array(cmd.console[(echoed + 1)...])
    }

    @Test func outputAndExitCode() async throws {
        #expect(try await run("echo one; echo two; exit 3") == ["one", "two", "[exit code 3]"])
    }

    @Test func outputArrivingAfterTheShellExitedComesBeforeTheExitCode() async throws {
        // The subshell keeps writing after the main shell has exited. This used to print "late" after the summary.
        let out = try await run("(sleep 0.3; echo late) & echo early; exit 2")
        #expect(out == ["early", "late", "[exit code 2]"])
    }

    @Test func backgroundJobHoldingTheOutputOpenDoesNotBlock() async throws {
        let start = Date()
        let out = try await run("sleep 3 & echo started")
        #expect(out == ["started"])
        #expect(Date().timeIntervalSince(start) < 2.5)
    }
}
