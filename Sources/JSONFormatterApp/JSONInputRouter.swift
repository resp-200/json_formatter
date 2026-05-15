import Foundation

enum JSONInputRouter {
    static func text(from url: URL) -> String? {
        guard url.scheme == "jsonformatter" else {
            return nil
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
           !text.isEmpty {
            return text
        }

        let pathText = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return pathText.isEmpty ? nil : pathText.removingPercentEncoding ?? pathText
    }

    static func textFromLaunchArguments() -> String? {
        let arguments = CommandLine.arguments.dropFirst()
        let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension Notification.Name {
    static let formatExternalJSONRequested = Notification.Name("formatExternalJSONRequested")
}
