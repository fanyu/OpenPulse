import CloudKit
import Foundation

struct DeskSnapshotCloudKitClient {
    private static let sharedContainerIdentifier = "iCloud.com.fanyu.openpulse"
    private static let sharedKeyValueKey = "deskSnapshot.current"

    var fetchCurrent: @Sendable () async throws -> DeskSnapshot? = {
        let keyValueStore = NSUbiquitousKeyValueStore.default
        keyValueStore.synchronize()
        if let data = keyValueStore.data(forKey: sharedKeyValueKey) {
            return try DeskSnapshotJSONCodec.decode(data)
        }

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
