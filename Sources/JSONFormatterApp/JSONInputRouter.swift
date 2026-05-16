import AppKit
import Foundation

public enum JSONInputRouter {
    private static let supportedURLSchemes = Set(["jsonformatter", "json-formatter"])
    private static let jsonFileExtensions = Set(["json", "jsonc", "geojson"])
    private static let candidateQueryItemNames = ["text", "json", "input", "q"]

    public static func text(from url: URL) -> String? {
        if let scheme = url.scheme?.lowercased(), supportedURLSchemes.contains(scheme) {
            return textFromAppURL(url)
        }

        return textFromFileURL(url)
    }

    public static func textFromLaunchArguments(_ arguments: [String] = CommandLine.arguments) -> String? {
        let arguments = arguments.dropFirst()
        guard !arguments.isEmpty else {
            return nil
        }

        let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @MainActor
    static func textFromGeneralPasteboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return nil
        }

        return normalizedNonEmptyText(text)
    }

    private static func textFromAppURL(_ url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for name in candidateQueryItemNames {
                if let text = components.queryItems?.first(where: { $0.name == name })?.value,
                   let normalizedText = normalizedNonEmptyText(text) {
                    return normalizedText
                }
            }
        }

        let pathCandidates = [
            url.host(percentEncoded: false),
            url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ]

        for candidate in pathCandidates {
            if let normalizedText = normalizedNonEmptyText(candidate) {
                return normalizedText
            }
        }

        return nil
    }

    private static func textFromFileURL(_ url: URL) -> String? {
        guard url.isFileURL else {
            return nil
        }

        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension.isEmpty || jsonFileExtensions.contains(fileExtension) else {
            return nil
        }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return normalizedNonEmptyText(text)
    }

    private static func normalizedNonEmptyText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedText.isEmpty ? nil : normalizedText
    }
}

enum ClipboardJSONAutoFormatDecision: Equatable {
    case shouldFormat(String)
    case duplicateChangeCount
    case noText
    case invalidJSON
}

struct ClipboardJSONAutoFormatter {
    private var lastProcessedChangeCount: Int?

    mutating func decision(changeCount: Int, text: String?) -> ClipboardJSONAutoFormatDecision {
        guard lastProcessedChangeCount != changeCount else {
            return .duplicateChangeCount
        }

        lastProcessedChangeCount = changeCount

        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noText
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            _ = try JSONFormatterService.format(normalizedText)
            return .shouldFormat(normalizedText)
        } catch {
            return .invalidJSON
        }
    }
}
