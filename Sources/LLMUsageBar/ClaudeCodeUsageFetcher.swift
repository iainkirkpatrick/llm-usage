import Foundation

protocol ClaudeCodeUsageFetching: Sendable {
    func identity(profile: ClaudeAccountProfile) async throws -> ClaudeOwnerAuthObservation
    func fetch(profile: ClaudeAccountProfile, force: Bool) async throws -> ClaudeCodeUsageSnapshot
}

actor ClaudeCodeUsageFetcher: ClaudeCodeUsageFetching {
    typealias IdentityRunner = @Sendable (ClaudeAccountProfile) async throws -> ClaudeOwnerAuthObservation
    typealias UsageRunner = @Sendable (ClaudeAccountProfile) async throws -> ClaudeCodeUsageSnapshot

    private struct Entry {
        var snapshot: ClaudeCodeUsageSnapshot?
        var successAt: Date?
        var failureAt: Date?
        var running: Task<ClaudeCodeUsageSnapshot, Error>?
    }

    private var entries: [String: Entry] = [:]
    private let identityRunner: IdentityRunner
    private let usageRunner: UsageRunner
    private let now: @Sendable () -> Date
    private let interval: TimeInterval

    init(identityRunner: @escaping IdentityRunner = { try await ClaudeOwnerUsageProbe.observeIdentity(profile: $0) },
         usageRunner: @escaping UsageRunner = { ClaudeCodeUsageSnapshot(result: try await ClaudeOwnerUsageProbe.run(profile: $0)) },
         cacheInterval: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identityRunner = identityRunner
        self.usageRunner = usageRunner
        self.interval = max(0, cacheInterval)
        self.now = now
    }

    func identity(profile: ClaudeAccountProfile) async throws -> ClaudeOwnerAuthObservation {
        try Task.checkCancellation()
        let observation = try await identityRunner(profile)
        try Task.checkCancellation()
        return observation
    }

    func fetch(profile: ClaudeAccountProfile, force: Bool = false) async throws -> ClaudeCodeUsageSnapshot {
        try Task.checkCancellation()
        let key = ClaudeCredentials.serviceName(for: profile)
        var entry = entries[key] ?? Entry()
        // Join in-flight work even for forced callers, before consulting either cache.
        if let running = entry.running {
            let snapshot = try await running.value
            try Task.checkCancellation()
            return snapshot
        }
        let time = now()
        if !force, let snapshot = entry.snapshot, let successAt = entry.successAt,
           time.timeIntervalSince(successAt) < interval {
            try Task.checkCancellation()
            return snapshot
        }
        if !force, let failureAt = entry.failureAt, time.timeIntervalSince(failureAt) < interval {
            throw ClaudeCodeUsageFetcherError.backoff
        }
        let runner = usageRunner
        let task = Task { try await runner(profile) }
        entry.running = task
        entries[key] = entry
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            entry = entries[key] ?? Entry()
            entry.running = nil
            entry.snapshot = snapshot
            entry.successAt = now()
            entry.failureAt = nil
            entries[key] = entry
            return snapshot
        } catch {
            entry = entries[key] ?? Entry()
            entry.running = nil
            // Failed refreshes invalidate this fetcher's success cache. AppState's
            // separately-held last-known snapshot remains untouched.
            entry.snapshot = nil
            entry.successAt = nil
            entry.failureAt = now()
            entries[key] = entry
            throw error
        }
    }
}

enum ClaudeCodeUsageFetcherError: Error, LocalizedError, Sendable {
    case backoff
    var errorDescription: String? { "Claude Code usage checks are temporarily paused. Please try again later." }
}
