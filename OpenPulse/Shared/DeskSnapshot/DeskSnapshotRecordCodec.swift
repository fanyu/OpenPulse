import CloudKit
import Foundation

enum DeskSnapshotRecordCodec {
    static let recordType = "DeskSnapshot"
    static let recordName = "current"

    static func makeRecord(snapshot: DeskSnapshot, zoneID: CKRecordZone.ID?) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID ?? .default)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        let encoder = JSONEncoder()

        record["snapshotID"] = snapshot.snapshotID as CKRecordValue
        record["sourceDeviceID"] = snapshot.sourceDeviceID as CKRecordValue
        record["schemaVersion"] = snapshot.schemaVersion as CKRecordValue
        record["updatedAt"] = snapshot.updatedAt as CKRecordValue
        record["codexData"] = try? encoder.encode(snapshot.codex) as CKRecordValue
        record["claudeData"] = try? encoder.encode(snapshot.claude) as CKRecordValue
        return record
    }

    static func decode(_ record: CKRecord) throws -> DeskSnapshot {
        let decoder = JSONDecoder()
        return DeskSnapshot(
            snapshotID: record["snapshotID"] as? String ?? "current",
            sourceDeviceID: record["sourceDeviceID"] as? String ?? "unknown",
            schemaVersion: record["schemaVersion"] as? Int ?? 1,
            updatedAt: record["updatedAt"] as? Date ?? .distantPast,
            codex: try decoder.decode(DeskToolSnapshot.self, from: recordData(record["codexData"])),
            claude: try decoder.decode(DeskToolSnapshot.self, from: recordData(record["claudeData"]))
        )
    }

    private static func recordData(_ value: CKRecordValueProtocol?) -> Data {
        if let data = value as? Data {
            return data
        }
        if let data = value as? NSData {
            return Data(referencing: data)
        }
        return Data()
    }
}
