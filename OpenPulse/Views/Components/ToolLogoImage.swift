import SwiftUI

extension Tool {
    /// Calibrated brand accent color for light and dark frosted surfaces.
    func brandAccentColor(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .codex:
            return colorScheme == .dark
                ? Color(red: 0.18, green: 0.82, blue: 0.64)
                : Color(red: 0.055, green: 0.61, blue: 0.47)
        case .antigravity:
            return colorScheme == .dark
                ? Color(red: 0.65, green: 0.54, blue: 0.98)
                : Color(red: 0.43, green: 0.28, blue: 0.90)
        case .claudeCode:
            return colorScheme == .dark
                ? Color(red: 0.94, green: 0.54, blue: 0.42)
                : Color(red: 0.85, green: 0.41, blue: 0.27)
        case .copilot:
            return colorScheme == .dark
                ? Color(red: 0.35, green: 0.63, blue: 1.00)
                : Color(red: 0.12, green: 0.42, blue: 0.88)
        }
    }
}

/// Displays each tool's native squircle app icon without extra nested background boxes.
/// Codex, Claude Code, and Antigravity already ship as full macOS squircle icons;
/// Copilot ships as a bare monochrome glyph so we wrap only Copilot in a matching squircle.
struct ToolBrandIconWell: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    var size: CGFloat = 26
    var iconSize: CGFloat? = nil

    var body: some View {
        if tool == .copilot {
            // Match the ~82% optical squircle bounds inside Codex/Claude/Antigravity 256x256 PNGs.
            let squircleSize = size * 0.82
            let cornerRadius = squircleSize * 0.23
            let glyphSize = squircleSize * 0.66
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color(red: 0.16, green: 0.19, blue: 0.24), Color(red: 0.09, green: 0.11, blue: 0.15)]
                                : [Color(red: 0.17, green: 0.20, blue: 0.25), Color(red: 0.10, green: 0.12, blue: 0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 1.5, y: 0.8)
                    .frame(width: squircleSize, height: squircleSize)

                if NSImage(named: tool.menuBarIconName) != nil {
                    Image(tool.menuBarIconName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: glyphSize, height: glyphSize)
                } else {
                    Image(systemName: tool.iconName)
                        .font(.system(size: glyphSize * 0.72, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
        } else {
            ToolLogoImage(tool: tool, size: size)
        }
    }
}

/// 显示工具品牌 Logo 的通用组件。
/// 优先使用 Assets.xcassets 中的 *Logo imageset；若图片不存在则回退到 SF Symbol。
struct ToolLogoImage: View {
    let tool: Tool
    let size: CGFloat

    var body: some View {
        if NSImage(named: tool.logoImageName) != nil {
            Image(tool.logoImageName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.iconName)
                .font(.system(size: size * 0.52, weight: .medium))
                .frame(width: size, height: size)
                .background(Color(tool.accentColorName).opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.22))
                .foregroundStyle(Color(tool.accentColorName))
        }
    }
}
