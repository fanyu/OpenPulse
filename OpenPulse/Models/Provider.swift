import Foundation

/// Represents an AI coding tool provider. Carries metadata about
/// the provider's auth requirements and data source paths.
enum Provider: String, CaseIterable, Identifiable {
    case claudeCode  = "claude"
    case codex       = "codex"
    case copilot     = "copilot"
    case antigravity = "antigravity"
    case opencode    = "opencode"

    var id: String { rawValue }

    var tool: Tool {
        guard let t = Tool(rawValue: rawValue) else {
            fatalError("Provider '\(rawValue)' has no matching Tool case — keep the two enums in sync.")
        }
        return t
    }

    var displayName: String { tool.displayName }

    var logoImageName: String { tool.logoImageName }

    var iconName: String { tool.iconName }

    /// How this provider is authenticated / authorized.
    var authKind: AuthKind {
        switch self {
        case .claudeCode:   .localFile
        case .codex:        .localFile
        case .copilot:      .oauthToken
        case .antigravity:  .localFile
        case .opencode:     .localFile
        }
    }

    /// Human-readable data source path shown in the UI.
    var dataSourcePath: String {
        switch self {
        case .claudeCode:   "~/.claude/projects/"
        case .codex:        "~/.codex/state_5.sqlite"
        case .antigravity:  "~/.cli-proxy-api/antigravity-*.json"
        case .copilot:      "~/.cli-proxy-api/github-copilot-*.json"
        case .opencode:     "~/.local/share/opencode/"
        }
    }

    enum AuthKind {
        case localFile   // reads local auth files, no manual setup
        case oauthToken  // requires user to provide/import a token
        case apiKey      // API Key stored in Keychain
    }
}
