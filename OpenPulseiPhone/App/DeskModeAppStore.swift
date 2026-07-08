import Observation

@MainActor
@Observable
final class DeskModeAppStore {
    var snapshot: DeskSnapshot?
    var statusText = "Waiting for Mac"

    private let client: DeskSnapshotCloudKitClient

    init(client: DeskSnapshotCloudKitClient = .init()) {
        self.client = client
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
