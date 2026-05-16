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
    @State private var currentMatchIndex = 0
    @State private var keyDownMonitor: Any?

    @FocusState private var isSearchFocused: Bool

    private let logger = Logger(subsystem: "local.json-formatter.app", category: "ContentView")

    private var outputMatchRanges: [NSRange] {
        searchRanges(in: outputText, query: searchQuery)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("JSON 格式化工具")
                        .font(.largeTitle.bold())

                    Text("粘贴 JSON 后按 Cmd+Enter 格式化；Cmd+F 或 Ctrl+F 搜索输出；系统入口支持 URL Scheme、JSON 文件打开和剪贴板自动格式化。")
                        .foregroundStyle(.secondary)
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
                Button("格式化") {
                    formatJSON()
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("压缩") {
                    compactJSON()
                }

                Button("复制结果") {
                    copyOutput()
                }
                .disabled(outputText.isEmpty)

                Button("搜索输出") {
                    openSearch()
                }

                Button("清空") {
                    clearAll()
                }
                .disabled(inputText.isEmpty && outputText.isEmpty && errorMessage.isEmpty && searchQuery.isEmpty)
            }

            if isSearchVisible {
                outputSearchBar(matchCount: outputMatchRanges.count)
            }

            HStack(alignment: .top, spacing: 12) {
                editor(title: "输入", text: $inputText)
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
        .onAppear(perform: installFindShortcutMonitor)
        .onDisappear(perform: removeFindShortcutMonitor)
        .onChange(of: searchQuery) { _, _ in
            currentMatchIndex = 0
        }
        .onChange(of: outputText) { _, _ in
            currentMatchIndex = 0
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

    private func editor(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    private func outputEditor(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            HighlightedOutputView(
                attributedText: attributedOutputText(),
                currentMatchRange: currentMatchRange
            )
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
            .disabled(matchCount == 0)

            Button("下一个") {
                selectNextMatch(matchCount: matchCount)
            }
            .disabled(matchCount == 0)

            Button("关闭") {
                closeSearch()
            }
        }
    }

    private func formatJSON() {
        transformInput(actionName: "格式化", JSONFormatterService.format)
    }

    private func compactJSON() {
        transformInput(actionName: "压缩", JSONFormatterService.compact)
    }

    private func transformInput(actionName: String, _ transform: (String) throws -> String) {
        logger.info("开始执行 JSON \(actionName, privacy: .public)，输入长度 \(inputText.count, privacy: .public)")
        do {
            outputText = try transform(inputText)
            errorMessage = ""
            logger.info("JSON \(actionName, privacy: .public) 成功，输出长度 \(outputText.count, privacy: .public)")
        } catch {
            errorMessage = "JSON 解析失败：\(error.localizedDescription)"
            logger.error("JSON \(actionName, privacy: .public) 失败，输入长度 \(inputText.count, privacy: .public)，错误 \(error.localizedDescription, privacy: .public)")
        }
    }

    private func acceptExternalJSON(_ request: ExternalJSONInputRequest) {
        inputText = request.text
        externalInputStore.clearClipboardOffer()
        formatJSON()
        externalInputStore.markFormatRequestHandled(request)
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
        logger.info("复制 JSON 输出成功，输出长度 \(outputText.count, privacy: .public)")
    }

    private func clearAll() {
        inputText = ""
        outputText = ""
        errorMessage = ""
        searchQuery = ""
        currentMatchIndex = 0
        logger.info("清空 JSON 输入输出内容成功")
    }

    private func openSearch() {
        isSearchVisible = true
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func closeSearch() {
        isSearchVisible = false
        searchQuery = ""
        currentMatchIndex = 0
    }

    private func selectPreviousMatch(matchCount: Int) {
        guard matchCount > 0 else {
            return
        }

        currentMatchIndex = (safeCurrentMatchIndex + matchCount - 1) % matchCount
    }

    private func selectNextMatch(matchCount: Int) {
        guard matchCount > 0 else {
            return
        }

        currentMatchIndex = (safeCurrentMatchIndex + 1) % matchCount
    }

    private func searchStatusText(matchCount: Int) -> String {
        guard !searchQuery.isEmpty else {
            return "输入关键词"
        }

        guard matchCount > 0 else {
            return "0 个匹配"
        }

        return "\(safeCurrentMatchIndex + 1) / \(matchCount)"
    }

    private func toggleColorScheme() {
        isDarkMode.toggle()
        logger.info("切换 JSON Formatter 主题，当前为 \(isDarkMode ? "黑夜模式" : "日间模式", privacy: .public)")
    }

    private func attributedOutputText() -> NSAttributedString {
        buildHighlightedJSONText(
            outputText,
            isDarkMode: isDarkMode,
            matchRanges: outputMatchRanges,
            currentMatchIndex: safeCurrentMatchIndex
        )
    }

    private func installFindShortcutMonitor() {
        guard keyDownMonitor == nil else {
            return
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = event.charactersIgnoringModifiers?.lowercased()
            let modifierFlags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let isFindShortcut = key == "f" && (modifierFlags == .command || modifierFlags == .control)

            if isFindShortcut {
                openSearch()
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

private struct HighlightedOutputView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let currentMatchRange: NSRange?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

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

        if !textView.attributedString().isEqual(to: attributedText) {
            textView.textStorage?.setAttributedString(attributedText)
        }

        if let currentMatchRange {
            textView.scrollRangeToVisible(currentMatchRange)
        }
    }
}

private func searchRanges(in text: String, query: String) -> [NSRange] {
    guard !text.isEmpty, !query.isEmpty else {
        return []
    }

    let nsText = text as NSString
    var ranges: [NSRange] = []
    var searchRange = NSRange(location: 0, length: nsText.length)

    while searchRange.location < nsText.length {
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
