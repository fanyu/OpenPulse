import Foundation

/// Ordering mode for multi-account lists in the Menu Bar popover.
enum MenuBarAccountSortMode: String, CaseIterable, Identifiable, Sendable {
    case manual = "manual"
    case quotaDescending = "quota_desc"
    case quotaAscending = "quota_asc"

    var id: String { rawValue }

    init(rawValueOrDefault rawValue: String) {
        self = MenuBarAccountSortMode(rawValue: rawValue) ?? .manual
    }

    var iconName: String {
        switch self {
        case .manual: "line.3.horizontal"
        case .quotaDescending: "arrow.down"
        case .quotaAscending: "arrow.up"
        }
    }

    var shortLabel: String {
        switch self {
        case .manual: String(localized: "手动")
        case .quotaDescending: String(localized: "多 → 少")
        case .quotaAscending: String(localized: "少 → 多")
        }
    }

    var helpText: String {
        switch self {
        case .manual: String(localized: "手动排序（可拖拽调整顺序）")
        case .quotaDescending: String(localized: "按剩余额度从多到少自动排序")
        case .quotaAscending: String(localized: "按剩余额度从少到多自动排序")
        }
    }
}

enum MenuBarAccountSortStorage {
    static let antigravitySortModeKey = "menubar.ag.accountSortMode"
    static let antigravityOrderKey = "menubar.ag.accountOrder"
    static let codexSortModeKey = "menubar.codex.accountSortMode"
    static let codexOrderKey = "menubar.codex.accountOrder"
}

enum MenuBarAccountOrdering {
    /// Parses a persisted comma-separated identifier list, preserving order and dropping empty/duplicate entries.
    static func parseOrder(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in raw.components(separatedBy: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func serializeOrder(_ ids: [String]) -> String {
        var seen = Set<String>()
        var unique: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            unique.append(trimmed)
        }
        return unique.joined(separator: ",")
    }

    /// Reorders `currentVisibleIDs` by moving `draggedID` to `targetID`'s slot, while preserving any
    /// hidden/offline account identifiers stored in `existingOrderRaw` in their relative positions.
    static func reordering(
        visibleIDs: [String],
        existingOrderRaw: String,
        draggedID: String,
        to targetID: String
    ) -> String {
        guard draggedID != targetID else { return existingOrderRaw }
        var reordered = visibleIDs
        guard let fromIndex = reordered.firstIndex(of: draggedID),
              let toIndex = reordered.firstIndex(of: targetID) else {
            return existingOrderRaw
        }
        let item = reordered.remove(at: fromIndex)
        reordered.insert(item, at: toIndex)
        return mergeReorderedVisibleIDs(reordered, intoExistingOrderRaw: existingOrderRaw)
    }

    /// Moves `id` by `delta` (-1 up, +1 down) within `visibleIDs`, preserving hidden IDs in `existingOrderRaw`.
    static func moving(
        visibleIDs: [String],
        existingOrderRaw: String,
        id: String,
        by delta: Int
    ) -> String {
        var reordered = visibleIDs
        guard let index = reordered.firstIndex(of: id) else { return existingOrderRaw }
        let targetIndex = index + delta
        guard reordered.indices.contains(targetIndex) else { return existingOrderRaw }
        reordered.swapAt(index, targetIndex)
        return mergeReorderedVisibleIDs(reordered, intoExistingOrderRaw: existingOrderRaw)
    }

    private static func mergeReorderedVisibleIDs(_ reorderedVisible: [String], intoExistingOrderRaw existingOrderRaw: String) -> String {
        let visibleSet = Set(reorderedVisible)
        let preservedHidden = parseOrder(existingOrderRaw).filter { !visibleSet.contains($0) }
        return serializeOrder(reorderedVisible + preservedHidden)
    }

    // MARK: - Antigravity

    /// Effective remaining fraction used for Antigravity quota sorting.
    /// Prefers the Gemini group's effective 5h remaining fraction (0 when weekly-exhausted),
    /// then Gemini weekly, then the first available group.
    static func antigravityPrimaryFraction(for account: AGAccountQuota) -> Double? {
        if let gemini = account.groups.first(where: { $0.id.caseInsensitiveCompare("gemini") == .orderedSame }),
           let fraction = effectiveAGGroupFraction(gemini) {
            return fraction
        }
        for group in account.groups {
            if let fraction = effectiveAGGroupFraction(group) {
                return fraction
            }
        }
        return account.primaryRemainingFraction
    }

    private static func effectiveAGGroupFraction(_ group: AGQuotaGroup) -> Double? {
        if group.isFiveHourUnusable {
            return 0.0
        }
        if let fiveHour = group.fiveHour?.remainingFraction, fiveHour.isFinite {
            return min(1.0, max(0.0, fiveHour))
        }
        if let weekly = group.weekly?.remainingFraction, weekly.isFinite {
            return min(1.0, max(0.0, weekly))
        }
        return nil
    }

    private static func antigravitySecondaryFraction(for account: AGAccountQuota) -> Double? {
        if let geminiWeekly = account.groups
            .first(where: { $0.id.caseInsensitiveCompare("gemini") == .orderedSame })?
            .weekly?.remainingFraction,
           geminiWeekly.isFinite {
            return min(1.0, max(0.0, geminiWeekly))
        }
        for group in account.groups {
            if let weekly = group.weekly?.remainingFraction, weekly.isFinite {
                return min(1.0, max(0.0, weekly))
            }
        }
        return nil
    }

    static func sortAntigravityAccounts(
        _ accounts: [AGAccountQuota],
        mode: MenuBarAccountSortMode,
        manualOrderRaw: String
    ) -> [AGAccountQuota] {
        switch mode {
        case .manual:
            return applyManualOrder(accounts, id: \.email, manualOrderRaw: manualOrderRaw)
        case .quotaDescending, .quotaAscending:
            let ascending = (mode == .quotaAscending)
            return accounts.sorted { lhs, rhs in
                if let cmp = compareOptionalFraction(
                    antigravityPrimaryFraction(for: lhs),
                    antigravityPrimaryFraction(for: rhs),
                    ascending: ascending
                ) {
                    return cmp
                }
                if let cmp = compareOptionalFraction(
                    antigravitySecondaryFraction(for: lhs),
                    antigravitySecondaryFraction(for: rhs),
                    ascending: ascending
                ) {
                    return cmp
                }
                return lhs.email.localizedCaseInsensitiveCompare(rhs.email) == .orderedAscending
            }
        }
    }

    // MARK: - Codex

    /// Effective remaining fraction used for Codex quota sorting.
    /// Uses valid unexpired 5h window remaining fraction (0 when 7d is exhausted), falling back to 7d.
    static func codexPrimaryFraction(for account: CodexAccountSnapshot, now: Date = Date()) -> Double? {
        guard let limits = account.limits else { return nil }
        let fiveHour = validCodexWindowFraction(limits.fiveHourWindow, now: now)
        let sevenDay = validCodexWindowFraction(limits.oneWeekWindow, now: now)
        if let sevenDay, sevenDay <= 0.001 {
            return 0.0
        }
        return fiveHour ?? sevenDay
    }

    private static func codexSecondaryFraction(for account: CodexAccountSnapshot, now: Date = Date()) -> Double? {
        validCodexWindowFraction(account.limits?.oneWeekWindow, now: now)
    }

    private static func validCodexWindowFraction(_ window: CodexWindow?, now: Date) -> Double? {
        guard let window, let used = window.usedPercent, used.isFinite else { return nil }
        if let resetDate = window.resetDate, resetDate <= now {
            return nil
        }
        return min(1.0, max(0.0, (100.0 - used) / 100.0))
    }

    static func sortCodexAccounts(
        _ accounts: [CodexAccountSnapshot],
        mode: MenuBarAccountSortMode,
        manualOrderRaw: String,
        now: Date = Date()
    ) -> [CodexAccountSnapshot] {
        switch mode {
        case .manual:
            return applyManualOrder(accounts, id: \.id, manualOrderRaw: manualOrderRaw)
        case .quotaDescending, .quotaAscending:
            let ascending = (mode == .quotaAscending)
            let fallbackRank = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element.id, $0.offset) })
            return accounts.sorted { lhs, rhs in
                if let cmp = compareOptionalFraction(
                    codexPrimaryFraction(for: lhs, now: now),
                    codexPrimaryFraction(for: rhs, now: now),
                    ascending: ascending
                ) {
                    return cmp
                }
                if let cmp = compareOptionalFraction(
                    codexSecondaryFraction(for: lhs, now: now),
                    codexSecondaryFraction(for: rhs, now: now),
                    ascending: ascending
                ) {
                    return cmp
                }
                return (fallbackRank[lhs.id] ?? 0) < (fallbackRank[rhs.id] ?? 0)
            }
        }
    }

    // MARK: - Shared helpers

    private static func applyManualOrder<T>(
        _ items: [T],
        id: KeyPath<T, String>,
        manualOrderRaw: String
    ) -> [T] {
        let savedOrder = parseOrder(manualOrderRaw)
        guard !savedOrder.isEmpty else { return items }
        let rankByID = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) })
        let originalIndex = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element[keyPath: id], $0.offset) })
        return items.sorted { lhs, rhs in
            let leftRank = rankByID[lhs[keyPath: id]]
            let rightRank = rankByID[rhs[keyPath: id]]
            switch (leftRank, rightRank) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return (originalIndex[lhs[keyPath: id]] ?? 0) < (originalIndex[rhs[keyPath: id]] ?? 0)
            }
        }
    }

    /// Compares two optional fractions; known values always sort before `nil` (unknown) regardless of direction.
    private static func compareOptionalFraction(_ lhs: Double?, _ rhs: Double?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            if abs(l - r) < 0.000_1 { return nil }
            return ascending ? (l < r) : (l > r)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return nil
        }
    }
}
