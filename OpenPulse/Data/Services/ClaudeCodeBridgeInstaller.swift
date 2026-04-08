import Foundation

enum ClaudeCodeBridgeInstaller {
    private static let bridgeFileName = "claude-code-bridge.sh"
    private static let settingsURL = URL.homeDirectory
        .appending(path: ".claude")
        .appending(path: "settings.json")

    static var cacheURL: URL {
        applicationSupportURL.appending(path: "claude-code-status.json")
    }

    @MainActor
    static func installIfNeeded() {
        do {
            try installBridgeScript()
            try configureClaudeCodeSettings()
            AppLogger.shared.info("Claude Code bridge installed")
        } catch {
            AppLogger.shared.warning("Claude Code bridge install skipped: \(error.localizedDescription)")
        }
    }

    private static var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support")
        return base.appending(path: "OpenPulse")
    }

    private static var bridgeURL: URL {
        applicationSupportURL.appending(path: bridgeFileName)
    }

    private static func installBridgeScript() throws {
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        let data = Data(bridgeScript.utf8)
        if (try? Data(contentsOf: bridgeURL)) != data {
            try data.write(to: bridgeURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeURL.path)
    }

    private static func configureClaudeCodeSettings() throws {
        var settings = try loadSettings()
        let statusLine = settings["statusLine"] as? [String: Any]
        let currentCommand = statusLine?["command"] as? String

        guard currentCommand?.contains(bridgeFileName) != true else { return }

        let forwardCommand = currentCommand.flatMap { $0.isEmpty ? nil : $0 }
        let bridgeCommand = makeBridgeCommand(forwardCommand: forwardCommand)
        var nextStatusLine = statusLine ?? [:]
        nextStatusLine["type"] = "command"
        nextStatusLine["command"] = bridgeCommand
        settings["statusLine"] = nextStatusLine

        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backupURL = settingsURL.deletingPathExtension().appendingPathExtension("openpulse-backup.json")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: settingsURL, to: backupURL)
            }
        }

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func makeBridgeCommand(forwardCommand: String?) -> String {
        let base = "/bin/bash \(shellQuote(bridgeURL.path))"
        guard let forwardCommand else { return base }
        let encodedForwardCommand = Data(forwardCommand.utf8).base64EncodedString()
        return "\(base) --forward-base64 \(shellQuote(encodedForwardCommand))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let bridgeScript = #"""
#!/bin/bash
set -f

input=$(cat)
cache_dir="${HOME}/Library/Application Support/OpenPulse"
cache_file="${cache_dir}/claude-code-status.json"

mkdir -p "$cache_dir" 2>/dev/null
tmp_file=$(mktemp "${cache_dir}/claude-code-status.XXXXXX" 2>/dev/null)

if [ -n "$tmp_file" ]; then
    if printf "%s" "$input" | python3 -c '
import json
import sys
import time

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(1)

rate_limits = payload.get("rate_limits") or {}
context_window = payload.get("context_window") or {}
output = {
    "captured_at": int(time.time()),
    "rate_limits": {
        "five_hour": rate_limits.get("five_hour"),
        "seven_day": rate_limits.get("seven_day"),
    },
    "context_window": {
        "used_percentage": context_window.get("used_percentage"),
        "remaining_percentage": context_window.get("remaining_percentage"),
    },
}
json.dump(output, sys.stdout, separators=(",", ":"))
' > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$cache_file" 2>/dev/null || rm -f "$tmp_file"
    else
        rm -f "$tmp_file"
    fi
fi

decode_base64() {
    printf "%s" "$1" | base64 --decode 2>/dev/null || printf "%s" "$1" | base64 -D 2>/dev/null
}

if [ "$1" = "--forward-base64" ] && [ -n "$2" ]; then
    forward_command=$(decode_base64 "$2")
    if [ -n "$forward_command" ]; then
        printf "%s" "$input" | eval "$forward_command"
        exit $?
    fi
fi

if command -v python3 >/dev/null 2>&1; then
    printf "%s" "$input" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    print("Claude")
    sys.exit(0)

model = ((payload.get("model") or {}).get("display_name")) or "Claude"
used = ((payload.get("context_window") or {}).get("used_percentage"))
if used is None:
    print(model)
else:
    print(f"{model} · {used:.0f}% context")
'
else
    printf "Claude"
fi
"""#
}
