import Foundation
import SQLite

/// Parses OpenCode (SST) data from ~/.local/share/opencode/opencode.db
actor OpenCodeParser {
    private let dataDir: URL

    init(dataDir: URL = .homeDirectory.appending(path: ".local/share/opencode")) {
        self.dataDir = dataDir
    }

    // MARK: - Sessions

    func parseSessions(since date: Date? = nil) async throws -> [ToolSession] {
        let dbURL = dataDir.appending(path: "opencode.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        return (try? parseSessions(from: dbURL, since: date)) ?? []
    }

    private func parseSessions(from dbURL: URL, since date: Date?) throws -> [ToolSession] {
        let db = try Connection(.uri(dbURL.path, parameters: [.immutable(true), .mode(.readOnly)]))

        guard let sessionRows = try? db.prepare(
            "SELECT id, title, time_created, directory FROM session WHERE time_archived IS NULL"
        ) else { return [] }

        var sessions: [ToolSession] = []
        for row in sessionRows {
            guard let sessionId = row[0] as? String else { continue }
            let title   = row[1] as? String ?? ""
            let timeMs  = row[2] as? Int64  ?? 0
            let dir     = row[3] as? String ?? ""
            let startDate = Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000)

            if let cutoff = date, startDate < cutoff { continue }

            var inputTokens  = 0
            var outputTokens = 0
            var cacheRead    = 0
            var cacheWrite   = 0
            var model        = ""

            if let msgRows = try? db.prepare(
                "SELECT data FROM message WHERE session_id = ?", sessionId
            ) {
                for msgRow in msgRows {
                    guard let dataStr = msgRow[0] as? String,
                          let data = dataStr.data(using: .utf8),
                          let msg = try? JSONDecoder().decode(OpenCodeMessageData.self, from: data),
                          msg.role == "assistant" else { continue }
                    inputTokens  += msg.tokens?.input     ?? 0
                    outputTokens += msg.tokens?.output    ?? 0
                    cacheRead    += msg.tokens?.cache?.read  ?? 0
                    cacheWrite   += msg.tokens?.cache?.write ?? 0
                    if model.isEmpty, let m = msg.modelID, !m.isEmpty { model = m }
                }
            }

            sessions.append(ToolSession(
                id: stableUUID(from: sessionId),
                tool: .opencode,
                startedAt: startDate,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                taskDescription: String(title.prefix(300)),
                model: model,
                cwd: dir
            ))
        }
        return sessions
    }
}

// MARK: - Helpers

/// Creates a stable UUID from an arbitrary string (e.g. "ses_abc123").
private func stableUUID(from string: String) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    for (i, byte) in string.utf8.enumerated() { bytes[i % 16] ^= byte }
    return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                       bytes[4],  bytes[5],  bytes[6],  bytes[7],
                       bytes[8],  bytes[9],  bytes[10], bytes[11],
                       bytes[12], bytes[13], bytes[14], bytes[15]))
}

// MARK: - Response models

private struct OpenCodeMessageData: Decodable {
    let role: String?
    let modelID: String?
    let tokens: OpenCodeTokens?
}

private struct OpenCodeTokens: Decodable {
    let input: Int?
    let output: Int?
    let cache: OpenCodeCache?
}

private struct OpenCodeCache: Decodable {
    let read: Int?
    let write: Int?
}
