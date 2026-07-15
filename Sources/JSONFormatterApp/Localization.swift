import Foundation

/// 界面语言。rawValue 用于 `@AppStorage` 持久化，与业务/持久化数据解耦。
enum AppLanguage: String, CaseIterable, Identifiable {
    case en
    case cn

    var id: String { rawValue }

    /// 分段控件展示用短标签。
    var shortLabel: String {
        switch self {
        case .en:
            return "EN"
        case .cn:
            return "CN"
        }
    }
}

/// 所有可见文案的 key，穷举界面中出现的中/英文字符串。
enum LocKey {
    // 菜单
    case menuFormat
    case menuSavePage
    case menuNewPage
    case menuFindOutput

    // 侧边栏
    case appTitle
    case newDocument
    case collapseSidebar
    case expandSidebar
    case settings
    case toggleDarkMode
    case toggleLightMode
    case clearHistory
    case clearHistoryConfirmTitle
    case clearHistoryConfirmMessage
    case clearHistoryConfirm
    case statusUnsaved
    case statusBlankPage
    case timeJustNow

    // 页面行操作
    case rename
    case delete
    case done
    case cancel
    case current
    case pageNamePlaceholder

    // 顶栏 / 操作
    case format
    case formatting
    case compress
    case jsonDiff
    case escape
    case escapeAndCopy
    case copyOutput
    case clear
    case compare
    case comparing
    case saveOutput
    case searchPlaceholder

    // 面板
    case inputTitle
    case outputTitle
    case paste
    case run
    case queryPlaceholder
    case queryHint
    case outputModeText
    case outputModeTree
    case expandAll
    case collapseAll
    case processing

    // 搜索
    case searchPrevious
    case searchNext
    case searchEnterKeyword
    case searchPaused
    case searchNoMatch

    // 大文件提示
    case largeFileBanner

    // 版本 / 新版本
    case devVersion
    case newBadge
    case newBadgeHelp

    // 剪贴板导入
    case clipboardBanner
    case formatClipboard
    case ignore

    // Diff 结果
    case diffResultTitle
    case diffIdentical
    case diffEmptyHint
    case diffKindAdded
    case diffKindRemoved
    case diffKindChanged

    // 树视图空态
    case treeEmptyTitle
    case treeEmptyDescription

    // 错误
    case diffLeftEmpty
    case diffRightEmpty
    case queryNeedInput
    case queryNeedExpression

    // 动作名（用于失败信息 / 复制反馈）
    case actionFormat
    case actionCompress
    case actionEscape
    case actionEscapeAndCopy
    case actionQuery
    case actionCopyOutput
    case actionCompare
}

/// 轻量本地化查表。按语言返回中/英文案，不引入第三方依赖。
struct L10n {
    let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    func t(_ key: LocKey) -> String {
        let pair = L10n.table[key] ?? ("", "")
        return language == .cn ? pair.cn : pair.en
    }

    /// 版本号文案，例如「版本 1.2.0」/「Version 1.2.0」。
    func versionText(_ version: String) -> String {
        language == .cn ? "版本 \(version)" : "Version \(version)"
    }

    /// 新建页面默认标题，例如「页面 2」/「Page 2」。
    func newPageTitle(_ number: Int) -> String {
        language == .cn ? "页面 \(number)" : "Page \(number)"
    }

    /// 失败信息，例如「格式化失败：xxx」/「Format failed: xxx」。
    func failure(_ actionKey: LocKey, detail: String) -> String {
        let action = t(actionKey)
        return language == .cn ? "\(action)失败：\(detail)" : "\(action) failed: \(detail)"
    }

    /// 搜索匹配计数，例如「2 / 10」。
    func searchStatus(currentIndex: Int, matchCount: Int, hasQuery: Bool, isPaused: Bool) -> String {
        guard hasQuery else {
            return t(.searchEnterKeyword)
        }
        if isPaused {
            return t(.searchPaused)
        }
        guard matchCount > 0 else {
            return t(.searchNoMatch)
        }
        return "\(currentIndex + 1) / \(matchCount)"
    }

    /// 相对时间副标题，例如「3 天前」/「3d ago」。
    func relativeTime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        let minute = 60.0
        let hour = 3_600.0
        let day = 86_400.0

        if seconds < minute {
            return t(.timeJustNow)
        }
        if seconds < hour {
            let value = Int(seconds / minute)
            return language == .cn ? "\(value) 分钟前" : "\(value)m ago"
        }
        if seconds < day {
            let value = Int(seconds / hour)
            return language == .cn ? "\(value) 小时前" : "\(value)h ago"
        }
        let value = Int(seconds / day)
        return language == .cn ? "\(value) 天前" : "\(value)d ago"
    }

    /// 大文件模式已加载提示。
    func largeFileLoadedNotice(loadedLines: Int, totalLines: Int) -> String {
        if language == .cn {
            return "大文件模式：已加载前 \(loadedLines) 行 / 共 \(totalLines) 行，继续向下滚动会加载后续内容。\n\n"
        }
        return "Large file mode: loaded \(loadedLines) of \(totalLines) lines. Scroll down to load more.\n\n"
    }

    private static let table: [LocKey: (cn: String, en: String)] = [
        .menuFormat: ("格式化 JSON", "Format JSON"),
        .menuSavePage: ("保存当前 JSON 页面", "Save Current Page"),
        .menuNewPage: ("新建 JSON 页面", "New Document"),
        .menuFindOutput: ("搜索输出 JSON", "Find in Output"),

        .appTitle: ("JSON Formatter", "JSON Formatter"),
        .newDocument: ("新建文档", "New Document"),
        .collapseSidebar: ("收起侧边栏", "Collapse Sidebar"),
        .expandSidebar: ("展开侧边栏", "Expand Sidebar"),
        .settings: ("设置", "Settings"),
        .toggleDarkMode: ("切换到黑夜模式", "Switch to Dark Mode"),
        .toggleLightMode: ("切换到日间模式", "Switch to Light Mode"),
        .clearHistory: ("清空历史", "Clear History"),
        .clearHistoryConfirmTitle: ("清空全部文档历史？", "Clear all document history?"),
        .clearHistoryConfirmMessage: (
            "将删除侧边栏中所有页面并重置为一个空白页面，此操作无法撤销。",
            "All pages in the sidebar will be removed and reset to a single blank page. This cannot be undone."
        ),
        .clearHistoryConfirm: ("清空", "Clear"),
        .statusUnsaved: ("未保存", "Unsaved"),
        .statusBlankPage: ("空白页面", "Blank page"),
        .timeJustNow: ("刚刚", "just now"),

        .rename: ("重命名", "Rename"),
        .delete: ("删除", "Delete"),
        .done: ("完成", "Done"),
        .cancel: ("取消", "Cancel"),
        .current: ("当前", "Current"),
        .pageNamePlaceholder: ("页面名称", "Page name"),

        .format: ("格式化", "Format"),
        .formatting: ("处理中...", "Formatting..."),
        .compress: ("压缩", "Compress"),
        .jsonDiff: ("JSON Diff", "JSON Diff"),
        .escape: ("转义", "Escape"),
        .escapeAndCopy: ("转义并复制", "Escape & Copy"),
        .copyOutput: ("复制结果", "Copy"),
        .clear: ("清空", "Clear"),
        .compare: ("比较 JSON", "Compare"),
        .comparing: ("比较中...", "Comparing..."),
        .saveOutput: ("保存", "Save Output"),
        .searchPlaceholder: ("搜索输出...", "Search in output..."),

        .inputTitle: ("输入", "INPUT"),
        .outputTitle: ("输出", "OUTPUT"),
        .paste: ("粘贴", "Paste"),
        .run: ("执行", "Run"),
        .queryPlaceholder: (
            "JS 查询/处理表达式，例如 .hi.map(x => x) 或 .filter(x => x > 1)",
            "JS query / filter expression, e.g. .hi.map(x => x) or .filter(x => x > 1)"
        ),
        .queryHint: (
            "表达式基于输入 JSON 执行：以 . 或 [ 开头会自动接在根数据后，也可用 value、input 或 $ 引用根数据。",
            "Expression runs against the input JSON: a leading . or [ chains onto the root; you can also reference the root via value, input or $."
        ),
        .outputModeText: ("文本", "Text"),
        .outputModeTree: ("树状", "Tree"),
        .expandAll: ("一键展开", "Expand All"),
        .collapseAll: ("一键收起", "Collapse All"),
        .processing: ("正在本地处理 JSON...", "Processing JSON locally..."),

        .searchPrevious: ("上一个", "Previous"),
        .searchNext: ("下一个", "Next"),
        .searchEnterKeyword: ("输入关键词", "Type to search"),
        .searchPaused: ("输出过大，文本搜索已暂停", "Output too large; text search paused"),
        .searchNoMatch: ("0 个匹配", "No matches"),

        .largeFileBanner: (
            "大文件模式：右侧输出按可视区域懒加载，已暂停高亮和全文搜索；复制结果仍会复制完整 JSON。",
            "Large file mode: output is lazily rendered by viewport; highlighting and full-text search are paused. Copy still copies the full JSON."
        ),

        .devVersion: ("开发版", "Dev"),
        .newBadge: ("new", "new"),
        .newBadgeHelp: (
            "发现新版本，点击前往 GitHub Releases 下载",
            "A new version is available. Click to open GitHub Releases."
        ),

        .clipboardBanner: ("检测到剪贴板文本，可作为 JSON 输入。", "Clipboard text detected; you can use it as JSON input."),
        .formatClipboard: ("格式化剪贴板", "Format Clipboard"),
        .ignore: ("忽略", "Ignore"),

        .diffResultTitle: ("比较结果", "Diff Result"),
        .diffIdentical: (
            "无差异：两个 JSON 的内容相同（对象键顺序已忽略）",
            "No differences: both JSON values are identical (object key order ignored)."
        ),
        .diffEmptyHint: (
            "输入左右两份 JSON 后点击“比较 JSON”，对象键顺序不同不会被视为差异，数组顺序仍参与比较。",
            "Enter JSON on both sides and click Compare. Object key order is ignored; array order still counts."
        ),
        .diffKindAdded: ("新增", "Added"),
        .diffKindRemoved: ("删除", "Removed"),
        .diffKindChanged: ("变更", "Changed"),

        .treeEmptyTitle: ("暂无可展示的 JSON 树", "No JSON tree to show"),
        .treeEmptyDescription: ("请先格式化或查询 JSON 输出。", "Format or query JSON output first."),

        .diffLeftEmpty: ("比较失败：左侧 JSON 不能为空", "Compare failed: left JSON cannot be empty"),
        .diffRightEmpty: ("比较失败：右侧 JSON 不能为空", "Compare failed: right JSON cannot be empty"),
        .queryNeedInput: ("JS 查询失败：请输入 JSON 后再执行表达式", "JS query failed: enter JSON before running an expression"),
        .queryNeedExpression: ("JS 查询失败：JS 表达式不能为空", "JS query failed: expression cannot be empty"),

        .actionFormat: ("格式化", "Format"),
        .actionCompress: ("压缩", "Compress"),
        .actionEscape: ("转义", "Escape"),
        .actionEscapeAndCopy: ("转义并复制", "Escape & copy"),
        .actionQuery: ("JS 查询", "JS query"),
        .actionCopyOutput: ("复制结果", "Copy"),
        .actionCompare: ("比较", "Compare"),
    ]
}

/// Diff 差异类型的本地化标题。
extension L10n {
    func diffKindTitle(_ kind: JSONDifferenceKind) -> String {
        switch kind {
        case .added:
            return t(.diffKindAdded)
        case .removed:
            return t(.diffKindRemoved)
        case .changed:
            return t(.diffKindChanged)
        }
    }
}
