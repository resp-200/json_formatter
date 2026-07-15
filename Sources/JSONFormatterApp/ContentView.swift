import AppKit
import OSLog
import SwiftUI

struct ContentView: View {
    @ObservedObject var externalInputStore: ExternalJSONInputStore
    // 旧外观键：保留只读用于迁移，切换外观只写新键 jsonFormatterAppearanceMode（向后兼容）。
    @AppStorage("jsonFormatterIsDarkMode") private var legacyIsDarkMode = false
    @AppStorage("jsonFormatterAppearanceMode") private var appearanceModeRaw = ""
    @AppStorage("jsonFormatterEditorFontSize") private var editorFontSize = 13.0
    @AppStorage("jsonFormatterAutoSave") private var autoSave = false
    @AppStorage("jsonFormatterLanguage") private var languageRaw = AppLanguage.cn.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var isClearHistoryConfirmationPresented = false
    @State private var isSettingsPresented = false
    @State private var autoSaveDebounceTask: Task<Void, Never>?

    @State private var inputText = ""
    @State private var outputText = ""
    @State private var workspaceMode: WorkspaceMode = .format
    @State private var diffRightText = ""
    @State private var diffResult: JSONDiffResult?
    @State private var errorMessage = ""
    @State private var isSearchVisible = false
    @State private var searchQuery = ""
    @State private var queryExpression = ""
    @State private var currentMatchIndex = 0
    @State private var outputMatchRanges: [NSRange] = []
    @State private var isOutputSearchSkippedForSize = false
    @State private var outputDisplayMode: OutputDisplayMode = .text
    @State private var jsonTreeRoot: JSONTreeNode?
    @State private var expandedTreeNodeIDs: Set<String> = []
    @State private var treeSearchMatches: [JSONTreeSearchMatch] = []
    @State private var outputRenderRevision = 0
    @State private var outputScrollRevision = 0
    @State private var outputLineIndex = OutputLineIndex.empty
    @State private var activeTransformID: UUID?
    @State private var isTransforming = false
    @State private var latestReleaseInfo: LatestReleaseInfo?
    @State private var keyDownMonitor: Any?
    @AppStorage("jsonFormatterIsSidebarCollapsed") private var isSidebarCollapsed = false
    @State private var pages: [JSONWorkspacePage] = [.initial]
    @State private var selectedPageID: UUID?
    @State private var nextPageNumber = 2
    @State private var editingPageID: UUID?
    @State private var editingPageTitle = ""
    @State private var editingOriginalPageTitle = ""
    @State private var didLoadPersistedWorkspace = false
    @State private var isLoadingPageSnapshot = false

    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedEditingPageID: UUID?

    private static let logger = Logger(subsystem: "local.json-formatter.app", category: "ContentView")
    private let logger = ContentView.logger

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .cn
    }

    private var l10n: L10n {
        L10n(language: language)
    }

    /// 当前外观模式。老用户从未写过新键（空串）时回退用旧 `legacyIsDarkMode` 推导，
    /// 保证升级不丢外观偏好；固化到新键在 onAppear 的 `migrateAppearanceModeIfNeeded()` 完成。
    private var appearanceMode: AppearanceMode {
        get {
            if let mode = AppearanceMode(rawValue: appearanceModeRaw) {
                return mode
            }
            return legacyIsDarkMode ? .dark : .light
        }
        nonmutating set {
            appearanceModeRaw = newValue.rawValue
        }
    }

    /// 有效暗色：喂给 NSTextView 高亮配色（buildHighlightedJSONText / depthColors）。
    /// system 模式下读环境 colorScheme（此时 preferredColorScheme(nil)，环境即系统解析值）。
    private var effectiveIsDarkMode: Bool {
        switch appearanceMode {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return systemColorScheme == .dark
        }
    }

    /// SwiftUI 强制外观：light→.light，dark→.dark，system→nil（跟随系统）。
    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return nil
        }
    }

    private var safeCurrentMatchIndex: Int {
        guard !outputMatchRanges.isEmpty else {
            return 0
        }

        return min(max(currentMatchIndex, 0), outputMatchRanges.count - 1)
    }

    private var currentMatchRange: NSRange? {
        guard !outputMatchRanges.isEmpty else {
            return nil
        }

        return outputMatchRanges[safeCurrentMatchIndex]
    }

    private var activeMatchCount: Int {
        switch outputDisplayMode {
        case .text:
            return outputMatchRanges.count
        case .tree:
            return treeSearchMatches.count
        }
    }

    private var selectedPage: JSONWorkspacePage? {
        pages.first { $0.id == activePageID }
    }

    private var activePageID: UUID {
        selectedPageID ?? pages.first?.id ?? JSONWorkspacePage.initial.id
    }

    private var safeActiveMatchIndex: Int {
        guard activeMatchCount > 0 else {
            return 0
        }

        return min(max(currentMatchIndex, 0), activeMatchCount - 1)
    }

    private var currentAppVersion: String {
        let infoDictionary = Bundle.main.infoDictionary
        if let version = infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }

        return l10n.t(.devVersion)
    }

    private var appVersionText: String {
        l10n.versionText(currentAppVersion)
    }

    var body: some View {
        HSplitView {
            sidebarView()
                // 侧边栏使用固定宽度，避免 HSplitView 记忆分隔条位置导致
                // 首次进入与「收起→再展开」后的宽度不一致；统一以设计稿 260 为基准。
                .frame(width: isSidebarCollapsed ? 72 : 260)

            mainEditorView()
                // 主区最小宽度收窄，让窗口能真正压缩而不裁切；双编辑卡片各自的
                // 最小宽度在 mainEditorView 分栏处单独约束，确保窄窗口下不被挤没。
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.surfaceBright)
        .tint(AppTheme.primary)
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $isSettingsPresented) {
            SettingsModalView(
                languageRaw: $languageRaw,
                appearanceMode: Binding(get: { appearanceMode }, set: { appearanceMode = $0 }),
                editorFontSize: $editorFontSize,
                autoSave: $autoSave,
                l10n: l10n,
                onDone: { isSettingsPresented = false }
            )
        }
        .onChange(of: autoSave) { _, isOn in
            handleAutoSaveToggle(isOn)
        }
        .onAppear {
            migrateAppearanceModeIfNeeded()
            loadPersistedWorkspaceIfNeeded()
            installFindShortcutMonitor()
            checkLatestRelease()
        }
        .onDisappear {
            removeFindShortcutMonitor()
        }
        .onChange(of: inputText) { _, _ in
            invalidateActiveTransform()
            if workspaceMode == .diff {
                diffResult = nil
            }
            updateCurrentPageForTextEditing()
        }
        .onChange(of: diffRightText) { _, _ in
            invalidateActiveTransform()
            diffResult = nil
            updateCurrentPageForTextEditing()
        }
        .onChange(of: workspaceMode) { _, _ in
            guard !isLoadingPageSnapshot else {
                return
            }
            invalidateActiveTransform()
            diffResult = nil
            errorMessage = ""
            updateCurrentPageForTextEditing()
        }
        .onChange(of: outputText) { _, _ in
            refreshSearchMatches()
            updateCurrentPageForTextEditing()
        }
        .onChange(of: errorMessage) { _, _ in
            updateCurrentPageForTextEditing()
        }
        .onChange(of: queryExpression) { _, _ in
            updateCurrentPageForTextEditing()
        }
        .onChange(of: searchQuery) { _, _ in
            refreshSearchMatches()
            updateCurrentPageForTextEditing()
        }
        .onChange(of: outputDisplayMode) { _, _ in
            refreshSearchMatches()
            updateCurrentPageForTextEditing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatJSONRequested)) { _ in
            formatJSON()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveJSONPageRequested)) { _ in
            saveCurrentPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newJSONPageRequested)) { _ in
            createNewPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .findOutputRequested)) { _ in
            openSearch()
        }
        .onChange(of: externalInputStore.pendingFormatRequest, initial: true) { _, request in
            guard let request else {
                return
            }
            acceptExternalJSON(request)
        }
    }

    private func sidebarView() -> some View {
        Group {
            if isSidebarCollapsed {
                collapsedSidebarView()
            } else {
                expandedSidebarView()
            }
        }
        .background(AppTheme.surfaceContainerLow)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.outlineVariant)
                .frame(width: 1)
        }
    }

    private func expandedSidebarView() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.primary)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                    .shadow(color: AppTheme.primary.opacity(0.25), radius: 3, y: 1)

                Text(l10n.t(.appTitle))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.onSurface)

                Spacer(minLength: 4)

                Button {
                    toggleSidebarCollapsed()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .foregroundStyle(AppTheme.onSurfaceVariant)
                }
                .buttonStyle(.borderless)
                .help(l10n.t(.collapseSidebar))
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Button {
                createNewPage()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text(l10n.t(.newDocument))
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(AppTheme.onSurface)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.surfaceContainer)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.outlineVariant, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(pages) { page in
                        pageRow(page)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
            }

            sidebarFooter()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarFooter() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
                .padding(.bottom, 6)

            HStack(spacing: 6) {
                Text(appVersionText)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.onSurfaceVariant)
                    .textSelection(.enabled)

                if latestReleaseInfo != nil {
                    Button {
                        openLatestReleasePage()
                    } label: {
                        Text(l10n.t(.newBadge))
                            .font(.caption2.bold())
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.error)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(l10n.t(.newBadgeHelp))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            // Settings 入口：点击弹出居中设置弹窗（语言 / 外观 / 字号 / 自动保存）。
            // 原语言下拉菜单已迁移进弹窗的语言分区。
            Button {
                openSettings()
            } label: {
                sidebarFooterRow(icon: "gearshape", title: l10n.t(.settings), tint: AppTheme.onSurfaceVariant)
            }
            .buttonStyle(.plain)

            Button {
                isClearHistoryConfirmationPresented = true
            } label: {
                sidebarFooterRow(icon: "trash", title: l10n.t(.clearHistory), tint: AppTheme.error)
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                l10n.t(.clearHistoryConfirmTitle),
                isPresented: $isClearHistoryConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(l10n.t(.clearHistoryConfirm), role: .destructive) {
                    clearAllHistory()
                }
                Button(l10n.t(.cancel), role: .cancel) {}
            } message: {
                Text(l10n.t(.clearHistoryConfirmMessage))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    private func sidebarFooterRow(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func collapsedSidebarView() -> some View {
        VStack(spacing: 10) {
            Button {
                toggleSidebarCollapsed()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help(l10n.t(.expandSidebar))

            Button {
                createNewPage()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(l10n.t(.newDocument))

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(pages) { page in
                        collapsedPageButton(page)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func pageRow(_ page: JSONWorkspacePage) -> some View {
        let isEditing = editingPageID == page.id
        let isActive = page.id == activePageID

        return Group {
            if isEditing {
                pageEditingRow(page)
            } else {
                pageCard(page, isActive: isActive)
            }
        }
        .onChange(of: focusedEditingPageID) { previousPageID, nextPageID in
            guard previousPageID == page.id, nextPageID != page.id else {
                return
            }

            DispatchQueue.main.async {
                guard editingPageID == page.id, focusedEditingPageID != page.id else {
                    return
                }

                commitPageTitleEditing(page)
            }
        }
    }

    private func pageCard(_ page: JSONWorkspacePage, isActive: Bool) -> some View {
        Button {
            selectPage(page)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive || page.isUnsaved ? AppTheme.primary.opacity(0.14) : AppTheme.surfaceContainer)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: page.isUnsaved ? "doc.text" : "doc")
                            .font(.system(size: 14))
                            .foregroundStyle(isActive || page.isUnsaved ? AppTheme.primary : AppTheme.outline)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.onSurface)
                        .lineLimit(1)

                    Text(pageStatusSubtitle(page))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(page.isUnsaved ? AppTheme.primary : AppTheme.outline)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isActive {
                    Text(l10n.t(.current))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? AppTheme.primary.opacity(0.08) : AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? AppTheme.primary.opacity(0.5) : AppTheme.outlineVariant, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(l10n.t(.rename)) {
                beginPageTitleEditing(page)
            }
            Button(l10n.t(.delete), role: .destructive) {
                deletePage(page)
            }
        }
    }

    private func pageEditingRow(_ page: JSONWorkspacePage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(l10n.t(.pageNamePlaceholder), text: $editingPageTitle)
                .textFieldStyle(.roundedBorder)
                .focused($focusedEditingPageID, equals: page.id)
                .onSubmit {
                    commitPageTitleEditing(page)
                }

            HStack(spacing: 8) {
                Button(l10n.t(.done)) {
                    commitPageTitleEditing(page)
                }
                .buttonStyle(.borderless)

                Button(l10n.t(.cancel)) {
                    cancelPageTitleEditing(page)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.primary.opacity(0.5), lineWidth: 1)
        )
    }

    private func pageStatusSubtitle(_ page: JSONWorkspacePage) -> String {
        if page.isUnsaved {
            return l10n.t(.statusUnsaved)
        }

        return l10n.relativeTime(since: page.updatedAt)
    }

    private func collapsedPageButton(_ page: JSONWorkspacePage) -> some View {
        Button {
            selectPage(page)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(page.shortTitle)
                    .font(.caption.weight(page.id == activePageID ? .bold : .regular))
                    .foregroundStyle(page.id == activePageID ? Color.white : AppTheme.onSurface)
                    .frame(width: 36, height: 32)
                    .background(page.id == activePageID ? AppTheme.primary : AppTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.outlineVariant, lineWidth: page.id == activePageID ? 0 : 1)
                    )

                if page.isUnsaved {
                    Circle()
                        .fill(AppTheme.primary)
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(page.isUnsaved ? "\(page.title) (\(l10n.t(.statusUnsaved)))" : page.title)
    }

    private func mainEditorView() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar()

            VStack(alignment: .leading, spacing: 12) {
                if let clipboardText = externalInputStore.clipboardTextToOffer {
                    clipboardImportBanner(clipboardText)
                }

                Text(workspaceMode.description(l10n))
                    .font(.caption)
                    .foregroundStyle(AppTheme.onSurfaceVariant)
                    .textSelection(.enabled)

                if isTransforming {
                    ProgressView(l10n.t(.processing))
                        .controlSize(.small)
                }

                if workspaceMode == .format, outputLineIndex.isVirtualized {
                    Text(l10n.t(.largeFileBanner))
                        .font(.caption)
                        .foregroundStyle(AppTheme.onSurfaceVariant)
                        .textSelection(.enabled)
                }

                if workspaceMode == .format {
                    HStack(alignment: .top, spacing: 16) {
                        editor(title: l10n.t(.inputTitle), text: $inputText, showLineNumbers: false) {
                            queryExpressionBar()
                        }
                        .frame(minWidth: 180)
                        outputEditor(title: l10n.t(.outputTitle))
                            .frame(minWidth: 180)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            editor(title: l10n.t(.inputTitle), text: $inputText, showLineNumbers: false) { EmptyView() }
                                .frame(minWidth: 180)
                            editor(title: l10n.t(.outputTitle), text: $diffRightText, showLineNumbers: false) { EmptyView() }
                                .frame(minWidth: 180)
                        }
                        .frame(maxHeight: .infinity)

                        diffResultView()
                            .frame(minHeight: 150, idealHeight: 190, maxHeight: 230)
                    }
                    .frame(maxHeight: .infinity)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(AppTheme.error)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.surfaceBright)
    }

    private func topBar() -> some View {
        HStack(spacing: 12) {
            // 按钮组做「溢出折叠」：宽时全部平铺，窄时放不下的次要按钮
            // 自动收进右侧「更多」下拉菜单，主按钮始终在外。
            adaptiveActionBar()

            Spacer(minLength: 12)

            if workspaceMode == .format {
                topBarSearchField()
            }

            // 顶栏放日夜切换（原为语言切换，已与侧边栏 Settings 对调）。
            themeToggle()

            // 「清空」固定在顶栏最右（原保存按钮位置），不参与左侧按钮组的折叠。
            Button(l10n.t(.clear)) {
                clearAll()
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(isClearDisabled)
            .layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .frame(maxWidth: .infinity)
        .background(AppTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.outlineVariant)
                .frame(height: 1)
        }
    }

    private func topBarSearchField() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.outline)

            TextField(l10n.t(.searchPlaceholder), text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.onSurface)
                .focused($isSearchFocused)
                .frame(minWidth: 110, idealWidth: 180, maxWidth: 180)
                .onSubmit {
                    isSearchVisible = true
                    selectNextMatch(matchCount: activeMatchCount)
                }

            if !searchQuery.isEmpty {
                Text(l10n.searchStatus(
                    currentIndex: safeActiveMatchIndex,
                    matchCount: activeMatchCount,
                    hasQuery: !searchQuery.isEmpty,
                    isPaused: isOutputSearchSkippedForSize
                ))
                .font(.caption2)
                .foregroundStyle(AppTheme.onSurfaceVariant)

                Button {
                    selectPreviousMatch(matchCount: activeMatchCount)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(activeMatchCount == 0 || isOutputSearchSkippedForSize)

                Button {
                    selectNextMatch(matchCount: activeMatchCount)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(activeMatchCount == 0 || isOutputSearchSkippedForSize)

                Button {
                    closeSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.outline)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.surfaceContainerLow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.outlineVariant, lineWidth: 1)
        )
        .onChange(of: searchQuery) { _, newValue in
            if !newValue.isEmpty {
                isSearchVisible = true
            }
        }
    }

    /// 顶栏日夜快切：太阳 / 月亮图标按钮。语义为在 light↔dark 间显式切换
    /// （依据当前有效外观决定去向），System 只能从设置弹窗进入。
    private func themeToggle() -> some View {
        Button {
            toggleColorScheme()
        } label: {
            Image(systemName: effectiveIsDarkMode ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.onSurfaceVariant)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.surfaceContainerLow)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.outlineVariant, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(effectiveIsDarkMode ? l10n.t(.toggleLightMode) : l10n.t(.toggleDarkMode))
    }

    /// 顶栏左侧操作按钮的描述数据，用于在平铺 / 折叠两种布局间复用同一份逻辑。
    private struct ActionButtonSpec: Identifiable {
        let id: String
        let title: String
        let isDisabled: Bool
        let action: () -> Void
    }

    /// 当前是否禁用「清空」：所有内容与状态均为空且非处理中。
    private var isClearDisabled: Bool {
        inputText.isEmpty && outputText.isEmpty && diffRightText.isEmpty
            && diffResult == nil && errorMessage.isEmpty && searchQuery.isEmpty
            && queryExpression.isEmpty && !isTransforming
    }

    /// 可折叠的次要按钮（描边），顺序即优先级：靠后的先被收进「更多」菜单。
    /// 注意：「清空」不在此列——它固定在顶栏最右，不参与折叠。
    private var collapsibleActionSpecs: [ActionButtonSpec] {
        if workspaceMode == .format {
            return [
                ActionButtonSpec(id: "compress", title: l10n.t(.compress), isDisabled: isTransforming) {
                    compactJSON()
                },
                ActionButtonSpec(id: "diff", title: l10n.t(.jsonDiff), isDisabled: isTransforming) {
                    switchWorkspaceMode(to: .diff)
                },
                ActionButtonSpec(id: "escape", title: l10n.t(.escape), isDisabled: isTransforming) {
                    escapeJSON()
                },
            ]
        }
        return [
            ActionButtonSpec(id: "toFormat", title: l10n.t(.format), isDisabled: isTransforming) {
                switchWorkspaceMode(to: .format)
            },
        ]
    }

    /// 仅存在于「更多」菜单里的动作（转义并复制 / 复制结果），沿用原 ellipsis 菜单。
    private var overflowOnlyActionSpecs: [ActionButtonSpec] {
        guard workspaceMode == .format else {
            return []
        }
        return [
            ActionButtonSpec(id: "escapeAndCopy", title: l10n.t(.escapeAndCopy), isDisabled: isTransforming) {
                escapeAndCopyJSON()
            },
            ActionButtonSpec(id: "copyOutput", title: l10n.t(.copyOutput), isDisabled: outputText.isEmpty || isTransforming) {
                copyOutput()
            },
        ]
    }

    /// 顶栏主按钮（格式化 / 比较）：始终保留在外，带 Cmd+Enter 快捷键。
    @ViewBuilder
    private func primaryActionButton() -> some View {
        if workspaceMode == .format {
            Button(isTransforming ? l10n.t(.formatting) : l10n.t(.format)) {
                formatJSON()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isTransforming)
        } else {
            Button(isTransforming ? l10n.t(.comparing) : l10n.t(.compare)) {
                compareJSON()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isTransforming)
        }
    }

    /// 溢出折叠的操作按钮组：用 ViewThatFits 从「全部平铺」到「逐步折叠进菜单」
    /// 挑选第一个能放下的候选布局，去掉了原横向 ScrollView 包裹，避免闪烁。
    @ViewBuilder
    private func adaptiveActionBar() -> some View {
        let collapsible = collapsibleActionSpecs
        // 显式枚举候选，避免 ViewThatFits 把 ForEach 当作单一候选。
        // 可折叠按钮当前最多 3 个（格式化模式：压缩 / Diff / 转义），从全平铺逐级折叠；
        // visibleCount 大于实际数量时 prefix 自动截断，与低位候选等价，
        // ViewThatFits 取首个能放下者，无副作用（保留 4 位候选为将来扩展留余量）。
        ViewThatFits(in: .horizontal) {
            actionBarCandidate(visibleCount: 4, collapsible: collapsible)
            actionBarCandidate(visibleCount: 3, collapsible: collapsible)
            actionBarCandidate(visibleCount: 2, collapsible: collapsible)
            actionBarCandidate(visibleCount: 1, collapsible: collapsible)
            actionBarCandidate(visibleCount: 0, collapsible: collapsible)
        }
    }

    /// 单个候选布局：前 `visibleCount` 个次要按钮平铺，其余与「仅菜单项」合并进「更多」菜单。
    private func actionBarCandidate(visibleCount: Int, collapsible: [ActionButtonSpec]) -> some View {
        let visible = Array(collapsible.prefix(visibleCount))
        let overflow = Array(collapsible.dropFirst(visibleCount)) + overflowOnlyActionSpecs
        return HStack(spacing: 8) {
            primaryActionButton()

            ForEach(visible) { spec in
                Button(spec.title) { spec.action() }
                    .buttonStyle(OutlineActionButtonStyle())
                    .disabled(spec.isDisabled)
            }

            if !overflow.isEmpty {
                overflowActionMenu(overflow)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 「更多」下拉菜单，收纳折叠掉的按钮与仅菜单项。
    private func overflowActionMenu(_ specs: [ActionButtonSpec]) -> some View {
        Menu {
            ForEach(specs) { spec in
                Button(spec.title) { spec.action() }
                    .disabled(spec.isDisabled)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help(l10n.t(.more))
    }

    @ViewBuilder
    private func diffResultView() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t(.diffResultTitle))
                .font(.headline)
                .foregroundStyle(AppTheme.onSurface)

            if let diffResult {
                if diffResult.isIdentical {
                    Label(l10n.t(.diffIdentical), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.stringValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(diffResult.differences) { difference in
                                differenceRow(difference)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(l10n.t(.diffEmptyHint))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.outlineVariant, lineWidth: 1))
    }

    private func differenceRow(_ difference: JSONDifference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(l10n.diffKindTitle(difference.kind))
                    .font(.caption.bold())
                    .foregroundStyle(difference.kind.color)
                Text(difference.path)
                    .font(.system(.body, design: .monospaced).bold())
                    .textSelection(.enabled)
            }
            if let oldValue = difference.oldValue {
                Text(language == .cn ? "旧值：\(oldValue)" : "Old: \(oldValue)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let newValue = difference.newValue {
                Text(language == .cn ? "新值：\(newValue)" : "New: \(newValue)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func initializePageSelectionIfNeeded() {
        if pages.isEmpty {
            pages = [.initial]
        }

        if selectedPageID == nil || !pages.contains(where: { $0.id == selectedPageID }) {
            selectedPageID = pages.first?.id
        }
        nextPageNumber = max(nextPageNumber, pages.count + 1)
    }

    private func createNewPage() {
        updateCurrentPageForUnsavedChanges()
        let currentTitle = l10n.newPageTitle(nextPageNumber)
        let page = JSONWorkspacePage(title: currentTitle)
        nextPageNumber += 1
        pages.insert(page, at: 0)
        loadPage(page)
        logger.info("新建 JSON 页面成功，页面标识 \(page.id.uuidString, privacy: .public)，页面标题 \(page.title, privacy: .public)，新页面已放在侧边栏顶部")
    }

    private func saveCurrentPage() {
        initializePageSelectionIfNeeded()
        let pageID = activePageID
        let snapshot = currentPageSnapshot()

        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            let savedAt = Date()
            var page = JSONWorkspacePage(title: l10n.newPageTitle(nextPageNumber), snapshot: snapshot, updatedAt: savedAt)
            page.markSaved(at: savedAt)
            nextPageNumber += 1
            pages.insert(page, at: 0)
            selectedPageID = page.id
            persistWorkspaceNow(reason: "用户手动保存补建 JSON 页面")
            logger.info("保存当前页面时创建新的 JSON 页面，页面标识 \(page.id.uuidString, privacy: .public)，输入长度 \(inputText.count, privacy: .public)，输出长度 \(outputText.count, privacy: .public)")
            return
        }

        let savedAt = Date()
        pages[pageIndex].snapshot = snapshot
        pages[pageIndex].updatedAt = savedAt
        pages[pageIndex].markSaved(at: savedAt)
        persistWorkspaceNow(reason: "用户手动保存当前 JSON 页面")
        logger.info("保存当前页面成功，页面标识 \(pageID.uuidString, privacy: .public)，输入长度 \(inputText.count, privacy: .public)，输出长度 \(outputText.count, privacy: .public)")
    }

    private func updateCurrentPageForTextEditing() {
        guard !isLoadingPageSnapshot else {
            return
        }

        updateCurrentPageForUnsavedChanges()
        if autoSave {
            scheduleAutoSave()
        }
    }

    private func updateCurrentPageForUnsavedChanges() {
        initializePageSelectionIfNeeded()
        let pageID = activePageID
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            return
        }

        pages[pageIndex].snapshot = currentPageSnapshot()
        pages[pageIndex].updatedAt = Date()
    }

    private func toggleSidebarCollapsed() {
        isSidebarCollapsed.toggle()
        logger.info("切换 JSON 页面侧边栏状态，当前为 \(isSidebarCollapsed ? "收起" : "展开", privacy: .public)")
    }

    private func beginPageTitleEditing(_ page: JSONWorkspacePage) {
        if let editingPageID, editingPageID != page.id,
           let editingPage = pages.first(where: { $0.id == editingPageID }) {
            commitPageTitleEditing(editingPage)
        }

        editingPageID = page.id
        editingPageTitle = page.title
        editingOriginalPageTitle = page.title
        focusedEditingPageID = page.id
        logger.info("开始重命名 JSON 页面，页面标识 \(page.id.uuidString, privacy: .public)")
    }

    private func commitPageTitleEditing(_ page: JSONWorkspacePage) {
        guard editingPageID == page.id else {
            return
        }

        let normalizedTitle = editingPageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageIndex = pages.firstIndex(where: { $0.id == page.id }) else {
            clearPageTitleEditingState()
            return
        }

        let currentTitle = pages[pageIndex].title
        let nextTitle = normalizedTitle.isEmpty ? currentTitle : normalizedTitle
        guard nextTitle != currentTitle else {
            clearPageTitleEditingState()
            logger.info("重命名 JSON 页面未产生标题变更，跳过工作区持久化，页面标识 \(page.id.uuidString, privacy: .public)")
            return
        }

        let renamedAt = Date()
        pages[pageIndex].title = nextTitle
        pages[pageIndex].markTitleSaved(at: renamedAt)
        clearPageTitleEditingState()
        persistWorkspaceNow(reason: "重命名 JSON 页面后保存工作区", includesUnsavedPageSnapshots: false)
        logger.info("重命名 JSON 页面成功，页面标识 \(page.id.uuidString, privacy: .public)，页面标题 \(nextTitle, privacy: .public)")
    }

    private func cancelPageTitleEditing(_ page: JSONWorkspacePage? = nil) {
        if let page, editingPageID == page.id, let pageIndex = pages.firstIndex(where: { $0.id == page.id }) {
            pages[pageIndex].title = editingOriginalPageTitle.isEmpty ? page.title : editingOriginalPageTitle
        }
        clearPageTitleEditingState()
    }

    private func clearPageTitleEditingState() {
        editingPageID = nil
        editingPageTitle = ""
        editingOriginalPageTitle = ""
        focusedEditingPageID = nil
    }

    private func deletePage(_ page: JSONWorkspacePage) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == page.id }) else {
            return
        }

        let wasActivePage = page.id == activePageID
        pages.remove(at: pageIndex)
        if editingPageID == page.id {
            cancelPageTitleEditing()
        }

        if pages.isEmpty {
            let replacementPage = JSONWorkspacePage(title: l10n.newPageTitle(1))
            pages = [replacementPage]
            nextPageNumber = max(nextPageNumber, 2)
            loadPage(replacementPage)
        } else if wasActivePage {
            let replacementIndex = min(pageIndex, pages.count - 1)
            loadPage(pages[replacementIndex])
        } else {
            initializePageSelectionIfNeeded()
        }

        persistWorkspaceNow(reason: "删除 JSON 页面后保存工作区")
        logger.info("删除 JSON 页面成功，页面标识 \(page.id.uuidString, privacy: .public)，剩余页面数 \(pages.count, privacy: .public)")
    }

    private func clearAllHistory() {
        let removedPageCount = pages.count
        editingPageID = nil
        clearPageTitleEditingState()
        let replacementPage = JSONWorkspacePage(title: l10n.newPageTitle(1))
        pages = [replacementPage]
        nextPageNumber = 2
        loadPage(replacementPage)
        persistWorkspaceNow(reason: "用户从侧边栏清空全部 JSON 文档历史")
        logger.info("清空全部 JSON 文档历史成功，已删除页面数 \(removedPageCount, privacy: .public)，重置为单个空白页面")
    }

    private func switchWorkspaceMode(to mode: WorkspaceMode) {
        guard workspaceMode != mode else {
            return
        }
        workspaceMode = mode
        logger.info("切换 JSON 工作模式，当前为 \(mode.rawValue, privacy: .public)")
    }

    /// 首次运行迁移：老用户从未写过新外观键（空串）时，用旧 `legacyIsDarkMode`
    /// 推导并固化到新键，避免升级丢外观偏好。旧键保留不动（向后兼容 / 可回滚）。
    private func migrateAppearanceModeIfNeeded() {
        guard appearanceModeRaw.isEmpty else {
            return
        }
        let migrated: AppearanceMode = legacyIsDarkMode ? .dark : .light
        appearanceModeRaw = migrated.rawValue
        logger.info("迁移外观偏好到新键，旧暗色开关 \(legacyIsDarkMode, privacy: .public)，迁移后外观 \(migrated.rawValue, privacy: .public)")
    }

    private func openSettings() {
        isSettingsPresented = true
        logger.info("打开设置弹窗，当前语言 \(languageRaw, privacy: .public)，当前外观 \(appearanceMode.rawValue, privacy: .public)，当前字号 \(editorFontSize, privacy: .public)，自动保存 \(autoSave, privacy: .public)")
    }

    /// 自动保存开关变化：开启的瞬间对当前页触发一次保存（不批量处理历史页），
    /// 关闭则取消待执行的防抖任务，回到手动保存行为。
    private func handleAutoSaveToggle(_ isOn: Bool) {
        logger.info("切换自动保存开关，当前为 \(isOn ? "开启" : "关闭", privacy: .public)")
        if isOn {
            commitAutoSave()
        } else {
            autoSaveDebounceTask?.cancel()
            autoSaveDebounceTask = nil
        }
    }

    /// 防抖调度自动保存：编辑内容后 600ms 无新编辑则落盘，避免连续输入频繁写盘。
    private func scheduleAutoSave() {
        autoSaveDebounceTask?.cancel()
        autoSaveDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                commitAutoSave()
            }
        }
    }

    /// 提交一次自动保存：将当前页标记为已保存并立即持久化。
    private func commitAutoSave() {
        guard didLoadPersistedWorkspace else {
            return
        }
        initializePageSelectionIfNeeded()
        let pageID = activePageID
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            return
        }

        let savedAt = Date()
        pages[pageIndex].snapshot = currentPageSnapshot()
        pages[pageIndex].updatedAt = savedAt
        pages[pageIndex].markSaved(at: savedAt)
        persistWorkspaceNow(reason: "自动保存当前 JSON 页面")
        logger.info("自动保存当前 JSON 页面成功，页面标识 \(pageID.uuidString, privacy: .public)，输入长度 \(inputText.count, privacy: .public)，输出长度 \(outputText.count, privacy: .public)")
    }

    private func updateCurrentPageAfterTransform(with output: OutputTransformResult) {
        let pageID = activePageID
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            return
        }

        pages[pageIndex].snapshot = JSONWorkspacePageSnapshot(
            inputText: inputText,
            outputText: output.text,
            workspaceMode: workspaceMode,
            diffRightText: diffRightText,
            errorMessage: "",
            queryExpression: queryExpression,
            searchQuery: searchQuery,
            outputDisplayMode: outputDisplayMode,
            jsonTreeRoot: output.treeRoot,
            expandedTreeNodeIDs: output.treeRoot.map { [$0.id] } ?? [],
            outputLineIndex: output.lineIndex
        )
        pages[pageIndex].updatedAt = Date()
    }

    private func updateCurrentPageAfterTransformFailure(_ errorMessage: String) {
        let pageID = activePageID
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            return
        }

        var snapshot = currentPageSnapshot()
        snapshot.errorMessage = errorMessage
        pages[pageIndex].snapshot = snapshot
        pages[pageIndex].updatedAt = Date()
    }

    private func currentPageSnapshot() -> JSONWorkspacePageSnapshot {
        JSONWorkspacePageSnapshot(
            inputText: inputText,
            outputText: outputText,
            workspaceMode: workspaceMode,
            diffRightText: diffRightText,
            errorMessage: errorMessage,
            queryExpression: queryExpression,
            searchQuery: searchQuery,
            outputDisplayMode: outputDisplayMode,
            jsonTreeRoot: jsonTreeRoot,
            expandedTreeNodeIDs: expandedTreeNodeIDs,
            outputLineIndex: outputLineIndex
        )
    }

    private func selectPage(_ page: JSONWorkspacePage) {
        guard page.id != activePageID else {
            return
        }

        updateCurrentPageForUnsavedChanges()
        guard let latestPage = pages.first(where: { $0.id == page.id }) else {
            return
        }

        loadPage(latestPage)
        logger.info("切换 JSON 页面成功，页面标识 \(latestPage.id.uuidString, privacy: .public)，页面标题 \(latestPage.title, privacy: .public)")
    }

    private func loadPage(_ page: JSONWorkspacePage) {
        isLoadingPageSnapshot = true
        selectedPageID = page.id
        activeTransformID = nil
        isTransforming = false
        inputText = page.snapshot.inputText
        outputText = page.snapshot.outputText
        workspaceMode = page.snapshot.workspaceMode
        diffRightText = page.snapshot.diffRightText
        diffResult = nil
        errorMessage = page.snapshot.errorMessage
        queryExpression = page.snapshot.queryExpression
        searchQuery = page.snapshot.searchQuery
        currentMatchIndex = 0
        outputMatchRanges = []
        treeSearchMatches = []
        outputDisplayMode = page.snapshot.outputDisplayMode
        jsonTreeRoot = page.snapshot.jsonTreeRoot
        expandedTreeNodeIDs = page.snapshot.expandedTreeNodeIDs
        outputLineIndex = page.snapshot.outputLineIndex
        isOutputSearchSkippedForSize = page.snapshot.outputLineIndex.isVirtualized && page.snapshot.outputDisplayMode == .text
        outputRenderRevision += 1
        outputScrollRevision += 1
        refreshSearchMatches()
        isLoadingPageSnapshot = false
    }

    private func loadPersistedWorkspaceIfNeeded() {
        guard !didLoadPersistedWorkspace else {
            return
        }

        didLoadPersistedWorkspace = true
        do {
            guard let document = try JSONWorkspacePersistence.loadDocument() else {
                initializePageSelectionIfNeeded()
                if let page = selectedPage {
                    loadPage(page)
                }
                logger.info("未发现持久化 JSON 工作区，使用默认空白页面")
                return
            }

            let restoredPages = document.pages.map(JSONWorkspacePage.init(persistencePage:))
            pages = restoredPages.isEmpty ? [.initial] : restoredPages
            nextPageNumber = max(document.nextPageNumber, pages.count + 1)
            selectedPageID = document.selectedPageID
            initializePageSelectionIfNeeded()
            if let page = selectedPage {
                loadPage(page)
            }
            logger.info("加载持久化 JSON 工作区成功，页面数 \(pages.count, privacy: .public)，选中页面标识 \(activePageID.uuidString, privacy: .public)")
        } catch {
            initializePageSelectionIfNeeded()
            if let page = selectedPage {
                loadPage(page)
            }
            logger.error("加载持久化 JSON 工作区失败，将使用默认页面，错误 \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistWorkspaceNow(reason: String, includesUnsavedPageSnapshots: Bool = true) {
        guard didLoadPersistedWorkspace else {
            return
        }

        do {
            let document = includesUnsavedPageSnapshots
                ? persistenceDocument()
                : persistenceDocumentPreservingUnsavedSnapshots()
            try JSONWorkspacePersistence.save(document)
            logger.info("立即持久化 JSON 工作区成功，原因 \(reason, privacy: .public)，页面数 \(document.pages.count, privacy: .public)")
        } catch {
            logger.error("立即持久化 JSON 工作区失败，原因 \(reason, privacy: .public)，错误 \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistenceDocument() -> JSONWorkspacePersistenceDocument {
        JSONWorkspacePersistenceDocument(
            version: JSONWorkspacePersistence.documentVersion,
            pages: pages.map(\.persistencePage),
            selectedPageID: selectedPageID,
            nextPageNumber: nextPageNumber
        )
    }

    private func persistenceDocumentPreservingUnsavedSnapshots() -> JSONWorkspacePersistenceDocument {
        JSONWorkspacePersistenceDocument(
            version: JSONWorkspacePersistence.documentVersion,
            pages: pages.map { page in
                page.hasUnsavedSnapshot ? page.savedSnapshotPersistencePage : page.persistencePage
            },
            selectedPageID: selectedPageID,
            nextPageNumber: nextPageNumber
        )
    }

    private func clipboardImportBanner(_ clipboardText: String) -> some View {
        HStack(spacing: 10) {
            Text(l10n.t(.clipboardBanner))
                .foregroundStyle(AppTheme.onSurfaceVariant)

            Spacer()

            Button(l10n.t(.formatClipboard)) {
                inputText = clipboardText
                externalInputStore.clearClipboardOffer()
                formatJSON()
            }
            .buttonStyle(OutlineActionButtonStyle())

            Button(l10n.t(.ignore)) {
                externalInputStore.clearClipboardOffer()
            }
            .buttonStyle(OutlineActionButtonStyle())
        }
        .padding(12)
        .background(AppTheme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 输入卡片：标题栏「INPUT」+ Paste + 内容 + 底部 footer（JS 查询迷你控制台）。
    private func editor<Footer: View>(
        title: String,
        text: Binding<String>,
        showLineNumbers: Bool,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(AppTheme.onSurfaceVariant)

                Spacer()

                Button(l10n.t(.paste)) {
                    pasteIntoInput(text)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(AppTheme.surfaceContainerLow)

            Divider()

            AutoPairingTextEditor(text: text, fontSize: CGFloat(editorFontSize))
                .background(AppTheme.surface)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.outlineVariant, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
    }

    private func pasteIntoInput(_ text: Binding<String>) {
        guard let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty else {
            logger.info("粘贴到输入区跳过，剪贴板无可用文本")
            return
        }
        text.wrappedValue = clipboard
        logger.info("从剪贴板粘贴到输入区成功，文本长度 \(clipboard.count, privacy: .public)")
    }

    /// JS 查询迷你控制台，固定在输入卡片底部。
    private func queryExpressionBar() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            HStack(spacing: 8) {
                Text("JS")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.outline)

                TextField(l10n.t(.queryPlaceholder), text: $queryExpression)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppTheme.onSurface)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppTheme.outlineVariant, lineWidth: 1)
                    )
                    .onSubmit {
                        runQueryExpression()
                    }
                    .disabled(isTransforming)

                Button(l10n.t(.run)) {
                    runQueryExpression()
                }
                .buttonStyle(OutlineActionButtonStyle())
                .disabled(inputText.isEmpty || queryExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTransforming)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(AppTheme.surfaceContainerLow)
        .help(l10n.t(.queryHint))
    }

    /// 输出卡片：标题栏「OUTPUT」+ Text/Tree 切换 + 行号栏 + 内容。
    private func outputEditor(title: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(AppTheme.onSurfaceVariant)

                Spacer()

                if outputDisplayMode == .tree {
                    Button(l10n.t(.expandAll)) {
                        expandEntireTree()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.primary)
                    .disabled(jsonTreeRoot == nil)

                    Button(l10n.t(.collapseAll)) {
                        collapseEntireTree()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.primary)
                    .disabled(jsonTreeRoot == nil)
                }

                outputModeSwitcher()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(AppTheme.surfaceContainerLow)

            Divider()

            HStack(spacing: 0) {
                if outputDisplayMode == .text {
                    outputLineNumberGutter()
                    Divider()
                }

                Group {
                    switch outputDisplayMode {
                    case .text:
                        HighlightedOutputView(
                            outputText: outputText,
                            lineIndex: outputLineIndex,
                            isDarkMode: effectiveIsDarkMode,
                            matchRanges: outputMatchRanges,
                            currentMatchIndex: safeCurrentMatchIndex,
                            currentMatchRange: currentMatchRange,
                            renderRevision: outputRenderRevision,
                            scrollRevision: outputScrollRevision,
                            language: language,
                            fontSize: CGFloat(editorFontSize)
                        )
                    case .tree:
                        JSONTreeView(
                            root: jsonTreeRoot,
                            expandedNodeIDs: $expandedTreeNodeIDs,
                            searchMatches: treeSearchMatches,
                            currentMatchIndex: safeActiveMatchIndex,
                            language: language
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppTheme.surface)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.outlineVariant, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
    }

    /// 输出文本视图的行号栏（MVP：按行数生成，与内容行数对齐，随内容纵向滚动同步交由二期）。
    private func outputLineNumberGutter() -> some View {
        let lineCount = max(min(outputLineIndex.lineCount, 5_000), 1)
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...lineCount, id: \.self) { line in
                    Text("\(line)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AppTheme.outline.opacity(0.6))
                        .frame(height: 18, alignment: .trailing)
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 44)
        .background(AppTheme.surfaceContainerLow.opacity(0.4))
        .disabled(true)
    }

    private func outputModeSwitcher() -> some View {
        HStack(spacing: 2) {
            ForEach(OutputDisplayMode.allCases) { mode in
                let isSelected = mode == outputDisplayMode
                Button {
                    guard !(outputText.isEmpty || isTransforming) else {
                        return
                    }
                    outputDisplayMode = mode
                } label: {
                    Text(mode.title(l10n))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? AppTheme.onSurface : AppTheme.onSurfaceVariant)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? AppTheme.surface : Color.clear)
                        )
                        .shadow(color: isSelected ? Color.black.opacity(0.08) : Color.clear, radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.surfaceContainer)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.outlineVariant, lineWidth: 1)
        )
        .disabled(outputText.isEmpty || isTransforming)
    }

    private func formatJSON() {
        transformInput(actionKey: .actionFormat, JSONFormatterService.format)
    }

    private func compareJSON() {
        let leftInput = inputText
        let rightInput = diffRightText
        guard !leftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidateActiveTransform()
            diffResult = nil
            errorMessage = l10n.t(.diffLeftEmpty)
            return
        }
        guard !rightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidateActiveTransform()
            diffResult = nil
            errorMessage = l10n.t(.diffRightEmpty)
            return
        }

        let transformID = UUID()
        activeTransformID = transformID
        isTransforming = true
        errorMessage = ""
        diffResult = nil
        logger.info("开始执行本地 JSON Diff，左侧输入长度 \(leftInput.count, privacy: .public)，右侧输入长度 \(rightInput.count, privacy: .public)")

        Task.detached(priority: .userInitiated) {
            let result = Result {
                try JSONFormatterService.diff(leftInput, rightInput)
            }

            await MainActor.run {
                guard activeTransformID == transformID else {
                    logger.info("忽略已过期的 JSON Diff 结果")
                    return
                }

                isTransforming = false
                activeTransformID = nil
                switch result {
                case .success(let result):
                    diffResult = result
                    logger.info("JSON Diff 成功，差异数量 \(result.differences.count, privacy: .public)")
                case .failure(let error):
                    errorMessage = l10n.failure(.actionCompare, detail: error.localizedDescription)
                    logger.error("JSON Diff 失败，错误 \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func runQueryExpression() {
        let expression = queryExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = l10n.t(.queryNeedInput)
            logger.info("跳过 JS 查询，输入为空")
            return
        }
        guard !expression.isEmpty else {
            errorMessage = l10n.t(.queryNeedExpression)
            logger.info("跳过 JS 查询，表达式为空")
            return
        }

        transformInput(actionKey: .actionQuery) { input in
            try JSONFormatterService.evaluateQuery(input, expression: expression)
        }
    }

    private func compactJSON() {
        transformInput(actionKey: .actionCompress, JSONFormatterService.compact)
    }

    private func escapeJSON() {
        transformInput(actionKey: .actionEscape, JSONFormatterService.escape)
    }

    private func escapeAndCopyJSON() {
        transformInput(actionKey: .actionEscapeAndCopy, copyAfterSuccess: true, JSONFormatterService.escape)
    }

    private func transformInput(
        actionKey: LocKey,
        copyAfterSuccess: Bool = false,
        _ transform: @escaping @Sendable (String) throws -> String
    ) {
        let input = inputText
        let actionName = l10n.t(actionKey)
        let transformID = UUID()
        activeTransformID = transformID
        isTransforming = true
        errorMessage = ""
        logger.info("开始执行 JSON \(actionName, privacy: .public)，输入长度 \(input.count, privacy: .public)")

        Task.detached(priority: .userInitiated) {
            let result = Result {
                let output = try transform(input)
                return OutputTransformResult(
                    text: output,
                    lineIndex: OutputLineIndex(text: output),
                    treeRoot: try? JSONTreeBuilder.build(from: output)
                )
            }

            await MainActor.run {
                guard activeTransformID == transformID else {
                    logger.info("忽略已过期的 JSON \(actionName, privacy: .public) 结果")
                    return
                }

                isTransforming = false
                activeTransformID = nil

                switch result {
                case .success(let output):
                    currentMatchIndex = 0
                    outputMatchRanges = []
                    treeSearchMatches = []
                    outputLineIndex = output.lineIndex
                    isOutputSearchSkippedForSize = output.lineIndex.isVirtualized && outputDisplayMode == .text
                    outputText = output.text
                    jsonTreeRoot = output.treeRoot
                    expandedTreeNodeIDs = output.treeRoot.map { [$0.id] } ?? []
                    updateCurrentPageAfterTransform(with: output)
                    outputRenderRevision += 1
                    if copyAfterSuccess {
                        copyToPasteboard(output.text, actionName: actionName)
                    }
                    logger.info("JSON \(actionName, privacy: .public) 成功，输出长度 \(output.text.count, privacy: .public)，大文件虚拟化 \(output.lineIndex.isVirtualized, privacy: .public)")
                case .failure(let error):
                    let message = l10n.failure(actionKey, detail: error.localizedDescription)
                    errorMessage = message
                    updateCurrentPageAfterTransformFailure(message)
                    logger.error("JSON \(actionName, privacy: .public) 失败，输入长度 \(input.count, privacy: .public)，错误 \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func acceptExternalJSON(_ request: ExternalJSONInputRequest) {
        loadPersistedWorkspaceIfNeeded()

        if request.opensInNewPage {
            createNewPage()
            logger.info("外部 JSON 输入已打开到新页面，来源 \(request.source, privacy: .public)，页面标识 \(activePageID.uuidString, privacy: .public)")
        } else {
            updateCurrentPageForUnsavedChanges()
        }

        inputText = request.text
        externalInputStore.clearClipboardOffer()
        formatJSON()
        externalInputStore.markFormatRequestHandled(request)
    }

    private func copyOutput() {
        copyToPasteboard(outputText, actionName: l10n.t(.actionCopyOutput))
    }

    private func copyToPasteboard(_ text: String, actionName: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logger.info("JSON \(actionName, privacy: .public) 写入剪贴板成功，输出长度 \(text.count, privacy: .public)")
    }

    private func clearAll() {
        inputText = ""
        outputText = ""
        diffRightText = ""
        diffResult = nil
        errorMessage = ""
        searchQuery = ""
        queryExpression = ""
        currentMatchIndex = 0
        outputMatchRanges = []
        treeSearchMatches = []
        isOutputSearchSkippedForSize = false
        outputLineIndex = .empty
        jsonTreeRoot = nil
        expandedTreeNodeIDs = []
        outputDisplayMode = .text
        activeTransformID = nil
        isTransforming = false
        outputRenderRevision += 1
        outputScrollRevision += 1
        updateCurrentPageForTextEditing()
        logger.info("清空 JSON 输入输出内容成功")
    }

    private func invalidateActiveTransform() {
        guard activeTransformID != nil || isTransforming else {
            return
        }
        activeTransformID = nil
        isTransforming = false
    }

    private func openSearch() {
        isSearchVisible = true
        if outputDisplayMode == .text, outputLineIndex.isVirtualized {
            isOutputSearchSkippedForSize = true
        } else if outputDisplayMode == .tree {
            isOutputSearchSkippedForSize = false
        }
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func closeSearch() {
        isSearchVisible = false
        searchQuery = ""
        currentMatchIndex = 0
        outputMatchRanges = []
        treeSearchMatches = []
        isOutputSearchSkippedForSize = false
    }

    private func selectPreviousMatch(matchCount: Int) {
        guard matchCount > 0 else {
            return
        }

        currentMatchIndex = (safeActiveMatchIndex + matchCount - 1) % matchCount
        outputScrollRevision += 1
    }

    private func selectNextMatch(matchCount: Int) {
        guard matchCount > 0 else {
            return
        }

        currentMatchIndex = (safeActiveMatchIndex + 1) % matchCount
        outputScrollRevision += 1
    }

    private func searchStatusText(matchCount: Int) -> String {
        l10n.searchStatus(
            currentIndex: safeActiveMatchIndex,
            matchCount: matchCount,
            hasQuery: !searchQuery.isEmpty,
            isPaused: isOutputSearchSkippedForSize
        )
    }

    private func expandEntireTree() {
        guard let jsonTreeRoot else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            expandedTreeNodeIDs = jsonTreeRoot.allExpandableNodeIDs()
        }
        logger.info("展开整棵 JSON 树，节点数 \(expandedTreeNodeIDs.count, privacy: .public)")
    }

    private func collapseEntireTree() {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedTreeNodeIDs = []
        }
        logger.info("收起整棵 JSON 树，匹配数 \(treeSearchMatches.count, privacy: .public)")
    }

    private func refreshSearchMatches() {
        currentMatchIndex = 0
        outputScrollRevision += 1

        guard !searchQuery.isEmpty else {
            outputMatchRanges = []
            treeSearchMatches = []
            isOutputSearchSkippedForSize = false
            return
        }

        switch outputDisplayMode {
        case .text:
            treeSearchMatches = []
            guard !outputLineIndex.isVirtualized, outputText.utf8.count <= OutputRenderingPolicy.maxSearchableBytes else {
                outputMatchRanges = []
                isOutputSearchSkippedForSize = true
                logger.info("跳过大 JSON 输出文本搜索，输出字节数 \(outputText.utf8.count, privacy: .public)，大文件虚拟化 \(outputLineIndex.isVirtualized, privacy: .public)")
                return
            }

            isOutputSearchSkippedForSize = false
            outputMatchRanges = searchRanges(in: outputText, query: searchQuery)
        case .tree:
            outputMatchRanges = []
            isOutputSearchSkippedForSize = false
            guard let jsonTreeRoot else {
                treeSearchMatches = []
                return
            }

            treeSearchMatches = jsonTreeRoot.searchMatches(query: searchQuery, limit: OutputRenderingPolicy.maxSearchMatches)
            expandedTreeNodeIDs.formUnion(treeSearchMatches.flatMap(\.ancestorIDs))
        }
    }

    /// 顶栏快切：在 light↔dark 之间切换，依据当前有效外观决定去向，只写新键。
    private func toggleColorScheme() {
        let previousMode = appearanceMode
        let nextMode: AppearanceMode = effectiveIsDarkMode ? .light : .dark
        appearanceMode = nextMode
        logger.info("顶栏切换 JSON Formatter 外观，原外观 \(previousMode.rawValue, privacy: .public)，当前外观 \(nextMode.rawValue, privacy: .public)")
    }

    private func checkLatestRelease() {
        Task {
            do {
                let releaseInfo = try await ReleaseVersionChecker.fetchLatestRelease()

                guard !Task.isCancelled else {
                    return
                }

                let hasNewRelease = ReleaseVersionChecker.isNewerRelease(
                    currentVersion: currentAppVersion,
                    latestTagName: releaseInfo.tagName
                )

                guard hasNewRelease else {
                    logger.info("GitHub Releases 未发现新版本，当前版本 \(currentAppVersion, privacy: .public)，最新版本 \(releaseInfo.tagName, privacy: .public)")
                    return
                }

                await MainActor.run {
                    latestReleaseInfo = releaseInfo
                }
                logger.info("GitHub Releases 发现新版本，当前版本 \(currentAppVersion, privacy: .public)，最新版本 \(releaseInfo.tagName, privacy: .public)")
            } catch {
                logger.error("GitHub Releases 新版本检测失败，错误 \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func openLatestReleasePage() {
        let url = latestReleaseInfo?.htmlURL ?? ReleaseVersionChecker.releasesPageURL
        logger.info("打开 GitHub Releases 页面，页面地址 \(url.absoluteString, privacy: .public)")
        NSWorkspace.shared.open(url)
    }

    private func installFindShortcutMonitor() {
        guard keyDownMonitor == nil else {
            return
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = event.charactersIgnoringModifiers?.lowercased()
            let modifierFlags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let isFindShortcut = key == "f" && (modifierFlags == .command || modifierFlags == .control)
            let isEscape = event.keyCode == 53

            if isFindShortcut {
                openSearch()
                return nil
            }

            if isEscape, isSearchVisible {
                closeSearch()
                return nil
            }

            return event
        }
    }

    private func removeFindShortcutMonitor() {
        guard let keyDownMonitor else {
            return
        }

        NSEvent.removeMonitor(keyDownMonitor)
        self.keyDownMonitor = nil
    }
}

private struct AutoPairingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = NSFont.systemFontSize

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = AutoPairingTextView(frame: scrollView.contentView.bounds)
        textView.jsonFontSize = fontSize
        textView.delegate = context.coordinator
        textView.autoPairingDelegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.disableSmartJSONInputSubstitutions()
        textView.applyPlainJSONInputStyle(fontSize: fontSize)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        JSONInputTextViewLayout.configure(textView)
        textView.setPlainJSONInputString(text, fontSize: fontSize)
        context.coordinator.fontSize = fontSize
        context.coordinator.lastFontSize = fontSize

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AutoPairingTextView else {
            return
        }

        context.coordinator.text = $text
        context.coordinator.fontSize = fontSize
        textView.jsonFontSize = fontSize
        textView.disableSmartJSONInputSubstitutions()
        textView.applyPlainJSONInputStyle(fontSize: fontSize)
        // 字号变化需强制重设整段文本以刷新已有内容的字体（applyPlainJSONInputStyle 只影响
        // typingAttributes / font，不会重排已存在字符的属性）。
        let fontSizeChanged = context.coordinator.lastFontSize != fontSize
        context.coordinator.lastFontSize = fontSize
        guard !context.coordinator.isUpdatingFromTextView, textView.string != text || fontSizeChanged else {
            return
        }

        let selectedRanges = textView.selectedRanges
        textView.setPlainJSONInputString(text, fontSize: fontSize)
        textView.selectedRanges = clampedSelectionRanges(
            selectedRanges,
            preferredInsertionLocation: textView.string.utf16.count,
            textLength: (text as NSString).length
        )
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, AutoPairingTextViewDelegate {
        var text: Binding<String>
        var isUpdatingFromTextView = false
        var fontSize: CGFloat = NSFont.systemFontSize
        var lastFontSize: CGFloat = NSFont.systemFontSize

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            isUpdatingFromTextView = true
            text.wrappedValue = textView.string
            isUpdatingFromTextView = false
        }

        func insertAutoPair(open: String, close: String, in textView: NSTextView, replacementRange: NSRange) -> Bool {
            guard let range = effectiveInsertionRange(in: textView, replacementRange: replacementRange) else {
                return false
            }

            let currentText = textView.string as NSString
            let currentTextLength = currentText.length
            guard range.location != NSNotFound, range.location + range.length <= currentTextLength else {
                return false
            }

            if open == close,
               range.length == 0,
               range.location < currentTextLength,
               currentText.substring(with: NSRange(location: range.location, length: 1)) == close {
                textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return true
            }

            let selectedText = currentText.substring(with: range)
            let replacement = open + selectedText + close
            let replacementRange = NSRange(location: range.location, length: (replacement as NSString).length)
            let cursorRange = range.length == 0
                ? NSRange(location: range.location + (open as NSString).length, length: 0)
                : replacementRange

            return insertPlainText(replacement, in: textView, range: range, selectedRangeAfterInsert: cursorRange)
        }

        func insertLiteralSpace(in textView: NSTextView, replacementRange: NSRange) -> Bool {
            guard let range = effectiveInsertionRange(in: textView, replacementRange: replacementRange) else {
                return false
            }

            let cursorRange = NSRange(location: range.location + 1, length: 0)
            return insertPlainText(" ", in: textView, range: range, selectedRangeAfterInsert: cursorRange)
        }

        func textView(
            _ view: NSTextView,
            willCheckTextIn range: NSRange,
            options: [NSSpellChecker.OptionKey: Any],
            types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
        ) -> [NSSpellChecker.OptionKey: Any] {
            checkingTypes.pointee = 0
            return options
        }

        func textView(
            _ view: NSTextView,
            didCheckTextIn range: NSRange,
            types checkingTypes: NSTextCheckingTypes,
            options: [NSSpellChecker.OptionKey: Any],
            results: [NSTextCheckingResult],
            orthography: NSOrthography,
            wordCount: Int
        ) -> [NSTextCheckingResult] {
            []
        }

        private func insertPlainText(
            _ replacement: String,
            in textView: NSTextView,
            range: NSRange,
            selectedRangeAfterInsert: NSRange? = nil
        ) -> Bool {
            guard let textStorage = textView.textStorage else {
                return false
            }

            guard textView.shouldChangeText(in: range, replacementString: replacement) else {
                return false
            }

            let replacementRange = NSRange(location: range.location, length: (replacement as NSString).length)
            textView.applyPlainJSONInputStyle(fontSize: fontSize)
            textStorage.replaceCharacters(in: range, with: NSAttributedString(
                string: replacement,
                attributes: textView.plainJSONInputAttributes(fontSize: fontSize)
            ))
            textView.didChangeText()
            textView.setSelectedRange(selectedRangeAfterInsert ?? replacementRange)
            return true
        }

        private func effectiveInsertionRange(in textView: NSTextView, replacementRange: NSRange) -> NSRange? {
            let stringLength = (textView.string as NSString).length
            if let clampedReplacementRange = replacementRange.clamped(toLength: stringLength),
               replacementRange.location != NSNotFound {
                return clampedReplacementRange
            }

            let selectedRange = textView.selectedRange()
            if let clampedRange = selectedRange.clamped(toLength: stringLength), selectedRange.location != NSNotFound {
                return clampedRange
            }

            return NSRange(location: stringLength, length: 0)
        }
    }

    private func clampedSelectionRanges(
        _ ranges: [NSValue],
        preferredInsertionLocation: Int,
        textLength: Int
    ) -> [NSValue] {
        let clampedRanges = ranges.compactMap { rangeValue -> NSValue? in
            guard let range = rangeValue.rangeValue.clamped(toLength: textLength) else {
                return nil
            }
            return NSValue(range: range)
        }

        if !clampedRanges.isEmpty {
            return clampedRanges
        }

        let insertionLocation = min(max(preferredInsertionLocation, 0), textLength)
        return [NSValue(range: NSRange(location: insertionLocation, length: 0))]
    }
}

@MainActor
enum JSONInputTextViewLayout {
    static func configure(_ textView: NSTextView) {
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true

        // A vertically resizable NSTextView must not also track the clip view's height.
        // Otherwise bottom overscroll can repeatedly enlarge the document view.
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
    }
}

@MainActor
private protocol AutoPairingTextViewDelegate: AnyObject {
    func insertAutoPair(open: String, close: String, in textView: NSTextView, replacementRange: NSRange) -> Bool
    func insertLiteralSpace(in textView: NSTextView, replacementRange: NSRange) -> Bool
}

@MainActor
private final class AutoPairingTextView: NSTextView {
    weak var autoPairingDelegate: AutoPairingTextViewDelegate?
    /// 当前编辑器字号（设置弹窗可调，12–24pt）；SwiftUI 层每次 updateNSView 同步下来。
    var jsonFontSize: CGFloat = NSFont.systemFontSize

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle(fontSize: jsonFontSize)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle(fontSize: jsonFontSize)
        return didBecomeFirstResponder
    }

    override func didChangeText() {
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle(fontSize: jsonFontSize)
        super.didChangeText()
    }

    private let autoPairs: [String: String] = [
        "{": "}",
        "[": "]",
        "\"": "\""
    ]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle(fontSize: jsonFontSize)
        guard let text = insertString as? String, text.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        if text == " ", autoPairingDelegate?.insertLiteralSpace(in: self, replacementRange: replacementRange) == true {
            return
        }

        guard let close = autoPairs[text],
              autoPairingDelegate?.insertAutoPair(open: text, close: close, in: self, replacementRange: replacementRange) == true else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
    }
}

private extension NSTextView {
    func plainJSONInputAttributes(fontSize: CGFloat = NSFont.systemFontSize) -> [NSAttributedString.Key: Any] {
        [
            .font: AppTheme.editorFont(size: fontSize),
            .foregroundColor: NSColor.labelColor
        ]
    }

    func applyPlainJSONInputStyle(fontSize: CGFloat = NSFont.systemFontSize) {
        font = AppTheme.editorFont(size: fontSize)
        textColor = .labelColor
        insertionPointColor = .labelColor
        typingAttributes = plainJSONInputAttributes(fontSize: fontSize)
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
    }

    func setPlainJSONInputString(_ string: String, fontSize: CGFloat = NSFont.systemFontSize) {
        textStorage?.setAttributedString(NSAttributedString(
            string: string,
            attributes: plainJSONInputAttributes(fontSize: fontSize)
        ))
        applyPlainJSONInputStyle(fontSize: fontSize)
    }

    func disableSmartJSONInputSubstitutions() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        enabledTextCheckingTypes = 0
    }
}

private extension NSRange {
    func clamped(toLength length: Int) -> NSRange? {
        guard location != NSNotFound else {
            return nil
        }

        let safeLocation = min(max(location, 0), length)
        let safeEnd = min(max(location + self.length, safeLocation), length)
        return NSRange(location: safeLocation, length: safeEnd - safeLocation)
    }
}

private struct HighlightedOutputView: NSViewRepresentable {
    let outputText: String
    let lineIndex: OutputLineIndex
    let isDarkMode: Bool
    let matchRanges: [NSRange]
    let currentMatchIndex: Int
    let currentMatchRange: NSRange?
    let renderRevision: Int
    let scrollRevision: Int
    var language: AppLanguage = .cn
    var fontSize: CGFloat = NSFont.systemFontSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = VirtualizedOutputScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.outputCoordinator = context.coordinator

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = AppTheme.editorFont(size: fontSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        if let virtualizedScrollView = scrollView as? VirtualizedOutputScrollView {
            virtualizedScrollView.outputCoordinator = context.coordinator
        }

        context.coordinator.configure(
            textView: textView,
            scrollView: scrollView,
            outputText: outputText,
            lineIndex: lineIndex,
            isDarkMode: isDarkMode,
            matchRanges: matchRanges,
            currentMatchIndex: currentMatchIndex,
            language: language,
            fontSize: fontSize
        )

        let usesPlainRendering = outputText.utf8.count > OutputRenderingPolicy.maxHighlightedBytes
        let usesVirtualizedRendering = lineIndex.isVirtualized
        // 字号变化不会 bump renderRevision，但需要重排输出文本，故纳入所有分支判定。
        let fontSizeChanged = context.coordinator.lastFontSize != fontSize
        let shouldUpdateText: Bool
        if usesVirtualizedRendering {
            shouldUpdateText = context.coordinator.lastRenderRevision != renderRevision
                || context.coordinator.lastUsesVirtualizedRendering != usesVirtualizedRendering
                || fontSizeChanged
        } else if usesPlainRendering {
            shouldUpdateText = context.coordinator.lastRenderRevision != renderRevision
                || context.coordinator.lastUsesPlainRendering != usesPlainRendering
                || context.coordinator.lastUsesVirtualizedRendering != usesVirtualizedRendering
                || fontSizeChanged
        } else {
            shouldUpdateText = context.coordinator.lastRenderRevision != renderRevision
                || context.coordinator.lastUsesPlainRendering != usesPlainRendering
                || context.coordinator.lastUsesVirtualizedRendering != usesVirtualizedRendering
                || context.coordinator.lastIsDarkMode != isDarkMode
                || context.coordinator.lastMatchRanges != matchRanges
                || context.coordinator.lastCurrentMatchIndex != currentMatchIndex
                || fontSizeChanged
        }

        if shouldUpdateText {
            applyOutputText(to: textView, scrollView: scrollView, usesPlainRendering: usesPlainRendering, usesVirtualizedRendering: usesVirtualizedRendering, coordinator: context.coordinator)
            context.coordinator.lastRenderRevision = renderRevision
            context.coordinator.lastUsesPlainRendering = usesPlainRendering
            context.coordinator.lastUsesVirtualizedRendering = usesVirtualizedRendering
            context.coordinator.lastIsDarkMode = isDarkMode
            context.coordinator.lastMatchRanges = matchRanges
            context.coordinator.lastCurrentMatchIndex = currentMatchIndex
            context.coordinator.lastFontSize = fontSize
        }

        guard context.coordinator.lastScrollRevision != scrollRevision else {
            return
        }

        context.coordinator.lastScrollRevision = scrollRevision
        if let currentMatchRange, !usesVirtualizedRendering {
            textView.scrollRangeToVisible(currentMatchRange)
        }
    }

    private func applyOutputText(
        to textView: NSTextView,
        scrollView: NSScrollView,
        usesPlainRendering: Bool,
        usesVirtualizedRendering: Bool,
        coordinator: Coordinator
    ) {
        if usesVirtualizedRendering {
            // 大 JSON 不把全文塞入 NSTextView，避免一次性文本布局导致右侧滚动卡顿。
            coordinator.resetVirtualizedRendering(scrollView: scrollView)
            return
        }

        coordinator.disableVirtualizedRendering()

        // 大 JSON 全量逐字符高亮会在主线程产生大量属性写入，降级为纯文本保证滚动和选择流畅。
        if usesPlainRendering {
            textView.string = outputText
            textView.textColor = .labelColor
            textView.font = AppTheme.editorFont(size: fontSize)
            return
        }

        let attributedText = buildHighlightedJSONText(
            outputText,
            isDarkMode: isDarkMode,
            fontSize: fontSize,
            matchRanges: matchRanges,
            currentMatchIndex: currentMatchIndex
        )
        textView.textStorage?.setAttributedString(attributedText)
    }

    @MainActor final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var outputText = ""
        var lineIndex = OutputLineIndex.empty
        var isDarkMode = false
        var matchRanges: [NSRange] = []
        var currentMatchIndex = 0
        var lastRenderRevision = -1
        var lastScrollRevision = -1
        var lastUsesPlainRendering = false
        var lastUsesVirtualizedRendering = false
        var lastIsDarkMode = false
        var lastMatchRanges: [NSRange] = []
        var lastCurrentMatchIndex = 0
        var lastFontSize: CGFloat = -1
        var fontSize: CGFloat = NSFont.systemFontSize
        var renderedChunkIndex = 0
        var isUpdatingVirtualizedContent = false
        var language: AppLanguage = .cn

        func configure(
            textView: NSTextView,
            scrollView: NSScrollView,
            outputText: String,
            lineIndex: OutputLineIndex,
            isDarkMode: Bool,
            matchRanges: [NSRange],
            currentMatchIndex: Int,
            language: AppLanguage,
            fontSize: CGFloat
        ) {
            self.textView = textView
            self.scrollView = scrollView
            self.outputText = outputText
            self.lineIndex = lineIndex
            self.isDarkMode = isDarkMode
            self.matchRanges = matchRanges
            self.currentMatchIndex = currentMatchIndex
            self.language = language
            self.fontSize = fontSize
        }

        func resetVirtualizedRendering(scrollView: NSScrollView) {
            renderedChunkIndex = 0
            scrollView.contentView.scroll(to: .zero)
            appendVirtualizedLinesIfNeeded(force: true)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func disableVirtualizedRendering() {
            renderedChunkIndex = 0
            scrollView?.contentView.postsBoundsChangedNotifications = false
        }

        func scrollViewDidScroll(_ scrollView: NSScrollView) {
            guard lineIndex.isVirtualized, !isUpdatingVirtualizedContent else {
                return
            }

            let contentHeight = scrollView.documentView?.bounds.height ?? 0
            if scrollView.documentVisibleRect.maxY + OutputRenderingPolicy.virtualizedAppendPreloadHeight >= contentHeight {
                appendVirtualizedLinesIfNeeded(force: false)
            }
        }

        private func appendVirtualizedLinesIfNeeded(force: Bool) {
            guard lineIndex.isVirtualized, let textView, let scrollView, renderedChunkIndex < lineIndex.chunkCount else {
                return
            }

            let chunkStartIndex = renderedChunkIndex
            let chunkBatchSize = force
                ? OutputRenderingPolicy.virtualizedInitialChunks
                : OutputRenderingPolicy.virtualizedAppendChunks
            let chunkEndIndex = min(chunkStartIndex + chunkBatchSize, lineIndex.chunkCount)
            let chunk = lineIndex.textWindow(
                in: outputText,
                startChunk: chunkStartIndex,
                chunkCount: chunkEndIndex - chunkStartIndex
            )
            let loadedLineCount = lineIndex.loadedLineCount(upToChunk: chunkEndIndex)
            let prefix = chunkStartIndex == 0
                ? L10n(language: language).largeFileLoadedNotice(loadedLines: loadedLineCount, totalLines: lineIndex.lineCount)
                : ""

            isUpdatingVirtualizedContent = true
            if chunkStartIndex == 0 {
                textView.string = prefix + chunk
                textView.textColor = .labelColor
                textView.font = AppTheme.editorFont(size: fontSize)
            } else {
                textView.textStorage?.append(NSAttributedString(
                    string: prefix + chunk,
                    attributes: [
                        .font: AppTheme.editorFont(size: fontSize),
                        .foregroundColor: NSColor.labelColor
                    ]
                ))
            }
            renderedChunkIndex = chunkEndIndex
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isUpdatingVirtualizedContent = false
        }
    }
}

@MainActor
private final class VirtualizedOutputScrollView: NSScrollView {
    weak var outputCoordinator: HighlightedOutputView.Coordinator?

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        outputCoordinator?.scrollViewDidScroll(self)
    }
}

private func searchRanges(in text: String, query: String) -> [NSRange] {
    guard !text.isEmpty, !query.isEmpty else {
        return []
    }

    let nsText = text as NSString
    var ranges: [NSRange] = []
    var searchRange = NSRange(location: 0, length: nsText.length)

    while searchRange.location < nsText.length && ranges.count < OutputRenderingPolicy.maxSearchMatches {
        let foundRange = nsText.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        )

        guard foundRange.location != NSNotFound else {
            break
        }

        ranges.append(foundRange)

        let nextLocation = foundRange.location + max(foundRange.length, 1)
        guard nextLocation <= nsText.length else {
            break
        }

        searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
    }

    return ranges
}

private enum OutputDisplayMode: String, CaseIterable, Identifiable {
    case text
    case tree

    var id: String {
        rawValue
    }

    func title(_ l10n: L10n) -> String {
        switch self {
        case .text:
            return l10n.t(.outputModeText)
        case .tree:
            return l10n.t(.outputModeTree)
        }
    }
}

private enum WorkspaceMode: String, CaseIterable, Identifiable {
    case format
    case diff

    var id: String { rawValue }

    func title(_ l10n: L10n) -> String {
        switch self {
        case .format:
            return l10n.t(.format)
        case .diff:
            return l10n.t(.jsonDiff)
        }
    }

    func description(_ l10n: L10n) -> String {
        switch self {
        case .format:
            return l10n.language == .cn
                ? "粘贴 JSON 后按 Cmd+Enter 格式化；Cmd+T 新建页面；Cmd+S 保存到侧边栏；Cmd+F 或 Ctrl+F 搜索输出。"
                : "Paste JSON and press Cmd+Enter to format; Cmd+T for a new document; Cmd+S to save into the sidebar; Cmd+F or Ctrl+F to search output."
        case .diff:
            return l10n.language == .cn
                ? "左右输入两份 JSON 后按 Cmd+Enter 比较；对象键顺序会忽略，数组顺序仍参与比较，所有数据仅在本地处理。"
                : "Enter two JSON values and press Cmd+Enter to compare; object key order is ignored, array order still counts, all processing stays local."
        }
    }
}

private extension JSONDifferenceKind {
    var color: Color {
        switch self {
        case .added:
            return AppTheme.stringValue
        case .removed:
            return AppTheme.error
        case .changed:
            return AppTheme.accent
        }
    }
}

private struct JSONWorkspacePage: Identifiable, Equatable {
    static let initial = JSONWorkspacePage(title: "页面 1")

    let id: UUID
    var title: String
    var snapshot: JSONWorkspacePageSnapshot
    var updatedAt: Date
    private var savedSnapshot: JSONWorkspacePageSnapshot
    private var savedTitle: String
    private var savedUpdatedAt: Date

    var isUnsaved: Bool {
        title != savedTitle || snapshot != savedSnapshot
    }

    var hasUnsavedSnapshot: Bool {
        snapshot != savedSnapshot
    }

    var subtitle: String {
        let text = snapshot.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text.replacingOccurrences(of: "\n", with: " ")
        }

        return "空白页面"
    }

    var shortTitle: String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pagePrefix = "页面 "
        if normalizedTitle.hasPrefix(pagePrefix) {
            let suffix = normalizedTitle.dropFirst(pagePrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstSuffixCharacter = suffix.first {
                return String(firstSuffixCharacter)
            }
        }

        guard let firstCharacter = normalizedTitle.first else {
            return "页"
        }

        return String(firstCharacter).uppercased()
    }

    var persistencePage: JSONWorkspacePersistencePage {
        persistencePage(for: snapshot, updatedAt: updatedAt)
    }

    var savedSnapshotPersistencePage: JSONWorkspacePersistencePage {
        persistencePage(for: savedSnapshot, updatedAt: savedUpdatedAt)
    }

    private func persistencePage(for snapshot: JSONWorkspacePageSnapshot, updatedAt: Date) -> JSONWorkspacePersistencePage {
        JSONWorkspacePersistencePage(
            id: id,
            title: title,
            inputText: snapshot.inputText,
            outputText: snapshot.outputText,
            workspaceMode: snapshot.workspaceMode.rawValue,
            diffRightText: snapshot.diffRightText,
            errorMessage: snapshot.errorMessage,
            queryExpression: snapshot.queryExpression,
            searchQuery: snapshot.searchQuery,
            outputDisplayMode: snapshot.outputDisplayMode.rawValue,
            updatedAt: updatedAt
        )
    }

    init(
        id: UUID = UUID(),
        title: String,
        snapshot: JSONWorkspacePageSnapshot = .empty,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.snapshot = snapshot
        self.updatedAt = updatedAt
        self.savedSnapshot = snapshot
        self.savedTitle = title
        self.savedUpdatedAt = updatedAt
    }

    mutating func markSaved(at date: Date = Date()) {
        savedTitle = title
        savedSnapshot = snapshot
        updatedAt = date
        savedUpdatedAt = date
    }

    mutating func markTitleSaved(at date: Date = Date()) {
        savedTitle = title
        updatedAt = date
        savedUpdatedAt = date
    }

    init(persistencePage: JSONWorkspacePersistencePage) {
        let outputLineIndex = OutputLineIndex(text: persistencePage.outputText)
        let outputDisplayMode = OutputDisplayMode(rawValue: persistencePage.outputDisplayMode) ?? .text
        let treeRoot = outputDisplayMode == .tree ? try? JSONTreeBuilder.build(from: persistencePage.outputText) : nil
        self.init(
            id: persistencePage.id,
            title: persistencePage.title,
            snapshot: JSONWorkspacePageSnapshot(
                inputText: persistencePage.inputText,
                outputText: persistencePage.outputText,
                workspaceMode: WorkspaceMode(rawValue: persistencePage.workspaceMode ?? "") ?? .format,
                diffRightText: persistencePage.diffRightText ?? "",
                errorMessage: persistencePage.errorMessage,
                queryExpression: persistencePage.queryExpression,
                searchQuery: persistencePage.searchQuery,
                outputDisplayMode: outputDisplayMode,
                jsonTreeRoot: treeRoot,
                expandedTreeNodeIDs: treeRoot.map { [$0.id] } ?? [],
                outputLineIndex: outputLineIndex
            ),
            updatedAt: persistencePage.updatedAt
        )
    }
}

private struct JSONWorkspacePageSnapshot: Equatable {
    static let empty = JSONWorkspacePageSnapshot(
        inputText: "",
        outputText: "",
        workspaceMode: .format,
        diffRightText: "",
        errorMessage: "",
        queryExpression: "",
        searchQuery: "",
        outputDisplayMode: .text,
        jsonTreeRoot: nil,
        expandedTreeNodeIDs: [],
        outputLineIndex: .empty
    )

    var inputText: String
    var outputText: String
    var workspaceMode: WorkspaceMode
    var diffRightText: String
    var errorMessage: String
    var queryExpression: String
    var searchQuery: String
    var outputDisplayMode: OutputDisplayMode
    var jsonTreeRoot: JSONTreeNode?
    var expandedTreeNodeIDs: Set<String>
    var outputLineIndex: OutputLineIndex
}

private struct OutputTransformResult: Sendable {
    let text: String
    let lineIndex: OutputLineIndex
    let treeRoot: JSONTreeNode?
}

private struct OutputLineIndex: Equatable, Sendable {
    static let empty = OutputLineIndex(
        chunkStartUTF16Offsets: [0],
        chunkStartLineNumbers: [0],
        lineCount: 1,
        totalUTF16Length: 0,
        totalBytes: 0
    )

    let chunkStartUTF16Offsets: [Int]
    let chunkStartLineNumbers: [Int]
    let lineCount: Int
    let totalUTF16Length: Int
    let totalBytes: Int

    var chunkCount: Int {
        max(chunkStartUTF16Offsets.count, 1)
    }

    var isVirtualized: Bool {
        totalBytes > OutputRenderingPolicy.maxVirtualizedBytes || lineCount > OutputRenderingPolicy.maxVirtualizedLines
    }

    init(text: String) {
        totalUTF16Length = text.utf16.count
        totalBytes = text.utf8.count

        guard !text.isEmpty else {
            chunkStartUTF16Offsets = [0]
            chunkStartLineNumbers = [0]
            lineCount = 1
            return
        }

        var offsets: [Int] = [0]
        var lineNumbers: [Int] = [0]
        offsets.reserveCapacity(min(1_000, max(text.utf8.count / OutputRenderingPolicy.virtualizedMaxChunkUTF16Length, 1)))
        lineNumbers.reserveCapacity(offsets.capacity)

        var utf16Offset = 0
        var currentLineNumber = 0
        var currentChunkStartUTF16 = 0
        var currentChunkStartLineNumber = 0

        for character in text {
            utf16Offset += character.utf16.count
            if character == "\n" {
                currentLineNumber += 1
            }

            guard utf16Offset < totalUTF16Length else {
                continue
            }

            let chunkLineSpan = currentLineNumber - currentChunkStartLineNumber
            let chunkUTF16Length = utf16Offset - currentChunkStartUTF16
            if chunkLineSpan >= OutputRenderingPolicy.virtualizedChunkLines
                || chunkUTF16Length >= OutputRenderingPolicy.virtualizedMaxChunkUTF16Length {
                offsets.append(utf16Offset)
                lineNumbers.append(currentLineNumber)
                currentChunkStartUTF16 = utf16Offset
                currentChunkStartLineNumber = currentLineNumber
            }
        }

        chunkStartUTF16Offsets = offsets
        chunkStartLineNumbers = lineNumbers
        lineCount = max(currentLineNumber + 1, 1)
    }

    private init(
        chunkStartUTF16Offsets: [Int],
        chunkStartLineNumbers: [Int],
        lineCount: Int,
        totalUTF16Length: Int,
        totalBytes: Int
    ) {
        self.chunkStartUTF16Offsets = chunkStartUTF16Offsets
        self.chunkStartLineNumbers = chunkStartLineNumbers
        self.lineCount = lineCount
        self.totalUTF16Length = totalUTF16Length
        self.totalBytes = totalBytes
    }

    func loadedLineCount(upToChunk chunkIndex: Int) -> Int {
        guard chunkIndex < chunkStartLineNumbers.count else {
            return lineCount
        }

        return max(chunkStartLineNumbers[max(chunkIndex, 0)], 1)
    }

    func textWindow(in text: String, startChunk: Int, chunkCount: Int) -> String {
        guard !text.isEmpty else {
            return ""
        }

        let safeStartChunk = min(max(startChunk, 0), max(self.chunkCount - 1, 0))
        let safeEndChunk = min(safeStartChunk + max(chunkCount, 0), self.chunkCount)
        let startUTF16 = chunkStartUTF16Offsets[safeStartChunk]
        let endUTF16 = safeEndChunk < chunkStartUTF16Offsets.count ? chunkStartUTF16Offsets[safeEndChunk] : totalUTF16Length
        let length = max(endUTF16 - startUTF16, 0)
        guard length > 0 else {
            return ""
        }

        let nsText = text as NSString
        return nsText.substring(with: NSRange(location: startUTF16, length: length))
    }
}

private enum OutputRenderingPolicy {
    static let maxHighlightedBytes = 300_000
    static let maxSearchableBytes = 1_000_000
    static let maxSearchMatches = 2_000
    static let maxVirtualizedBytes = 1_500_000
    static let maxVirtualizedLines = 20_000
    static let virtualizedChunkLines = 300
    static let virtualizedMaxChunkUTF16Length = 80_000
    static let virtualizedInitialChunks = 4
    static let virtualizedAppendChunks = 3
    static let virtualizedAppendPreloadHeight: CGFloat = 1_400
}

private func buildHighlightedJSONText(
    _ text: String,
    isDarkMode: Bool,
    fontSize: CGFloat,
    matchRanges: [NSRange],
    currentMatchIndex: Int
) -> NSAttributedString {
    let font = AppTheme.editorFont(size: fontSize)
    let attributedText = NSMutableAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
    )

    guard !text.isEmpty else {
        return attributedText
    }

    let levelColors = depthColors(isDarkMode: isDarkMode)
    var depth = 0
    var isInsideString = false
    var isEscaped = false

    for index in text.indices {
        let character = text[index]

        if !isInsideString && (character == "}" || character == "]") {
            depth = max(depth - 1, 0)
        }

        let characterRange = NSRange(index..<text.index(after: index), in: text)
        let color = levelColors[depth % levelColors.count]
        attributedText.addAttribute(.foregroundColor, value: color, range: characterRange)

        if isInsideString {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isInsideString = false
            }
        } else if character == "\"" {
            isInsideString = true
        } else if character == "{" || character == "[" {
            depth += 1
        }
    }

    for (index, range) in matchRanges.enumerated() {
        let color = index == currentMatchIndex
            ? NSColor.systemOrange.withAlphaComponent(0.65)
            : NSColor.systemYellow.withAlphaComponent(0.35)
        attributedText.addAttribute(.backgroundColor, value: color, range: range)
    }

    return attributedText
}

private func depthColors(isDarkMode: Bool) -> [NSColor] {
    if isDarkMode {
        return [
            NSColor.systemTeal,
            NSColor.systemGreen,
            NSColor.systemYellow,
            NSColor.systemOrange,
            NSColor.systemPink,
            NSColor.systemPurple,
            NSColor.systemBlue
        ]
    }

    return [
        NSColor.systemBlue,
        NSColor.systemPurple,
        NSColor.systemPink,
        NSColor.systemRed,
        NSColor.systemOrange,
        NSColor.systemGreen,
        NSColor.systemTeal
    ]
}
