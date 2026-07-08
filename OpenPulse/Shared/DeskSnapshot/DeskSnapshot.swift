import Foundation

struct DeskSnapshot: Codable, Equatable, Sendable {
    let snapshotID: String
    let sourceDeviceID: String
    let schemaVersion: Int
    let updatedAt: Date
    let codex: DeskToolSnapshot
    let claude: DeskToolSnapshot
}

struct DeskToolSnapshot: Codable, Equatable, Sendable {
    let tool: Tool
    let displayLabel: String
    let remaining: Int?
    let total: Int?
    let fraction: Double?
    let resetAt: Date?
    let status: DeskQuotaStatus
    let petState: DeskPetState
}
