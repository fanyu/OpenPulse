import CloudKit
import CryptoKit
import Foundation
import Security

actor DeskSnapshotPublisher {
    private static let sharedContainerIdentifier = "iCloud.com.fanyu.openpulse"
    private static let sharedKeyValueKey = "deskSnapshot.current"

    private let saveRecord: (@Sendable (CKRecord) async throws -> Void)?
    private let publishStore: DeskSnapshotPublishStore
    private let keyValueStore: NSUbiquitousKeyValueStore
    private let now: @Sendable () -> Date

    init(
        database: CKDatabase? = nil,
        saveRecord: (@Sendable (CKRecord) async throws -> Void)? = nil,
        publishStore: DeskSnapshotPublishStore = DeskSnapshotPublishStore(),
        keyValueStore: NSUbiquitousKeyValueStore = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        if let saveRecord {
            self.saveRecord = saveRecord
        } else if let database {
            self.saveRecord = { record in
                _ = try await database.save(record)
            }
        } else {
            self.saveRecord = nil
        }
        self.publishStore = publishStore
        self.keyValueStore = keyValueStore
        self.now = now
    }

    static func makeIfAvailable(
        publishStore: DeskSnapshotPublishStore = DeskSnapshotPublishStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> DeskSnapshotPublisher? {
        guard hasSharedContainerEntitlement || hasKeyValueStoreEntitlement else { return nil }
        return DeskSnapshotPublisher(
            database: hasCloudKitEntitlement
                ? CKContainer(identifier: sharedContainerIdentifier).privateCloudDatabase
                : nil,
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

        do {
            let data = try DeskSnapshotJSONCodec.encode(snapshot)
            keyValueStore.set(data, forKey: Self.sharedKeyValueKey)
            keyValueStore.synchronize()
            await markPublished(hash: hash)
        } catch {
            await AppLogger.shared.warning("[desk-snapshot] key-value publish failed: \(error.localizedDescription)")
            return
        }

        guard let saveRecord else { return }

        do {
            let record = DeskSnapshotRecordCodec.makeRecord(snapshot: snapshot, zoneID: nil)
            try await saveRecord(record)
        } catch {
            await AppLogger.shared.warning("[desk-snapshot] cloudkit publish failed: \(error.localizedDescription)")
        }
    }

    private func markPublished(hash: String) async {
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

    private static var hasSharedContainerEntitlement: Bool {
        let entitlement = "com.apple.developer.icloud-container-identifiers" as CFString
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement, nil) else {
            return false
        }
        guard let identifiers = value as? [String] else { return false }
        return identifiers.contains(sharedContainerIdentifier)
    }

    private static var hasKeyValueStoreEntitlement: Bool {
        let entitlement = "com.apple.developer.ubiquity-kvstore-identifier" as CFString
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement, nil) else {
            return false
        }
        return value is String
    }
}

actor DeskSnapshotPublishDebouncer {
    private let delay: Duration
    private let operation: @Sendable () async -> Void
    private var pendingTask: Task<Void, Never>?

    init(
        delay: Duration,
        operation: @escaping @Sendable () async -> Void
    ) {
        self.delay = delay
        self.operation = operation
    }

    func schedule() {
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}
