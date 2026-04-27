import Foundation

/// Per-tool synchronization state. Replaces the single global `isSyncing` flag so
/// individual tools can refresh concurrently without blocking each other.
@MainActor
final class ToolSyncState: ObservableObject {
    private(set) var isRefreshing: Bool = false
    private(set) var lastSyncDate: Date?
    private(set) var lastError: String?          // surfaced error message (nil = OK)
    private(set) var lastErrorDate: Date?

    // Internal stale-detection guard.
    private var refreshStartedAt: Date?
    private static let staleThreshold: TimeInterval = 60

    var isStale: Bool {
        guard isRefreshing, let start = refreshStartedAt else { return false }
        return Date().timeIntervalSince(start) > Self.staleThreshold
    }

    /// Attempt to begin a refresh. Returns `false` when one is already running and not stale.
    func beginRefresh() -> Bool {
        if isRefreshing, !isStale { return false }
        isRefreshing = true
        refreshStartedAt = Date()
        return true
    }

    func endRefresh() {
        isRefreshing = false
        refreshStartedAt = nil
        lastSyncDate = Date()
    }

    func recordSuccess() {
        lastError = nil
        lastErrorDate = nil
    }

    func recordError(_ message: String) {
        lastError = message
        lastErrorDate = Date()
    }

    func clearError() {
        lastError = nil
        lastErrorDate = nil
    }
}

/// Aggregate view over all per-tool states. Views that need a single "is any tool syncing"
/// indicator use this instead of DataSyncService's per-tool map.
@MainActor
final class SyncStateMap {
    private var states: [Tool: ToolSyncState] = [:]

    init() {
        for tool in Tool.allCases {
            states[tool] = ToolSyncState()
        }
    }

    subscript(tool: Tool) -> ToolSyncState {
        states[tool]! // always present — initialised for every Tool case
    }

    var isAnySyncing: Bool {
        states.values.contains { $0.isRefreshing }
    }

    var lastSyncDate: Date? {
        states.values.compactMap(\.lastSyncDate).max()
    }

    var firstError: String? {
        states.values.compactMap(\.lastError).first
    }
}
