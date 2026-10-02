import XCTest
@testable import EdgeSync

final class ShellTests: XCTestCase {
    func testFindsGit() {
        XCTAssertNotNil(Shell.find("git"))
        XCTAssertNil(Shell.find("definitely-not-a-tool-xyz"))
    }

    func testCapturesStdoutAndStatus() async {
        let r = await Shell.run("git", ["--version"])
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.stdout.hasPrefix("git version"))
    }

    func testMissingToolIsAnError() async {
        let r = await Shell.run("definitely-not-a-tool-xyz", [])
        XCTAssertEqual(r.status, 127)
        XCTAssertTrue(r.errorLine.contains("not found"))
    }

    func testFailureReportsLastStderrLine() async {
        let r = await Shell.run("git", ["rev-parse", "--verify", "nope"], cwd: URL(fileURLWithPath: "/"))
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.errorLine.isEmpty)
    }

    func testTimeoutTerminatesProcess() async {
        let start = Date()
        let r = await Shell.run("/bin/sh", ["-c", "sleep 10"], timeout: 1)
        XCTAssertEqual(r.status, -1)
        XCTAssertTrue(r.errorLine.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testTimeoutEscalatesToKillWhenTermIgnored() async {
        let start = Date()
        let r = await Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 10"], timeout: 1)
        XCTAssertEqual(r.status, -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testSignalDeathIsNotReportedAsTimeout() async {
        let r = await Shell.run("/bin/sh", ["-c", "kill -TERM $$"])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertNotEqual(r.status, -1)
        XCTAssertFalse(r.errorLine.contains("timed out"))
    }

    func testOrphanedGrandchildDoesNotHang() async {
        let start = Date()
        let r = await Shell.run("/bin/sh", ["-c", "sleep 30 & echo started"])
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.stdout.contains("started"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testLargeOutputDoesNotDeadlock() async {
        let r = await Shell.run(
            "/bin/sh",
            ["-c", "head -c 2000000 /dev/zero | tr '\\0' x; head -c 2000000 /dev/zero | tr '\\0' y 1>&2"]
        )
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.stdout.count, 2_000_000)
        XCTAssertEqual(r.stderr.count, 2_000_000)
    }
}
