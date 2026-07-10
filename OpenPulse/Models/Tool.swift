import Foundation

/// Identifies which AI coding tool generated a session.
enum Tool: String, Codable, CaseIterable, Sendable {
    case codex = "codex"
    case claudeCode = "claude"
    case copilot = "copilot"
    case antigravity = "antigravity"

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        }
    }

    /// SF Symbol fallback（用于无法显示品牌 Logo 的小尺寸场合）
    var iconName: String {
        switch self {
        case .claudeCode: "c.circle.fill"
        case .codex: "terminal.fill"
        case .copilot: "airplane.circle.fill"
        case .antigravity: "atom"
        }
    }

    /// Assets.xcassets 中的品牌 Logo 图片名称
    var logoImageName: String {
        switch self {
        case .claudeCode: "ClaudeLogo"
        case .codex: "CodexLogo"
        case .copilot: "CopilotLogo"
        case .antigravity: "AntigravityLogo"
        }
    }

    var accentColorName: String {
        switch self {
        case .claudeCode: "ClaudeOrange"
        case .codex: "CodexGreen"
        case .copilot: "CopilotBlue"
        case .antigravity: "AntigravityPurple"
        }
    }

    /// Menu bar icon asset name (small template image for status bar)
    var menuBarIconName: String {
        switch self {
        case .claudeCode: "claude-menubar"
        case .codex: "codex-menubar"
        case .copilot: "CopilotLogo"
        case .antigravity: "AntigravityLogo"
        }
    }

    /// true = only quota is supported, no local session files
    var isQuotaOnly: Bool {
        false
    }

    /// Tools whose 5-hour quota is backed by a real data source and can be shown
    /// directly in the menu bar title.
    var supportsMenuBarFiveHourDisplay: Bool {
        switch self {
        case .claudeCode, .codex:
            true
        case .copilot, .antigravity:
            false
        }
    }

    /// 默认排列顺序（逗号分隔的 rawValue），用于 menubar.toolOrder AppStorage 初始值
    static var defaultOrderRaw: String {
        allCases.map(\.rawValue).joined(separator: ",")
    }
}
