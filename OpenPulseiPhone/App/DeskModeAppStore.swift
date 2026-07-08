import Foundation
import Observation

@MainActor
@Observable
final class DeskModeAppStore {
    var snapshot: DeskSnapshot?
    var statusText = "Waiting for Mac"

    private let client: DeskSnapshotCloudKitClient
    private let now: @Sendable () -> Date

    var codexPresentation: DeskPetPresentation? {
        guard let snapshot else { return nil }
        return DeskPetPresentation.make(from: snapshot.codex, now: now())
    }

    var claudePresentation: DeskPetPresentation? {
        guard let snapshot else { return nil }
        return DeskPetPresentation.make(from: snapshot.claude, now: now())
    }

    init(
        client: DeskSnapshotCloudKitClient = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.now = now
    }

    func refresh() async {
        do {
            snapshot = try await client.fetchCurrent()
            statusText = snapshot == nil ? "Waiting for Mac" : "Synced just now"
        } catch {
            statusText = "Cloud sync unavailable"
        }
    }
}
