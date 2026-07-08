import CloudKit
import CryptoKit
import Foundation
import Security

actor DeskSnapshotPublisher {
    private let database: CKDatabase?
    private let publishStore: DeskSnapshotPublishStore
    private let now: @Sendable () -> Date

    init(
        database: CKDatabase? = nil,
        publishStore: DeskSnapshotPublishStore = DeskSnapshotPublishStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.publishStore = publishStore
        self.now = now
    }

    static func makeIfAvailable(
        publishStore: DeskSnapshotPublishStore = DeskSnapshotPublishStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> DeskSnapshotPublisher? {
        guard hasCloudKitEntitlement else { return nil }
        return DeskSnapshotPublisher(
            database: CKContainer.default().privateCloudDatabase,
            publishStore: publishStore,
            now: now
        )
    }

    func shouldPublish(hash: String) async -> Bool {
        let publishedAt = now()
        guard let state = await publishStore.load() else { return true }
        if state.lastHash != hash { return true }
        return publishedAt.timeIntervalSince(state.lastPublishedAt) >= 30
    }

    func publishIfNeeded(
        codexAccounts: [CodexAccountSnapshot],
        claudeUsage: ClaudeUsageResponse?,
        fallbackQuotas: [QuotaRecord]
    ) async {
        guard let snapshot = DeskSnapshotBuilder.build(
            now: now(),
            codexAccounts: codexAccounts,
            claudeUsage: claudeUsage,
            fallbackQuotas: fallbackQuotas
        ) else {
            return
        }

        await publishIfNeeded(snapshot: snapshot)
    }

    func publishIfNeeded(snapshot: DeskSnapshot) async {
        let hash = snapshotHash(snapshot)
        guard await shouldPublish(hash: hash) else { return }
        guard let database else { return }

        do {
            let record = DeskSnapshotRecordCodec.makeRecord(snapshot: snapshot, zoneID: nil)
            _ = try await database.save(record)
            await markPublished(hash: hash)
        } catch {
            await AppLogger.shared.warning("[desk-snapshot] publish failed: \(error.localizedDescription)")
        }
    }

    func markPublished(hash: String) async {
        await publishStore.save(.init(
            lastHash: hash,
            lastPublishedAt: now()
        ))
    }

    private func snapshotHash(_ snapshot: DeskSnapshot) -> String {
        struct HashPayload: Codable {
            let snapshotID: String
            let sourceDeviceID: String
            let schemaVersion: Int
            let codex: DeskToolSnapshot
            let claude: DeskToolSnapshot
        }

        let payload = HashPayload(
            snapshotID: snapshot.snapshotID,
            sourceDeviceID: snapshot.sourceDeviceID,
            schemaVersion: snapshot.schemaVersion,
            codex: snapshot.codex,
            claude: snapshot.claude
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var hasCloudKitEntitlement: Bool {
        let entitlement = "com.apple.developer.icloud-services" as CFString
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement, nil) else {
            return false
        }
        guard let services = value as? [String] else { return false }
        return services.contains("CloudKit")
    }
}
