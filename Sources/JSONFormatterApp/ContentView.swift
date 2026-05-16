import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var externalInputStore: ExternalJSONInputStore
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("JSON 格式化工具")
                .font(.largeTitle.bold())

            Text("粘贴 JSON 后按 Cmd+Enter 格式化；系统入口可使用 URL Scheme、JSON 文件打开，或复制 JSON 后启动/重新打开 App 自动格式化。")
                .foregroundStyle(.secondary)

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

                Button("清空") {
                    clearAll()
                }
                .disabled(inputText.isEmpty && outputText.isEmpty && errorMessage.isEmpty)
            }

            HStack(alignment: .top, spacing: 12) {
                editor(title: "输入", text: $inputText)
                editor(title: "输出", text: $outputText)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .onReceive(NotificationCenter.default.publisher(for: .formatJSONRequested)) { _ in
            formatJSON()
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

    private func formatJSON() {
        transformInput(JSONFormatterService.format)
    }

    private func compactJSON() {
        transformInput(JSONFormatterService.compact)
    }

    private func transformInput(_ transform: (String) throws -> String) {
        do {
            outputText = try transform(inputText)
            errorMessage = ""
        } catch {
            errorMessage = "JSON 解析失败：\(error.localizedDescription)"
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
    }

    private func clearAll() {
        inputText = ""
        outputText = ""
        errorMessage = ""
    }
}
