import Foundation

enum DeskSnapshotJSONCodec {
    static func encode(_ snapshot: DeskSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    static func decode(_ data: Data) throws -> DeskSnapshot {
        try JSONDecoder().decode(DeskSnapshot.self, from: data)
    }
}
