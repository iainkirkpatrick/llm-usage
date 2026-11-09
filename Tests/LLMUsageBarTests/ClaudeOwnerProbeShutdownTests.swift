import Darwin
import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeOwnerProbeShutdownTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func fixture() throws -> Process {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-probe-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec /bin/sleep 30"]
        process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    func testStopAllRejectsFutureLaunches() throws {
        let registry = ClaudeOwnerProbeProcessRegistry()
        defer { registry.stopAll() }
        let running = try fixture()
        let lease = try ClaudeOwnerProbeProcess(running, registry: registry)
        registry.stopAll()
        XCTAssertFalse(running.isRunning)

        let late = try fixture()
        XCTAssertThrowsError(try ClaudeOwnerProbeProcess(late, registry: registry)) {
            XCTAssertEqual($0 as? ClaudeOwnerUsageProbeError, .launchFailed)
        }
        XCTAssertEqual(late.processIdentifier, 0, "Shutdown must reject before Process.run")
        lease.cleanup()
    }

    func testCleanupAndDeinitAfterStopDoNotTerminateTwice() throws {
        let calls = Counter()
        let registry = ClaudeOwnerProbeProcessRegistry(terminateRoot: {
            calls.increment()
            ProcessTreeTermination.terminate(root: $0, grace: 0.1)
        })
        defer { registry.stopAll() }
        let process = try fixture()
        var lease: ClaudeOwnerProbeProcess? = try ClaudeOwnerProbeProcess(process, registry: registry)
        registry.stopAll()
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(process.isRunning)
        lease?.cleanup()
        lease?.cleanup()
        lease = nil
        registry.stopAll()
        XCTAssertEqual(calls.value, 1, "Stale leases must not signal a potentially reused PID/group")
    }

    func testStopAllWaitsForClaimedCleanup() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cleanupFinished = DispatchSemaphore(value: 0)
        let stopAttempted = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let calls = Counter()
        let registry = ClaudeOwnerProbeProcessRegistry(terminateRoot: {
            calls.increment()
            entered.signal()
            // Bound fixture failure as well as ensuring the test can always release it.
            _ = release.wait(timeout: .now() + 10)
            ProcessTreeTermination.terminate(root: $0, grace: 0.1)
        })
        defer { release.signal(); registry.stopAll() }
        let process = try fixture()
        let lease = try ClaudeOwnerProbeProcess(process, registry: registry)
        DispatchQueue.global().async {
            lease.cleanup()
            cleanupFinished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            stopAttempted.signal()
            registry.stopAll()
            stopFinished.signal()
        }
        XCTAssertEqual(stopAttempted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.2), .timedOut,
                       "Shutdown must wait even after cleanup has removed its entry")
        XCTAssertTrue(process.isRunning, "The terminator is deliberately held before killing the root")
        release.signal()
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(process.isRunning, "Shutdown must include root reaping")
        lease.cleanup()
        registry.stopAll()
        XCTAssertEqual(calls.value, 1)
        XCTAssertNil(registry.launch(try fixture()), "Shutdown remains permanent after waiting")
    }
}
