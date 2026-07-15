import AppKit
import OSLog
import SwiftUI

@main
struct JSONFormatterApp: App {
    @NSApplicationDelegateAdaptor(JSONFormatterAppDelegate.self) private var appDelegate
    @StateObject private var externalInputStore = ExternalJSONInputStore.shared
    @AppStorage("jsonFormatterLanguage") private var languageRaw = AppLanguage.cn.rawValue

    private var l10n: L10n {
        L10n(language: AppLanguage(rawValue: languageRaw) ?? .cn)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(externalInputStore: externalInputStore)
                .frame(minWidth: 900, minHeight: 640)
                .onOpenURL { url in
                    guard let text = JSONInputRouter.text(from: url) else {
                        return
                    }
                    externalInputStore.requestFormat(text, source: "swiftui-url")
                }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button(l10n.t(.menuFormat)) {
                    NotificationCenter.default.post(name: .formatJSONRequested, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button(l10n.t(.menuSavePage)) {
                    NotificationCenter.default.post(name: .saveJSONPageRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button(l10n.t(.menuNewPage)) {
                    NotificationCenter.default.post(name: .newJSONPageRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button(l10n.t(.menuFindOutput)) {
                    NotificationCenter.default.post(name: .findOutputRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class JSONFormatterAppDelegate: NSObject, NSApplicationDelegate {
    private let externalInputStore = ExternalJSONInputStore.shared
    private let logger = Logger(subsystem: "local.json-formatter.app", category: "ClipboardAutoFormat")
    private var clipboardAutoFormatter = ClipboardJSONAutoFormatter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        if let launchText = JSONInputRouter.textFromLaunchArguments() {
            externalInputStore.requestFormat(launchText, source: "launch-arguments")
            return
        }

        stageClipboardTextIfAvailable(source: "launch-clipboard")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let text = JSONInputRouter.text(from: url) else {
                continue
            }

            externalInputStore.requestFormat(text, source: "application-open-url")
            return
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.activate(ignoringOtherApps: true)
        }

        stageClipboardTextIfAvailable(source: "reopen-clipboard")

        return true
    }

    @objc func openSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "JSON Formatter 未收到可格式化的文本"
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "JSON Formatter 收到的文本为空"
            return
        }

        externalInputStore.requestFormat(text, source: "service-selection")
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlText = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlText),
              let text = JSONInputRouter.text(from: url) else {
            return
        }

        externalInputStore.requestFormat(text, source: "apple-event-url")
    }

    private func stageClipboardTextIfAvailable(source: String) {
        guard externalInputStore.pendingFormatRequest == nil else {
            logger.info("跳过剪贴板自动格式化，已有外部 JSON 输入待处理，来源 \(source, privacy: .public)")
            return
        }

        let changeCount = NSPasteboard.general.changeCount
        let text = JSONInputRouter.textFromGeneralPasteboard()

        switch clipboardAutoFormatter.decision(changeCount: changeCount, text: text) {
        case .shouldFormat(let text):
            logger.info("自动格式化剪贴板 JSON，来源 \(source, privacy: .public)，剪贴板变更次数 \(changeCount, privacy: .public)，文本长度 \(text.count, privacy: .public)")
            externalInputStore.requestFormat(text, source: source, opensInNewPage: true)
        case .duplicateChangeCount:
            logger.info("跳过重复剪贴板内容，来源 \(source, privacy: .public)，剪贴板变更次数 \(changeCount, privacy: .public)")
        case .noText:
            logger.info("跳过空剪贴板文本，来源 \(source, privacy: .public)，剪贴板变更次数 \(changeCount, privacy: .public)")
            externalInputStore.clearClipboardOffer()
        case .invalidJSON:
            logger.info("跳过非法剪贴板 JSON，来源 \(source, privacy: .public)，剪贴板变更次数 \(changeCount, privacy: .public)")
            externalInputStore.clearClipboardOffer()
        }
    }
}

struct ExternalJSONInputRequest: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let source: String
    let opensInNewPage: Bool

    init(text: String, source: String, opensInNewPage: Bool = false) {
        self.text = text
        self.source = source
        self.opensInNewPage = opensInNewPage
    }
}

@MainActor
final class ExternalJSONInputStore: ObservableObject {
    static let shared = ExternalJSONInputStore()

    @Published private(set) var pendingFormatRequest: ExternalJSONInputRequest?
    @Published private(set) var clipboardTextToOffer: String?

    private let logger = Logger(subsystem: "local.json-formatter.app", category: "ExternalInput")
    private var queuedFormatRequests: [ExternalJSONInputRequest] = []

    private init() {}

    func requestFormat(_ text: String, source: String, opensInNewPage: Bool = false) {
        logger.info("收到外部 JSON 输入，来源 \(source, privacy: .public)，文本长度 \(text.count, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)

        let request = ExternalJSONInputRequest(text: text, source: source, opensInNewPage: opensInNewPage)
        if pendingFormatRequest == nil {
            pendingFormatRequest = request
        } else {
            queuedFormatRequests.append(request)
        }
    }

    func markFormatRequestHandled(_ request: ExternalJSONInputRequest) {
        guard pendingFormatRequest?.id == request.id else {
            logger.info("跳过已过期的外部 JSON 输入请求，请求标识 \(request.id.uuidString, privacy: .public)")
            return
        }

        pendingFormatRequest = queuedFormatRequests.isEmpty ? nil : queuedFormatRequests.removeFirst()
    }

    func stageClipboardJSON(_ text: String, source: String) {
        logger.info("暂存剪贴板 JSON 输入提示，来源 \(source, privacy: .public)，文本长度 \(text.count, privacy: .public)")
        clipboardTextToOffer = text
    }

    func clearClipboardOffer() {
        clipboardTextToOffer = nil
    }
}

extension Notification.Name {
    static let formatJSONRequested = Notification.Name("formatJSONRequested")
    static let saveJSONPageRequested = Notification.Name("saveJSONPageRequested")
    static let newJSONPageRequested = Notification.Name("newJSONPageRequested")
    static let findOutputRequested = Notification.Name("findOutputRequested")
}
