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
        let pct = defaults.integer(forKey: "notifications.threshold")
        return Double(pct > 0 ? min(pct, 100) : 10) / 100.0
    }

    private var lastAlertDate: [String: Date] = [:]
    private var pendingAlerts: Set<String> = []
    private let defaults: UserDefaults
    private let now: () -> Date
    private let deliver: (String, String, String) async throws -> Void

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        deliver: @escaping (String, String, String) async throws -> Void = { id, title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil)
            )
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.deliver = deliver
    }

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Check & fire

    /// Call after every sync with the latest quota info per tool.
    func checkAndNotify(quotas: [String: QuotaInfo]) {
        Task { await deliverQuotaNotifications(quotas: quotas) }
    }

    func deliverQuotaNotifications(quotas: [String: QuotaInfo]) async {
        guard defaults.bool(forKey: "notifications.enabled") else { return }

        for (toolRaw, info) in quotas {
            let date = now()
            guard info.fraction.isFinite, (0...1).contains(info.fraction),
                  info.fraction < threshold,
                  info.resetAt.map({ $0 > date }) != false,
                  !pendingAlerts.contains(toolRaw) else { continue }

            if let last = lastAlertDate[toolRaw], date.timeIntervalSince(last) < Self.throttleInterval { continue }
            pendingAlerts.insert(toolRaw)

            let toolName = Tool(rawValue: toolRaw)?.displayName ?? toolRaw
            let pct = Int((info.fraction * 100).rounded())
            let body: String
            if let resetAt = info.resetAt {
                body = String(localized: "剩余 \(pct)%，约 \(countdownString(to: resetAt)) 后重置。")
            } else {
                body = String(localized: "剩余 \(pct)%，请注意使用量。")
            }
            do {
                try await deliver("quota-low-\(toolRaw)", String(localized: "\(toolName) 配额不足"), body)
                lastAlertDate[toolRaw] = now()
            } catch {
                // A failed delivery can be retried on the next sync.
                print("[OpenPulse] Notification error: \(error)")
            }
            pendingAlerts.remove(toolRaw)
        }
    }
}
