import OSLog
import SwiftUI

/// 设置弹窗：聚合语言 / 外观 / 编辑器字号 / 自动保存四类偏好。
/// 以 `.sheet` 呈现（macOS 天然居中、带半透明背板、Esc 关闭）。
/// 所有配色走 AppTheme、文案走 L10n，设置项即时生效（改绑定即写 @AppStorage）。
struct SettingsModalView: View {
    @Binding var languageRaw: String
    @Binding var appearanceMode: AppearanceMode
    @Binding var editorFontSize: Double
    @Binding var autoSave: Bool
    let l10n: L10n
    let onDone: () -> Void

    private static let logger = Logger(subsystem: "local.json-formatter.app", category: "SettingsModal")
    private let logger = SettingsModalView.logger

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .cn
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    languageSection()
                    appearanceSection()
                    fontSizeSection()
                    autoSaveSection()
                }
                .padding(24)
            }

            Divider()
            footerBar()
        }
        .frame(width: 460)
        .frame(minHeight: 520, idealHeight: 560, maxHeight: 640)
        .background(AppTheme.surfaceBright)
        .tint(AppTheme.primary)
    }

    // MARK: - 标题栏

    private func titleBar() -> some View {
        HStack(spacing: 8) {
            Text(l10n.t(.settingsTitle))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.onSurface)

            Spacer()

            Button {
                closeSettings()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.surfaceContainerLow)
                    )
            }
            .buttonStyle(.plain)
            .help(l10n.t(.settingsClose))
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(AppTheme.surface)
    }

    // MARK: - 底部操作

    private func footerBar() -> some View {
        HStack(spacing: 12) {
            Spacer()

            Button(l10n.t(.cancel)) {
                closeSettings()
            }
            .buttonStyle(OutlineActionButtonStyle())

            Button(l10n.t(.settingsDone)) {
                closeSettings()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(AppTheme.surface)
    }

    // MARK: - 语言分区

    private func languageSection() -> some View {
        section(title: l10n.t(.settingsLanguage), description: l10n.t(.settingsLanguageDesc)) {
            HStack(spacing: 4) {
                ForEach(AppLanguage.allCases) { candidate in
                    let isSelected = candidate == language
                    Button {
                        selectLanguage(candidate)
                    } label: {
                        Text(candidate.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : AppTheme.onSurface)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isSelected ? AppTheme.primary : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(AppTheme.surfaceContainer)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(AppTheme.outlineVariant, lineWidth: 1)
            )
        }
    }

    // MARK: - 外观分区

    private func appearanceSection() -> some View {
        section(title: l10n.t(.settingsAppearance), description: l10n.t(.settingsAppearanceDesc)) {
            HStack(spacing: 12) {
                ForEach(AppearanceMode.allCases) { mode in
                    appearanceCard(mode)
                }
            }
        }
    }

    private func appearanceCard(_ mode: AppearanceMode) -> some View {
        let isSelected = mode == appearanceMode
        return Button {
            selectAppearance(mode)
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    appearancePreview(mode)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.primary)
                            .background(Circle().fill(Color.white).padding(2))
                            .padding(4)
                    }
                }

                Text(mode.title(l10n))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.primary : AppTheme.onSurface)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AppTheme.primary.opacity(0.08) : AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? AppTheme.primary : AppTheme.outlineVariant, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// 迷你外观预览：用现有表层色画一个「标题栏 + 内容行」缩略图，不引入新色。
    @ViewBuilder
    private func appearancePreview(_ mode: AppearanceMode) -> some View {
        let colors = previewColors(mode)
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(AppTheme.primary)
                .frame(width: 22, height: 5)
            RoundedRectangle(cornerRadius: 2)
                .fill(colors.line)
                .frame(width: 40, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(colors.line)
                .frame(width: 30, height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(AppTheme.outlineVariant, lineWidth: 1)
        )
    }

    /// 预览缩略图配色。light/dark 用固定亮暗底色示意，system 用中性表层色。
    private func previewColors(_ mode: AppearanceMode) -> (background: Color, line: Color) {
        switch mode {
        case .light:
            return (Color(nsColor: AppTheme.nsColor(0xffffff)), Color(nsColor: AppTheme.nsColor(0xcbd5e1)))
        case .dark:
            return (Color(nsColor: AppTheme.nsColor(0x1c2128)), Color(nsColor: AppTheme.nsColor(0x57606a)))
        case .system:
            return (AppTheme.surfaceContainer, AppTheme.outline)
        }
    }

    // MARK: - 字号分区

    private func fontSizeSection() -> some View {
        section(title: l10n.t(.settingsFontSize), description: l10n.t(.settingsFontSizeDesc)) {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Text("12px")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.onSurfaceVariant)

                    Slider(value: $editorFontSize, in: 12...24, step: 1) { editing in
                        if !editing {
                            logSelectedFontSize()
                        }
                    }
                    .tint(AppTheme.primary)

                    Text("24px")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.onSurfaceVariant)
                }

                Text("\(Int(editorFontSize.rounded()))px")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.primary)
            }
        }
    }

    // MARK: - 自动保存分区

    private func autoSaveSection() -> some View {
        section(title: l10n.t(.settingsAutoSave), description: l10n.t(.settingsAutoSaveDesc)) {
            Toggle(isOn: $autoSave) {
                Text(l10n.t(.settingsAutoSave))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.onSurface)
            }
            .toggleStyle(.switch)
            .tint(AppTheme.primary)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 分区容器

    private func section<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.onSurface)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作

    private func selectLanguage(_ candidate: AppLanguage) {
        guard candidate.rawValue != languageRaw else {
            return
        }
        languageRaw = candidate.rawValue
        logger.info("设置弹窗切换界面语言，当前为 \(candidate.rawValue, privacy: .public)")
    }

    private func selectAppearance(_ mode: AppearanceMode) {
        guard mode != appearanceMode else {
            return
        }
        appearanceMode = mode
        logger.info("设置弹窗切换外观模式，当前为 \(mode.rawValue, privacy: .public)")
    }

    private func logSelectedFontSize() {
        logger.info("设置弹窗调整编辑器字号，当前为 \(Int(editorFontSize.rounded()), privacy: .public)px")
    }

    private func closeSettings() {
        logger.info("关闭设置弹窗，语言 \(languageRaw, privacy: .public)，外观 \(appearanceMode.rawValue, privacy: .public)，字号 \(Int(editorFontSize.rounded()), privacy: .public)px，自动保存 \(autoSave, privacy: .public)")
        onDone()
    }
}
