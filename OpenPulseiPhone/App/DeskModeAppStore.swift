import Foundation
import Observation

@MainActor
@Observable
final class DeskModeAppStore {
    var snapshot: DeskSnapshot?
    var statusText = "Waiting for Mac"

    private let client: DeskSnapshotCloudKitClient
    private let now: @Sendable () -> Date
    private var presentationDate: Date
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshFailed = false

    var codexPresentation: DeskPetPresentation? {
        guard let snapshot else { return nil }
        return DeskPetPresentation.make(
            from: snapshot.codex,
            now: presentationDate,
            snapshotUpdatedAt: snapshot.updatedAt
        )
    }

    var claudePresentation: DeskPetPresentation? {
        guard let snapshot else { return nil }
        return DeskPetPresentation.make(
            from: snapshot.claude,
            now: presentationDate,
            snapshotUpdatedAt: snapshot.updatedAt
        )
    }

    init(
        client: DeskSnapshotCloudKitClient = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.now = now
        presentationDate = now()
    }

    func tick(now: Date? = nil) {
        let now = now ?? self.now()
        presentationDate = now

        guard !refreshFailed else {
            statusText = "Cloud sync unavailable"
            return
        }

        guard let snapshot else {
            statusText = "Waiting for Mac"
            return
        }

        let age = max(0, Int(now.timeIntervalSince(snapshot.updatedAt)))
        statusText = age > 600 ? "Sync delayed" : "Synced \(age)s ago"
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor in
            defer { refreshTask = nil }

            do {
                if let fetched = try await client.fetchCurrent(),
                   snapshot.map({ fetched.updatedAt >= $0.updatedAt }) ?? true {
                    snapshot = fetched
                }
                refreshFailed = false
            } catch {
                refreshFailed = true
            }
            tick()
        }
        refreshTask = task
        await task.value
    }
}
