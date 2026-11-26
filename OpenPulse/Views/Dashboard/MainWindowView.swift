import SwiftUI
import SwiftData
import AppKit

struct MainWindowView: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environment(appStore)
        } detail: {
            detailView
                .environment(appStore)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 560)
        .background(OpenWindowActionCapture())
        .background(MainWindowCapture())
    }

    @ViewBuilder
    private var detailView: some View {
        switch appStore.selectedTab {
        case .trends:    TrendsView()
        case .quota:     QuotaView()
        case .activity:  SessionHistoryView()
        case .providers: ProviderView()
        case .menuBar:   MenuBarSettingsView()
        case .settings:  SettingsView()
        }
    }
}

// MARK: - Sidebar (macOS 26 Liquid Glass Telemetry Chrome)

struct SidebarView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    private var hasSyncError: Bool {
        appStore.syncService?.syncError != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarIdentity()

            TelemetryHairline(opacity: colorScheme == .dark ? 0.08 : 0.06)
                .padding(.horizontal, 14)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    navSection(title: "监控", tabs: [.trends, .quota, .activity])
                    navSection(title: "管理", tabs: [.providers, .menuBar, .settings])
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)

            SidebarSyncStatus()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 248)
    }

    private func navSection(title: LocalizedStringKey, tabs: [AppTab]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)

            ForEach(tabs, id: \.self) { tab in
                SidebarNavRow(
                    tab: tab,
                    isSelected: appStore.selectedTab == tab,
                    showAlertDot: tab == .settings && hasSyncError,
                    selectionNamespace: selectionNamespace
                ) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                        appStore.selectedTab = tab
                    }
                }
            }
        }
    }
}

// MARK: - Brand Identity Header

private struct SidebarIdentity: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            brandAppMark

            VStack(alignment: .leading, spacing: 1.5) {
                Text("OpenPulse")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.35)
                Text("AI 用量与额度")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    private var brandAppMark: some View {
        let shape = RoundedRectangle(cornerRadius: 8.5, style: .continuous)
        return ZStack {
            if let appIcon = NSApp?.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(shape)
            } else {
                shape
                    .fill(Color.black)
                    .frame(width: 32, height: 32)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.90, blue: 0.82))
            }
        }
        .overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.26 : 0.65),
                            Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.14),
            radius: 4,
            x: 0,
            y: 1.5
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Navigation Item Row (Sliding Specular Pill + Semantic Icon Well)

private struct SidebarNavRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let tab: AppTab
    let isSelected: Bool
    let showAlertDot: Bool
    let selectionNamespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let accent = tab.sidebarAccentColor(for: colorScheme)
        let rowShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let iconShape = RoundedRectangle(cornerRadius: 7, style: .continuous)

        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    if isSelected {
                        iconShape
                            .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                            .overlay {
                                iconShape
                                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 0.5)
                            }
                    }

                    Image(systemName: isSelected ? tab.activeIcon : tab.icon)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            isSelected
                                ? accent
                                : (isHovered ? Color.primary.opacity(0.88) : Color.secondary)
                        )
                        .contentTransition(.symbolEffect(.replace.offUp))
                }
                .frame(width: 24, height: 24)

                Text(tab.localizedTitle)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? .primary
                            : (isHovered ? .primary : Color.primary.opacity(0.76))
                    )
                    .lineLimit(1)

                Spacer(minLength: 4)

                if showAlertDot {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .shadow(color: Color.orange.opacity(0.5), radius: 2)
                } else if isHovered && !isSelected {
                    Text(tab.shortcutLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    rowShape
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.11)
                                : Color.white.opacity(0.88)
                        )
                        .overlay {
                            rowShape
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.18)
                                                : Color.white.opacity(0.96),
                                            Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.065)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.6
                                )
                        }
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.055),
                            radius: 3,
                            x: 0,
                            y: 1
                        )
                        .matchedGeometryEffect(id: "sidebarActivePill", in: selectionNamespace)
                } else if isHovered {
                    rowShape
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.045))
                }
            }
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .keyboardShortcut(tab.shortcutDigit, modifiers: .command)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Bottom Telemetry Sync Status

private struct SidebarSyncStatus: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRefreshHovered = false

    var body: some View {
        let isSyncing = appStore.syncService?.isSyncingActive == true
        let hasError = appStore.syncService?.syncError != nil
        let lastDate = appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate
        let healthyTint = colorScheme == .dark
            ? Color(red: 0.24, green: 0.82, blue: 0.54)
            : Color(red: 0.12, green: 0.64, blue: 0.40)

        VStack(alignment: .leading, spacing: 0) {
            TelemetryHairline(opacity: colorScheme == .dark ? 0.08 : 0.06)
                .padding(.horizontal, 14)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if isSyncing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.72)
                            Text("正在同步")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    } else if hasError {
                        Button {
                            appStore.openDiagnosticsLogs()
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 6)
                                Text("同步遇到问题")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("查看同步日志")
                    } else {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(healthyTint)
                                .frame(width: 6, height: 6)
                            Text("本地用量监控")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let date = lastDate {
                        Text("最近同步于 \(date.formatted(.dateTime.hour().minute()))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .help(date.formatted(date: .complete, time: .standard))
                    } else {
                        Text("等待首次同步")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    guard !isSyncing else { return }
                    Task { await appStore.syncService?.sync() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSyncing ? .quaternary : (isRefreshHovered ? .primary : .tertiary))
                        .frame(width: 24, height: 24)
                        .background(
                            isRefreshHovered
                                ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)
                                : Color.clear,
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(isSyncing)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isRefreshHovered = hovering
                    }
                }
                .help(isSyncing ? String(localized: "同步中…") : String(localized: "立即刷新同步"))
                .accessibilityLabel("刷新同步")
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 13)
        }
    }
}
