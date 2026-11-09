import Foundation
import XCTest
@testable import LLMUsageBar

final class ClaudeCodeUsageFetcherTests: XCTestCase {
    func testSuccessCachePreservesCapturedAtAndExpiresAtConfiguredTimestamp() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 123))
        let calls = CallCounter()
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in
            calls.increment(); return Self.snapshot(Double(calls.value))
        }, cacheInterval: 60, now: { clock.value })
        let profile = ClaudeAccountProfile(label: "Fixture")
        let first = try await fetcher.fetch(profile: profile)
        clock.advance(59)
        let cached = try await fetcher.fetch(profile: profile)
        XCTAssertEqual(first.capturedAt, cached.capturedAt)
        XCTAssertEqual(calls.value, 1)
        clock.advance(2)
        _ = try await fetcher.fetch(profile: profile)
        XCTAssertEqual(calls.value, 2)
    }

    func testForceRefreshBypassesCache() async throws {
        let calls = CallCounter()
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in calls.increment(); return Self.snapshot(Double(calls.value)) })
        let profile = ClaudeAccountProfile(label: "Fixture")
        _ = try await fetcher.fetch(profile: profile)
        let fresh = try await fetcher.fetch(profile: profile, force: true)
        XCTAssertEqual(fresh.capturedAt.timeIntervalSince1970, 2)
        XCTAssertEqual(calls.value, 2)
    }

    func testFailedForcedRefreshInvalidatesOldSuccessAndBacksOff() async throws {
        let calls = CallCounter()
        let clock = TestClock(Date(timeIntervalSince1970: 10))
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in
            calls.increment()
            if calls.value == 2 { throw TestFailure.failed }
            return Self.snapshot(1)
        }, cacheInterval: 60, now: { clock.value })
        let profile = ClaudeAccountProfile(label: "Fixture")
        _ = try await fetcher.fetch(profile: profile)
        do { _ = try await fetcher.fetch(profile: profile, force: true); XCTFail("expected failure") } catch {}
        do { _ = try await fetcher.fetch(profile: profile); XCTFail("backoff should not return stale success") }
        catch { XCTAssertTrue(error is ClaudeCodeUsageFetcherError) }
        XCTAssertEqual(calls.value, 2)
        clock.advance(61)
        _ = try await fetcher.fetch(profile: profile)
        XCTAssertEqual(calls.value, 3)
    }

    func testSameProfileCoalescesIncludingForcedCaller() async throws {
        let calls = CallCounter(), gate = AsyncGate()
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in
            calls.increment(); await gate.pause(); return Self.snapshot(1)
        })
        let profile = ClaudeAccountProfile(label: "Fixture")
        let first = Task { try await fetcher.fetch(profile: profile) }
        await gate.waitUntilEntered()
        let second = Task { try await fetcher.fetch(profile: profile, force: true) }
        try await Task.sleep(for: .milliseconds(30))
        await gate.open()
        _ = try await first.value; _ = try await second.value
        XCTAssertEqual(calls.value, 1)
    }

    func testProfilesAreIsolatedIncludingDefaultAndExplicitTilde() async throws {
        let calls = CallCounter()
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in calls.increment(); return Self.snapshot(Double(calls.value)) })
        for profile in [ClaudeAccountProfile(label: "default"),
                        ClaudeAccountProfile(label: "tilde", configDirectory: "~/.claude"),
                        ClaudeAccountProfile(label: "other", configDirectory: "/tmp/other-profile")] {
            _ = try await fetcher.fetch(profile: profile)
        }
        XCTAssertEqual(calls.value, 3)
        _ = try await fetcher.fetch(profile: ClaudeAccountProfile(label: "default"))
        XCTAssertEqual(calls.value, 3)
    }

    func testCancelledInitiatorCancelsRunner() async throws {
        let entered = AsyncGate(), stopped = CallCounter()
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in
            await entered.markEntered()
            do { try await Task.sleep(for: .seconds(30)) } catch { stopped.increment(); throw error }
            return Self.snapshot(1)
        })
        let task = Task { try await fetcher.fetch(profile: .init(label: "Fixture")) }
        await entered.waitUntilEntered()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled initiator") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(stopped.value, 1)
    }

    func testCancelledJoiningCallerDoesNotCancelSharedRunner() async throws {
        let entered = AsyncGate(), calls = CallCounter()
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in
            calls.increment(); await entered.markEntered(); try await Task.sleep(for: .milliseconds(100)); return Self.snapshot(1)
        })
        let profile = ClaudeAccountProfile(label: "Fixture")
        let owner = Task { try await fetcher.fetch(profile: profile) }
        await entered.waitUntilEntered()
        let joiner = Task { try await fetcher.fetch(profile: profile, force: true) }
        try await Task.sleep(for: .milliseconds(30))
        joiner.cancel()
        do { _ = try await joiner.value; XCTFail("cancelled joiner") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await owner.value
        XCTAssertEqual(calls.value, 1)
    }

    func testFailureBackoffUsesInjectedClock() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 20)), calls = CallCounter()
        let fetcher = ClaudeCodeUsageFetcher(usageRunner: { _ in calls.increment(); throw TestFailure.failed },
                                             cacheInterval: 30, now: { clock.value })
        let profile = ClaudeAccountProfile(label: "Fixture")
        for _ in 0..<2 {
            do { _ = try await fetcher.fetch(profile: profile, force: true); XCTFail() } catch {}
        }
        do { _ = try await fetcher.fetch(profile: profile); XCTFail("backoff") }
        catch { XCTAssertTrue(error is ClaudeCodeUsageFetcherError) }
        XCTAssertEqual(calls.value, 2)
        clock.advance(31)
        do { _ = try await fetcher.fetch(profile: profile); XCTFail() } catch {}
        XCTAssertEqual(calls.value, 3)
    }

    func testIdentityOnlySeamRunsAuthInTemporaryWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-claude")
        let script = "#!/bin/sh\n[ \"$1 $2 $3\" = \"auth status --json\" ] || exit 9\nprintf '%s' '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"email\":\"fixture@example.invalid\",\"orgId\":\"123e4567-e89b-42d3-a456-426614174000\"}'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let observation = try await ClaudeOwnerUsageProbe.observeIdentity(
            profile: .init(label: "Fixture"), executable: executable, environment: [:],
            workingDirectory: directory, timeout: 3)
        XCTAssertEqual(observation.email, "fixture@example.invalid")
    }

    private static func snapshot(_ time: Double) -> ClaudeCodeUsageSnapshot {
        let identity = ClaudeOwnerAuthObservation(email: "fixture@example.invalid",
            organizationID: "123e4567-e89b-42d3-a456-426614174000", authMethod: "claude.ai", apiProvider: "firstParty")
        return ClaudeCodeUsageSnapshot(identity: identity,
            usage: ClaudeCLIUsageReading(fiveHour: nil, weekly: nil, modelWindows: []),
            capturedAt: Date(timeIntervalSince1970: time))
    }
}

private enum TestFailure: Error { case failed }

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}

private actor AsyncGate {
    private var entered = false
    private var openFlag = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        enterWaiters.forEach { $0.resume() }; enterWaiters.removeAll()
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }
    func pause() async {
        markEntered()
        if openFlag { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func open() {
        openFlag = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
