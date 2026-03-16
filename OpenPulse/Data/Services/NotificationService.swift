import UserNotifications
import Foundation

/// Sends local notifications when a tool's quota drops below a threshold.
/// Throttles per-tool alerts to at most once per hour.
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    struct QuotaInfo {
        let fraction: Double
        let resetAt: Date?
    }

    private static let throttleInterval: TimeInterval = 3600  // 1 hour between alerts per tool

    /// Reads the user-configured threshold (notifications.threshold key, integer percent, default 10).
    private var threshold: Double {
        let pct = UserDefaults.standard.integer(forKey: "notifications.threshold")
        return Double(pct > 0 ? pct : 10) / 100.0
    }

    private var lastAlertDate: [String: Date] = [:]

    private init() {}

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Check & fire

    /// Call after every sync with the latest quota info per tool.
    func checkAndNotify(quotas: [String: QuotaInfo]) {
        guard UserDefaults.standard.bool(forKey: "notifications.enabled") else { return }

        for (toolRaw, info) in quotas {
            guard info.fraction < threshold else { continue }

            let now = Date()
            if let last = lastAlertDate[toolRaw], now.timeIntervalSince(last) < Self.throttleInterval { continue }
            lastAlertDate[toolRaw] = now

            let toolName = Tool(rawValue: toolRaw)?.displayName ?? toolRaw
            let pct = Int((info.fraction * 100).rounded())
            let body: String
            if let resetAt = info.resetAt, resetAt > now {
                body = "剩余 \(pct)%，约 \(countdownString(to: resetAt)) 后重置。"
            } else {
                body = "剩余 \(pct)%，请注意使用量。"
            }
            sendNotification(
                id: "quota-low-\(toolRaw)",
                title: "\(toolName) 配额不足",
                body: body
            )
        }
    }

    // MARK: - Private

    private func sendNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[OpenPulse] Notification error: \(error)") }
        }
    }
}
