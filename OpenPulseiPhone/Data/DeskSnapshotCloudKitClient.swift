import CloudKit
import Foundation

struct DeskSnapshotCloudKitClient {
    private static let sharedContainerIdentifier = "iCloud.com.fanyu.openpulse"

    var fetchCurrent: @Sendable () async throws -> DeskSnapshot? = {
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
