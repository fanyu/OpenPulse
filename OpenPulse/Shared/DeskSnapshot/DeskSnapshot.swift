import Foundation

struct DeskSnapshot: Codable, Equatable, Sendable {
    let snapshotID: String
    let sourceDeviceID: String
    let schemaVersion: Int
    let updatedAt: Date
    let codex: DeskToolSnapshot
    let claude: DeskToolSnapshot
}

struct DeskQuotaWindowSnapshot: Codable, Equatable, Sendable {
    let label: String
    let remaining: Int?
    let total: Int?
    let fraction: Double?
    let resetAt: Date?
}

struct DeskToolSnapshot: Codable, Equatable, Sendable {
    let tool: Tool
    let displayLabel: String
    let remaining: Int?
    let total: Int?
    let fraction: Double?
    let resetAt: Date?
    let weekly: DeskQuotaWindowSnapshot?
    let status: DeskQuotaStatus
    let petState: DeskPetState

    var session: DeskQuotaWindowSnapshot {
        DeskQuotaWindowSnapshot(
            label: "5h Session",
            remaining: remaining,
            total: total,
            fraction: fraction,
            resetAt: resetAt
        )
    }
}
