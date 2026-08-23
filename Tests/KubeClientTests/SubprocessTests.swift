import Foundation
import XCTest
import KubeClient

/// `Subprocess` is the valuable thing to test here: binary discovery via
/// `locate`, and the null-stdin/watchdog/kill defences every external tool
/// call goes through. Exercised against small real binaries (`/bin/echo`,
/// `/bin/sh`, `/bin/sleep`) rather than a cluster - nothing here talks to
/// kubectl or a network.
final class SubprocessTests: XCTestCase {
    func test_locate_returnsFirstExecutablePath() {
        XCTAssertEqual(Subprocess.locate(["/nonexistent/binary", "/bin/echo"]), "/bin/echo")
    }

    func test_locate_returnsNilWhenNothingExists() {
        XCTAssertNil(Subprocess.locate(["/nonexistent/one", "/nonexistent/two"]))
    }

    func test_run_capturesStdoutOnSuccess() async throws {
        let result = try await Subprocess.run(binary: "/bin/echo", args: ["hello"],
                                               timeout: 5, label: "echo", context: nil)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "hello\n")
    }

    func test_run_throwsFailedWithStderrOnNonZeroExit() async {
        do {
            _ = try await Subprocess.run(binary: "/bin/sh", args: ["-c", "echo boom 1>&2; exit 1"],
                                          timeout: 5, label: "sh", context: nil)
            XCTFail("expected Subprocess.run to throw on non-zero exit")
        } catch let KubectlError.failed(message) {
            XCTAssertEqual(message, "boom")
        } catch {
            XCTFail("expected KubectlError.failed, got \(error)")
        }
    }

    /// The watchdog is the backstop for a tool that overruns its own
    /// request timeout: a process still running at `timeout * 1.5` must be
    /// killed, not left to hang the caller forever.
    func test_run_watchdogKillsHungProcess() async {
        let start = Date()
        do {
            _ = try await Subprocess.run(binary: "/bin/sleep", args: ["30"],
                                          timeout: 1, label: "sleep", context: nil)
            XCTFail("expected Subprocess.run to throw once the watchdog kills the process")
        } catch let KubectlError.failed(message) {
            XCTAssertTrue(message.contains("timed out"), "expected a timeout message, got: \(message)")
        } catch {
            XCTFail("expected KubectlError.failed, got \(error)")
        }
        // Watchdog fires at timeout*1.5 (1.5s here); generous slack for CI
        // scheduling without turning this into an unbounded hang itself.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
