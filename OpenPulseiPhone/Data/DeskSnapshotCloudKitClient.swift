import CloudKit
import Foundation

struct DeskSnapshotCloudKitClient: Sendable {
    private static let sharedContainerIdentifier = "iCloud.com.fanyu.openpulse"
    private static let sharedKeyValueKey = "deskSnapshot.current"

    enum FetchError: LocalizedError {
        case invalidKeyValueSnapshot
        case invalidKeyValueAndCloudKitUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidKeyValueSnapshot:
                return "The synced snapshot could not be read, and no CloudKit snapshot is available."
            case .invalidKeyValueAndCloudKitUnavailable:
                return "The synced snapshot could not be read, and CloudKit could not provide a replacement."
            }
        }
    }

    let fetchCurrent: @Sendable () async throws -> DeskSnapshot?

    init(fetchCurrent: @escaping @Sendable () async throws -> DeskSnapshot?) {
        self.fetchCurrent = fetchCurrent
    }

    init(
        readKeyValueData: @escaping @Sendable () -> Data? = Self.readKeyValueData,
        fetchCloudKitSnapshot: @escaping @Sendable () async throws -> DeskSnapshot? = Self.fetchCloudKitSnapshot
    ) {
        fetchCurrent = {
            var invalidKeyValueSnapshot = false
            if let data = readKeyValueData() {
                do {
                    return try DeskSnapshotJSONCodec.decode(data)
                } catch {
                    invalidKeyValueSnapshot = true
                }
            }

            do {
                if let snapshot = try await fetchCloudKitSnapshot() {
                    return snapshot
                }
            } catch {
                if invalidKeyValueSnapshot {
                    throw FetchError.invalidKeyValueAndCloudKitUnavailable
                }
                throw error
            }

            if invalidKeyValueSnapshot {
                throw FetchError.invalidKeyValueSnapshot
            }
            return nil
        }
    }

    private static func readKeyValueData() -> Data? {
        let keyValueStore = NSUbiquitousKeyValueStore.default
        keyValueStore.synchronize()
        return keyValueStore.data(forKey: sharedKeyValueKey)
    }

    private static func fetchCloudKitSnapshot() async throws -> DeskSnapshot? {
        let database = CKContainer(
            identifier: sharedContainerIdentifier
        ).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: DeskSnapshotRecordCodec.recordName)

        do {
            let record = try await database.record(for: recordID)
            return try DeskSnapshotRecordCodec.decode(record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
