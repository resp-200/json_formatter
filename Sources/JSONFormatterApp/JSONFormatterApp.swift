import AppKit
import SwiftUI

@main
struct JSONFormatterApp: App {
    init() {
        if let launchText = JSONInputRouter.textFromLaunchArguments() {
            DispatchQueue.main.async {
                postExternalJSON(launchText)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 640)
                .onOpenURL { url in
                    guard let text = JSONInputRouter.text(from: url) else {
                        return
                    }
                    postExternalJSON(text)
                }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("格式化 JSON") {
                    NotificationCenter.default.post(name: .formatJSONRequested, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}

@MainActor
private func postExternalJSON(_ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .formatExternalJSONRequested, object: text)
}

extension Notification.Name {
    static let formatJSONRequested = Notification.Name("formatJSONRequested")
}
