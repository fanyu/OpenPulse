import Foundation

struct DeskSnapshotPublishState: Codable, Equatable {
    let lastHash: String
    let lastPublishedAt: Date
}

actor DeskSnapshotPublishStore {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = "deskSnapshot.publish.state") {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> DeskSnapshotPublishState? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeskSnapshotPublishState.self, from: data)
    }

    func save(_ state: DeskSnapshotPublishState) {
        userDefaults.set(try? JSONEncoder().encode(state), forKey: key)
    }
}
