import AppKit
import SwiftUI

/// 集中定义 JSON Formatter 的品牌调色板与按钮样式。
/// 品牌色（teal 主色、强调、字符串值高亮）固定，界面表层色随亮/暗外观自适应，
/// 以便在保留既有暗色切换逻辑的同时贴合新版亮色设计稿。
enum AppTheme {
    // MARK: - 品牌色（固定，取自设计稿 token）

    /// primary #0d9488（Teal 600）：激活态、图标 tile、主强调。
    static let primary = color(0x0d9488)
    /// tertiary #10b981（Emerald 500）：次强调。
    static let accent = color(0x10b981)
    /// secondary #0284c7（Sky 600）：Save Output 等次级主按钮。
    static let secondary = color(0x0284c7)
    /// 成功 / JSON 字符串值 #059669（Emerald 600）。
    static let stringValue = color(0x059669)
    /// 错误 #ef4444。
    static let error = color(0xef4444)
    static let onPrimary = Color.white

    // MARK: - 表层色（随外观自适应）

    /// 卡片背景。
    static let surface = dynamic(light: 0xffffff, dark: 0x1c2128)
    /// 主区背景 surface-bright。
    static let surfaceBright = dynamic(light: 0xf8fafc, dark: 0x16191d)
    /// 低强度容器（标题栏 / 行号栏背景）。
    static let surfaceContainerLow = dynamic(light: 0xf8fafc, dark: 0x1c2128)
    /// 常规容器（侧边栏卡片 / 分段控件底）。
    static let surfaceContainer = dynamic(light: 0xf1f5f9, dark: 0x232830)
    /// 高强度容器（悬停 / 高亮容器）。
    static let surfaceContainerHigh = dynamic(light: 0xe2e8f0, dark: 0x2d333b)
    /// 主文本。
    static let onSurface = dynamic(light: 0x1e293b, dark: 0xe6edf3)
    /// 次要文本。
    static let onSurfaceVariant = dynamic(light: 0x64748b, dark: 0x9da7b3)
    /// 描边（较重）。
    static let outline = dynamic(light: 0x94a3b8, dark: 0x57606a)
    /// 描边变体（分隔线 / 卡片边框）。
    static let outlineVariant = dynamic(light: 0xe2e8f0, dark: 0x30363d)

    // MARK: - 构造工具

    private static func color(_ hex: Int) -> Color {
        Color(nsColor: nsColor(hex))
    }

    static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    static func dynamicNSColor(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        }
    }
}

/// 主按钮：teal 实心（Format / 比较 JSON）。
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.primary.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 次级主按钮：azure 实心（Save Output）。
struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.secondary.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 描边按钮：白底 + outline 边框（Compress / Escape / Clear 等）。
struct OutlineActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(AppTheme.onSurface.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? AppTheme.surfaceContainer : AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.outlineVariant, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.55)
    }
}
