import AppKit
import OSLog
import SwiftUI

struct ContentView: View {
    @ObservedObject var externalInputStore: ExternalJSONInputStore
    @AppStorage("jsonFormatterIsDarkMode") private var isDarkMode = false

    @State private var inputText = ""
    @State private var outputText = ""
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

    @FocusState private var isSearchFocused: Bool

    private let logger = Logger(subsystem: "local.json-formatter.app", category: "ContentView")

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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("JSON 格式化工具")
                        .font(.largeTitle.bold())

                    Text("粘贴 JSON 后按 Cmd+Enter 格式化；Cmd+F 或 Ctrl+F 搜索输出；系统入口支持 URL Scheme、JSON 文件打开和剪贴板自动格式化。")
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

                Button(isDarkMode ? "日间模式" : "黑夜模式") {
                    toggleColorScheme()
                }
            }

            if let clipboardText = externalInputStore.clipboardTextToOffer {
                clipboardImportBanner(clipboardText)
            }

            HStack(spacing: 10) {
                Button(isTransforming ? "处理中..." : "格式化") {
                    formatJSON()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isTransforming)

                Button("压缩") {
                    compactJSON()
                }
                .disabled(isTransforming)

                Button("转义") {
                    escapeJSON()
                }
                .disabled(isTransforming)

                Button("转义并复制 JSON") {
                    escapeAndCopyJSON()
                }
                .disabled(isTransforming)

                Button("复制结果") {
                    copyOutput()
                }
                .disabled(outputText.isEmpty || isTransforming)

                Button("搜索输出") {
                    openSearch()
                }
                .disabled(outputText.isEmpty || isTransforming)

                Button("清空") {
                    clearAll()
                }
                .disabled(inputText.isEmpty && outputText.isEmpty && errorMessage.isEmpty && searchQuery.isEmpty && queryExpression.isEmpty && !isTransforming)
            }

            if isSearchVisible {
                outputSearchBar(matchCount: activeMatchCount)
            }

            if isTransforming {
                ProgressView("正在本地处理 JSON...")
                    .controlSize(.small)
            }

            if outputLineIndex.isVirtualized {
                Text("大文件模式：右侧输出按可视区域懒加载，已暂停高亮和全文搜索；复制结果仍会复制完整 JSON。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 12) {
                editor(title: "输入", text: $inputText) {
                    queryExpressionBar()
                }
                outputEditor(title: "输出")
            }
            .frame(maxHeight: .infinity)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            installFindShortcutMonitor()
            checkLatestRelease()
        }
        .onDisappear(perform: removeFindShortcutMonitor)
        .onChange(of: searchQuery) { _, _ in
            refreshSearchMatches()
        }
        .onChange(of: outputText) { _, _ in
            refreshSearchMatches()
        }
        .onChange(of: outputDisplayMode) { _, _ in
            refreshSearchMatches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .formatJSONRequested)) { _ in
            formatJSON()
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
                    outputRenderRevision += 1
                    if copyAfterSuccess {
                        copyToPasteboard(output.text, actionName: actionName)
                    }
                    logger.info("JSON \(actionName, privacy: .public) 成功，输出长度 \(output.text.count, privacy: .public)，大文件虚拟化 \(output.lineIndex.isVirtualized, privacy: .public)")
                case .failure(let error):
                    errorMessage = "\(actionName)失败：\(error.localizedDescription)"
                    logger.error("JSON \(actionName, privacy: .public) 失败，输入长度 \(input.count, privacy: .public)，错误 \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func acceptExternalJSON(_ request: ExternalJSONInputRequest) {
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
        activeTransformID = nil
        isTransforming = false
        outputRenderRevision += 1
        outputScrollRevision += 1
        logger.info("清空 JSON 输入输出内容成功")
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
        logger.info("打开 GitHub Releases 页面，url=\(url.absoluteString, privacy: .public)")
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

        let textView = AutoPairingTextView()
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
