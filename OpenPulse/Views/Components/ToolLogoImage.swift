import SwiftUI

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
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: tool.iconName)
                .font(.system(size: size * 0.52, weight: .medium))
                .frame(width: size, height: size)
                .background(Color(tool.accentColorName).opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.22))
                .foregroundStyle(Color(tool.accentColorName))
        }
    }
}
