import AppKit
import OSLog
import SwiftUI

struct ContentView: View {
    @ObservedObject var externalInputStore: ExternalJSONInputStore
    @AppStorage("jsonFormatterIsDarkMode") private var isDarkMode = false

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

    private var canSaveCurrentPage: Bool {
        selectedPage != nil
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

        return "开发版"
    }

    private var appVersionText: String {
        "版本 \(currentAppVersion)"
    }

    var body: some View {
        HSplitView {
            sidebarView()
                .frame(
                    minWidth: isSidebarCollapsed ? 64 : 190,
                    idealWidth: isSidebarCollapsed ? 72 : 220,
                    maxWidth: isSidebarCollapsed ? 82 : 280
                )

            mainEditorView()
                .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
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
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func expandedSidebarView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("JSON 页面")
                    .font(.headline)

                Spacer()

                Button {
                    toggleSidebarCollapsed()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .help("收起侧边栏")

                Button {
                    createNewPage()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建 JSON 页面")
            }

            Button("保存当前页面") {
                saveCurrentPage()
            }
            .disabled(!canSaveCurrentPage)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(pages) { page in
                        pageRow(page)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func collapsedSidebarView() -> some View {
        VStack(spacing: 10) {
            Button {
                toggleSidebarCollapsed()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help("展开侧边栏")

            Button {
                createNewPage()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新建 JSON 页面")

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

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if isEditing {
                    TextField("页面名称", text: $editingPageTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedEditingPageID, equals: page.id)
                        .onSubmit {
                            commitPageTitleEditing(page)
                        }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(page.title)
                                .font(.body.weight(isActive ? .semibold : .regular))
                                .lineLimit(1)

                            if page.isUnsaved {
                                unsavedPageBadge()
                            }

                            Spacer(minLength: 4)

                            if isActive {
                                Text("当前")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(page.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                if isEditing {
                    Button("完成") {
                        commitPageTitleEditing(page)
                    }
                    .buttonStyle(.borderless)

                    Button("取消") {
                        cancelPageTitleEditing(page)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("重命名") {
                        beginPageTitleEditing(page)
                    }
                    .buttonStyle(.borderless)

                    Button("删除") {
                        deletePage(page)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isEditing {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
            } else {
                Button {
                    selectPage(page)
                } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func collapsedPageButton(_ page: JSONWorkspacePage) -> some View {
        Button {
            selectPage(page)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(page.shortTitle)
                    .font(.caption.weight(page.id == activePageID ? .bold : .regular))
                    .foregroundStyle(page.id == activePageID ? .white : .primary)
                    .frame(width: 36, height: 32)
                    .background(page.id == activePageID ? Color.accentColor : Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if page.isUnsaved {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(page.isUnsaved ? "\(page.title)（未保存）" : page.title)
    }

    private func unsavedPageBadge() -> some View {
        Text("未保存")
            .font(.caption2)
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.12))
            .clipShape(Capsule())
    }

    private func mainEditorView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("JSON 格式化工具")
                        .font(.largeTitle.bold())

                    Text(workspaceMode.description)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 6) {
                        Text(appVersionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        if latestReleaseInfo != nil {
                            Button {
                                openLatestReleasePage()
                            } label: {
                                Text("new")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("发现新版本，点击前往 GitHub Releases 下载")
                        }
                    }
                }

                Spacer()

                Picker("工作模式", selection: $workspaceMode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Button(isDarkMode ? "日间模式" : "黑夜模式") {
                    toggleColorScheme()
                }
            }

            if let clipboardText = externalInputStore.clipboardTextToOffer {
                clipboardImportBanner(clipboardText)
            }

            actionBar()

            if workspaceMode == .format, isSearchVisible {
                outputSearchBar(matchCount: activeMatchCount)
            }

            if isTransforming {
                ProgressView("正在本地处理 JSON...")
                    .controlSize(.small)
            }

            if workspaceMode == .format, outputLineIndex.isVirtualized {
                Text("大文件模式：右侧输出按可视区域懒加载，已暂停高亮和全文搜索；复制结果仍会复制完整 JSON。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if workspaceMode == .format {
                HStack(alignment: .top, spacing: 12) {
                    editor(title: "输入", text: $inputText) {
                        queryExpressionBar()
                    }
                    outputEditor(title: "输出")
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        editor(title: "左侧 JSON", text: $inputText) { EmptyView() }
                        editor(title: "右侧 JSON", text: $diffRightText) { EmptyView() }
                    }
                    .frame(maxHeight: .infinity)

                    diffResultView()
                        .frame(minHeight: 150, idealHeight: 190, maxHeight: 230)
                }
                .frame(maxHeight: .infinity)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func actionBar() -> some View {
        HStack(spacing: 10) {
            if workspaceMode == .format {
                Button(isTransforming ? "处理中..." : "格式化") {
                    formatJSON()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isTransforming)

                Button("压缩") { compactJSON() }
                    .disabled(isTransforming)
                Button("转义") { escapeJSON() }
                    .disabled(isTransforming)
                Button("转义并复制 JSON") { escapeAndCopyJSON() }
                    .disabled(isTransforming)
                Button("复制结果") { copyOutput() }
                    .disabled(outputText.isEmpty || isTransforming)
                Button("搜索输出") { openSearch() }
                    .disabled(outputText.isEmpty || isTransforming)
            } else {
                Button(isTransforming ? "比较中..." : "比较 JSON") {
                    compareJSON()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isTransforming)
            }

            Button("清空") {
                clearAll()
            }
            .disabled(
                inputText.isEmpty && outputText.isEmpty && diffRightText.isEmpty
                    && diffResult == nil && errorMessage.isEmpty && searchQuery.isEmpty
                    && queryExpression.isEmpty && !isTransforming
            )
        }
    }

    @ViewBuilder
    private func diffResultView() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("比较结果")
                .font(.headline)

            if let diffResult {
                if diffResult.isIdentical {
                    Label("无差异：两个 JSON 的内容相同（对象键顺序已忽略）", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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
                Text("输入左右两份 JSON 后点击“比较 JSON”，对象键顺序不同不会被视为差异，数组顺序仍参与比较。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func differenceRow(_ difference: JSONDifference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(difference.kind.title)
                    .font(.caption.bold())
                    .foregroundStyle(difference.kind.color)
                Text(difference.path)
                    .font(.system(.body, design: .monospaced).bold())
                    .textSelection(.enabled)
            }
            if let oldValue = difference.oldValue {
                Text("旧值：\(oldValue)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let newValue = difference.newValue {
                Text("新值：\(newValue)")
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
        let currentTitle = "页面 \(nextPageNumber)"
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
            var page = JSONWorkspacePage(title: "页面 \(nextPageNumber)", snapshot: snapshot, updatedAt: savedAt)
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
            let replacementPage = JSONWorkspacePage(title: "页面 1")
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
            Text("检测到剪贴板文本，可作为 JSON 输入。")
                .foregroundStyle(.secondary)

            Spacer()

            Button("格式化剪贴板") {
                inputText = clipboardText
                externalInputStore.clearClipboardOffer()
                formatJSON()
            }

            Button("忽略") {
                externalInputStore.clearClipboardOffer()
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func editor<Footer: View>(title: String, text: Binding<String>, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            AutoPairingTextEditor(text: text)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            footer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func queryExpressionBar() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("JS 查询/处理表达式，例如 .hi.map(x => x) 或 .filter(x => x > 1)", text: $queryExpression)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        runQueryExpression()
                    }
                    .disabled(isTransforming)

                Button("执行") {
                    runQueryExpression()
                }
                .disabled(inputText.isEmpty || queryExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTransforming)
            }

            Text("表达式基于输入 JSON 执行：以 . 或 [ 开头会自动接在根数据后，也可用 value、input 或 $ 引用根数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func outputEditor(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)

                Spacer()

                Picker("输出视图", selection: $outputDisplayMode) {
                    ForEach(OutputDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .disabled(outputText.isEmpty || isTransforming)

                if outputDisplayMode == .tree {
                    Button("一键展开") {
                        expandEntireTree()
                    }
                    .disabled(jsonTreeRoot == nil)

                    Button("一键收起") {
                        collapseEntireTree()
                    }
                    .disabled(jsonTreeRoot == nil)
                }
            }

            Group {
                switch outputDisplayMode {
                case .text:
                    HighlightedOutputView(
                        outputText: outputText,
                        lineIndex: outputLineIndex,
                        isDarkMode: isDarkMode,
                        matchRanges: outputMatchRanges,
                        currentMatchIndex: safeCurrentMatchIndex,
                        currentMatchRange: currentMatchRange,
                        renderRevision: outputRenderRevision,
                        scrollRevision: outputScrollRevision
                    )
                case .tree:
                    JSONTreeView(
                        root: jsonTreeRoot,
                        expandedNodeIDs: $expandedTreeNodeIDs,
                        searchMatches: treeSearchMatches,
                        currentMatchIndex: safeActiveMatchIndex
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outputSearchBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            TextField("搜索输出 JSON", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit {
                    selectNextMatch(matchCount: matchCount)
                }
                .frame(width: 260)

            Text(searchStatusText(matchCount: matchCount))
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)

            Button("上一个") {
                selectPreviousMatch(matchCount: matchCount)
            }
            .disabled(matchCount == 0 || isOutputSearchSkippedForSize)

            Button("下一个") {
                selectNextMatch(matchCount: matchCount)
            }
            .disabled(matchCount == 0 || isOutputSearchSkippedForSize)

            Button("关闭") {
                closeSearch()
            }
        }
    }

    private func formatJSON() {
        transformInput(actionName: "格式化", JSONFormatterService.format)
    }

    private func compareJSON() {
        let leftInput = inputText
        let rightInput = diffRightText
        guard !leftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidateActiveTransform()
            diffResult = nil
            errorMessage = "比较失败：左侧 JSON 不能为空"
            return
        }
        guard !rightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidateActiveTransform()
            diffResult = nil
            errorMessage = "比较失败：右侧 JSON 不能为空"
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
                    errorMessage = "比较失败：\(error.localizedDescription)"
                    logger.error("JSON Diff 失败，错误 \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func runQueryExpression() {
        let expression = queryExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "JS 查询失败：请输入 JSON 后再执行表达式"
            logger.info("跳过 JS 查询，输入为空")
            return
        }
        guard !expression.isEmpty else {
            errorMessage = "JS 查询失败：JS 表达式不能为空"
            logger.info("跳过 JS 查询，表达式为空")
            return
        }

        transformInput(actionName: "JS 查询") { input in
            try JSONFormatterService.evaluateQuery(input, expression: expression)
        }
    }

    private func compactJSON() {
        transformInput(actionName: "压缩", JSONFormatterService.compact)
    }

    private func escapeJSON() {
        transformInput(actionName: "转义", JSONFormatterService.escape)
    }

    private func escapeAndCopyJSON() {
        transformInput(actionName: "转义并复制", copyAfterSuccess: true, JSONFormatterService.escape)
    }

    private func transformInput(
        actionName: String,
        copyAfterSuccess: Bool = false,
        _ transform: @escaping @Sendable (String) throws -> String
    ) {
        let input = inputText
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
                    let message = "\(actionName)失败：\(error.localizedDescription)"
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
        copyToPasteboard(outputText, actionName: "复制结果")
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
        guard !searchQuery.isEmpty else {
            return "输入关键词"
        }

        if isOutputSearchSkippedForSize {
            return "输出过大，文本搜索已暂停"
        }

        guard matchCount > 0 else {
            return "0 个匹配"
        }

        return "\(safeActiveMatchIndex + 1) / \(matchCount)"
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

    private func toggleColorScheme() {
        isDarkMode.toggle()
        logger.info("切换 JSON Formatter 主题，当前为 \(isDarkMode ? "黑夜模式" : "日间模式", privacy: .public)")
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
        textView.applyPlainJSONInputStyle()
        textView.textContainerInset = NSSize(width: 10, height: 10)
        JSONInputTextViewLayout.configure(textView)
        textView.setPlainJSONInputString(text)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AutoPairingTextView else {
            return
        }

        context.coordinator.text = $text
        textView.disableSmartJSONInputSubstitutions()
        textView.applyPlainJSONInputStyle()
        guard !context.coordinator.isUpdatingFromTextView, textView.string != text else {
            return
        }

        let selectedRanges = textView.selectedRanges
        textView.setPlainJSONInputString(text)
        textView.selectedRanges = clampedSelectionRanges(
            selectedRanges,
            preferredInsertionLocation: textView.string.utf16.count,
            textLength: (text as NSString).length
        )
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, AutoPairingTextViewDelegate {
        var text: Binding<String>
        var isUpdatingFromTextView = false

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
            textView.applyPlainJSONInputStyle()
            textStorage.replaceCharacters(in: range, with: NSAttributedString(
                string: replacement,
                attributes: textView.plainJSONInputAttributes
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle()
        return didBecomeFirstResponder
    }

    override func didChangeText() {
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle()
        super.didChangeText()
    }

    private let autoPairs: [String: String] = [
        "{": "}",
        "[": "]",
        "\"": "\""
    ]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        disableSmartJSONInputSubstitutions()
        applyPlainJSONInputStyle()
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
    var plainJSONInputAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
    }

    func applyPlainJSONInputStyle() {
        font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textColor = .labelColor
        insertionPointColor = .labelColor
        typingAttributes = plainJSONInputAttributes
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
    }

    func setPlainJSONInputString(_ string: String) {
        textStorage?.setAttributedString(NSAttributedString(
            string: string,
            attributes: plainJSONInputAttributes
        ))
        applyPlainJSONInputStyle()
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
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
            currentMatchIndex: currentMatchIndex
        )

        let usesPlainRendering = outputText.utf8.count > OutputRenderingPolicy.maxHighlightedBytes
        let usesVirtualizedRendering = lineIndex.isVirtualized
        let shouldUpdateText: Bool
        if usesVirtualizedRendering {
            shouldUpdateText = context.coordinator.lastRenderRevision != renderRevision
                || context.coordinator.lastUsesVirtualizedRendering != usesVirtualizedRendering
        } else if usesPlainRendering {
            shouldUpdateText = context.coordinator.lastRenderRevision != renderRevision
                || context.coordinator.lastUsesPlainRendering != usesPlainRendering
                || context.coordinator.lastUsesVirtualizedRendering != usesVirtualizedRendering
        } else {
            shouldUpdateText = context.coordinator.lastRenderRevision != renderRevision
                || context.coordinator.lastUsesPlainRendering != usesPlainRendering
                || context.coordinator.lastUsesVirtualizedRendering != usesVirtualizedRendering
                || context.coordinator.lastIsDarkMode != isDarkMode
                || context.coordinator.lastMatchRanges != matchRanges
                || context.coordinator.lastCurrentMatchIndex != currentMatchIndex
        }

        if shouldUpdateText {
            applyOutputText(to: textView, scrollView: scrollView, usesPlainRendering: usesPlainRendering, usesVirtualizedRendering: usesVirtualizedRendering, coordinator: context.coordinator)
            context.coordinator.lastRenderRevision = renderRevision
            context.coordinator.lastUsesPlainRendering = usesPlainRendering
            context.coordinator.lastUsesVirtualizedRendering = usesVirtualizedRendering
            context.coordinator.lastIsDarkMode = isDarkMode
            context.coordinator.lastMatchRanges = matchRanges
            context.coordinator.lastCurrentMatchIndex = currentMatchIndex
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
            textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            return
        }

        let attributedText = buildHighlightedJSONText(
            outputText,
            isDarkMode: isDarkMode,
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
        var renderedChunkIndex = 0
        var isUpdatingVirtualizedContent = false

        func configure(
            textView: NSTextView,
            scrollView: NSScrollView,
            outputText: String,
            lineIndex: OutputLineIndex,
            isDarkMode: Bool,
            matchRanges: [NSRange],
            currentMatchIndex: Int
        ) {
            self.textView = textView
            self.scrollView = scrollView
            self.outputText = outputText
            self.lineIndex = lineIndex
            self.isDarkMode = isDarkMode
            self.matchRanges = matchRanges
            self.currentMatchIndex = currentMatchIndex
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
                ? "大文件模式：已加载前 \(loadedLineCount) 行 / 共 \(lineIndex.lineCount) 行，继续向下滚动会加载后续内容。\n\n"
                : ""

            isUpdatingVirtualizedContent = true
            if chunkStartIndex == 0 {
                textView.string = prefix + chunk
                textView.textColor = .labelColor
                textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                textView.textStorage?.append(NSAttributedString(
                    string: prefix + chunk,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
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

    var title: String {
        switch self {
        case .text:
            return "文本"
        case .tree:
            return "树状"
        }
    }
}

private enum WorkspaceMode: String, CaseIterable, Identifiable {
    case format
    case diff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .format:
            return "格式化"
        case .diff:
            return "JSON Diff"
        }
    }

    var description: String {
        switch self {
        case .format:
            return "粘贴 JSON 后按 Cmd+Enter 格式化；Cmd+T 新建页面；Cmd+S 保存到侧边栏；Cmd+F 或 Ctrl+F 搜索输出。"
        case .diff:
            return "左右输入两份 JSON 后按 Cmd+Enter 比较；对象键顺序会忽略，数组顺序仍参与比较，所有数据仅在本地处理。"
        }
    }
}

private extension JSONDifferenceKind {
    var title: String {
        switch self {
        case .added:
            return "新增"
        case .removed:
            return "删除"
        case .changed:
            return "变更"
        }
    }

    var color: Color {
        switch self {
        case .added:
            return .green
        case .removed:
            return .red
        case .changed:
            return .orange
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
    matchRanges: [NSRange],
    currentMatchIndex: Int
) -> NSAttributedString {
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
