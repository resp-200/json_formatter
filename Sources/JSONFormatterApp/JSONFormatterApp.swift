import SwiftUI

@main
struct JSONFormatterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 640)
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

extension Notification.Name {
    static let formatJSONRequested = Notification.Name("formatJSONRequested")
}
