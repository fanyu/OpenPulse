# OpenPulse

English | [中文](#openpulse-中文)

A native macOS menu bar app that unifies token consumption and quota tracking across AI coding assistants.

| Menu Bar Popover | Dashboard — Trends |
|:---:|:---:|
| ![Menubar](docs/screenshot-menubar.png) | ![Trends](docs/screenshot-dashboard-trends.png) |
| **In Context** | **Dashboard — Quota** |
| ![Menubar context](docs/screenshot-menubar-context.png) | ![Quota](docs/screenshot-dashboard-quota.png) |

## Highlights

- Track sessions, token usage, and quota across multiple AI coding assistants in one native macOS app.
- Codex supports multi-account import, OpenAI OAuth login, per-account quota monitoring, and menu bar account switching.
- Optional Codex smart switching can automatically move to a better account when the current 5h or 7d window is exhausted, then relaunch Codex.

## Supported Tools

| Tool | Integration | What It Tracks |
|------|-------------|----------------|
| **Claude Code** | Local JSONL files (`~/.claude/projects/`) | Sessions, tokens (input/output/cache), model, git context |
| **Codex** | Local SQLite + OpenAI OAuth + local multi-account store | Sessions, token usage, per-account 5h / 7d quota, account switching |
| **GitHub Copilot** | GitHub internal API | Quota remaining, reset time |
| **Gemini Code Assist** (Antigravity) | Local markdown + Google OAuth API | Sessions, quota |
| **OpenCode** | Local files | Sessions, token usage |

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & Run

```bash
# Clone the repo
git clone https://github.com/your-username/OpenPulse.git
cd OpenPulse

# Generate the Xcode project
xcodegen generate

# Open in Xcode and run
open OpenPulse.xcodeproj
```

Before building, set your own Apple Developer Team ID in `project.yml`:

```yaml
DEVELOPMENT_TEAM: "YOUR_TEAM_ID"
```

Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) under Membership.

## Tool Setup

### Claude Code
No setup required. OpenPulse reads `~/.claude/projects/` automatically.

### Codex
OpenPulse reads `~/.codex/state_5.sqlite` automatically for local session history, and also supports Codex multi-account management.

Features:

- Import the current `~/.codex/auth.json`
- Add additional Codex accounts via OpenAI OAuth login
- Monitor each account's 5h and 7d quota windows
- Switch the current Codex account from the dashboard or menu bar
- Relaunch Codex automatically after account switching
- Enable optional smart switching from Settings so OpenPulse can automatically switch to a better account when the current one is exhausted

Notes:

- Multi-account credentials are stored locally on the Mac in `~/.openpulse/codex-accounts.json`
- Codex session history still comes from the currently active local Codex state, so quota monitoring is multi-account but local session history is still tied to the current account

### GitHub Copilot
OpenPulse reads your existing Copilot credentials from `~/.config/github-copilot/`. Sign in to Copilot in VS Code or the GitHub CLI first.

### Gemini Code Assist (Antigravity)
OpenPulse reads session data from `~/.gemini/antigravity/brain/` and uses Google OAuth (via the Antigravity CLI credentials) to fetch quota. Install and authenticate the [Antigravity CLI](https://github.com/nguyenphutrong/quotio) first.

### OpenCode
No setup required. OpenPulse reads OpenCode's local state automatically.

## Architecture

```
MenuBarExtra (popover)          MainWindow (dashboard)
        │                               │
        └───────────── AppStore ────────┘
                           │
                    DataSyncService
                    ┌──────┼──────────────┐
              Parsers (actors, one per tool)
                    │
          SessionRecord / QuotaRecord / DailyStatsRecord
                    │
               SwiftData → @Query views
```

- **Parsers** are Swift `actor`s — thread-safe, no locks needed.
- **DataSyncService** manages FSEvents watchers (local files) and polling timers (APIs).
- **KeychainService** is the only place credentials are stored (`com.fanyu.openpulse`).
- No ViewModels — views query SwiftData directly via `@Query`.

See [`CLAUDE.md`](CLAUDE.md) for detailed architecture docs.

## Contributing

1. Fork and clone the repo.
2. Run `xcodegen generate` to create the Xcode project.
3. Set your `DEVELOPMENT_TEAM` in `project.yml`.
4. Make your change in a focused branch.
5. Open a pull request.

To add support for a new tool, see the "Adding a New Tool" section in [`CLAUDE.md`](CLAUDE.md).

## License

MIT

---

# OpenPulse 中文

[English](#openpulse) | 中文

一款原生 macOS 菜单栏应用，统一追踪多款 AI 编程助手的 Token 消耗与配额。

| 菜单栏弹窗 | 主面板 · 趋势 |
|:---:|:---:|
| ![菜单栏弹窗](docs/screenshot-menubar.png) | ![趋势](docs/screenshot-dashboard-trends.png) |
| **桌面环境** | **主面板 · 配额** |
| ![环境截图](docs/screenshot-menubar-context.png) | ![配额](docs/screenshot-dashboard-quota.png) |

## 功能亮点

- 用一款原生 macOS 应用统一查看多种 AI 编程助手的会话、Token 用量和配额。
- Codex 支持多账户导入、OpenAI OAuth 登录、按账户额度监测，以及菜单栏内直接切换账号。
- 可选开启 Codex 智能切换：当当前账号的 5h 或 7d 配额耗尽时，自动切到更优账号并重启 Codex。

## 支持的工具

| 工具 | 接入方式 | 追踪内容 |
|------|----------|----------|
| **Claude Code** | 本地 JSONL 文件（`~/.claude/projects/`）| 会话、Token（输入/输出/缓存）、模型、Git 信息 |
| **Codex** | 本地 SQLite + OpenAI OAuth + 本地多账户仓库 | 会话、Token 用量、按账户 5h / 7d 配额、账号切换 |
| **GitHub Copilot** | GitHub 内部 API | 剩余配额、重置时间 |
| **Gemini Code Assist**（Antigravity）| 本地 markdown + Google OAuth API | 会话、配额 |
| **OpenCode** | 本地文件 | 会话、Token 用量 |

## 环境要求

- macOS 26（Tahoe）或更高版本
- Xcode 26 或更高版本
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

## 构建与运行

```bash
# 克隆仓库
git clone https://github.com/your-username/OpenPulse.git
cd OpenPulse

# 生成 Xcode 项目
xcodegen generate

# 用 Xcode 打开并运行
open OpenPulse.xcodeproj
```

构建前，在 `project.yml` 中填写你自己的 Apple Developer Team ID：

```yaml
DEVELOPMENT_TEAM: "YOUR_TEAM_ID"
```

Team ID 可在 [developer.apple.com/account](https://developer.apple.com/account) 的 Membership 页面查到。

## 各工具配置

### Claude Code
无需额外配置，OpenPulse 自动读取 `~/.claude/projects/`。

### Codex
OpenPulse 会自动读取 `~/.codex/state_5.sqlite` 获取本地会话历史，同时支持 Codex 多账户管理。

支持内容：

- 导入当前 `~/.codex/auth.json`
- 通过 OpenAI OAuth 新增多个 Codex 账号
- 监测每个账号的 5h 与 7d 配额窗口
- 在主面板或菜单栏中切换当前 Codex 账号
- 切换账号后自动重启 Codex
- 可在设置中开启智能切换，在当前账号额度耗尽时自动切到更优账号

说明：

- 多账户认证信息只保存在本机的 `~/.openpulse/codex-accounts.json`
- Codex 会话历史仍来自当前本机正在使用的本地状态，因此多账户完整覆盖的是额度监测与账号切换；本地会话历史仍对应当前账号

### GitHub Copilot
OpenPulse 从 `~/.config/github-copilot/` 读取已有的 Copilot 凭据。请先在 VS Code 或 GitHub CLI 中登录 Copilot。

### Gemini Code Assist（Antigravity）
OpenPulse 从 `~/.gemini/antigravity/brain/` 读取会话数据，并通过 Google OAuth（使用 Antigravity CLI 的应用凭据）拉取配额。请先安装并登录 [Antigravity CLI](https://github.com/nguyenphutrong/quotio)。

### OpenCode
无需额外配置，OpenPulse 自动读取 OpenCode 的本地状态。

## 架构简介

```
MenuBarExtra（弹出窗口）          MainWindow（主面板）
        │                               │
        └───────────── AppStore ────────┘
                           │
                    DataSyncService
                    ┌──────┼──────────────┐
              Parsers（actor，每个工具一个）
                    │
          SessionRecord / QuotaRecord / DailyStatsRecord
                    │
               SwiftData → @Query 视图
```

- **Parsers** 使用 Swift `actor`，天然线程安全，无需加锁。
- **DataSyncService** 管理本地文件的 FSEvents 监听和 API 轮询定时器。
- **KeychainService** 是唯一存储凭据的地方（`com.fanyu.openpulse`）。
- 无 ViewModel，视图直接通过 `@Query` 查询 SwiftData。

详细架构文档见 [`CLAUDE.md`](CLAUDE.md)。

## 参与贡献

1. Fork 并克隆仓库。
2. 执行 `xcodegen generate` 生成 Xcode 项目。
3. 在 `project.yml` 中设置你的 `DEVELOPMENT_TEAM`。
4. 在独立分支上完成修改。
5. 提交 Pull Request。

如需新增工具支持，参见 [`CLAUDE.md`](CLAUDE.md) 中的「Adding a New Tool」章节。

## 许可证

MIT
