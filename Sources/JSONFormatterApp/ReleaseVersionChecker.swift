import Foundation
import OSLog

struct LatestReleaseInfo: Equatable, Sendable {
    let tagName: String
    let htmlURL: URL
}

enum ReleaseVersionChecker {
    static let releasesPageURL = URL(string: "https://github.com/resp-200/json_formatter/releases")!
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/resp-200/json_formatter/releases/latest")!
    private static let logger = Logger(subsystem: "local.json-formatter.app", category: "ReleaseVersion")

    static func fetchLatestRelease() async throws -> LatestReleaseInfo {
        logger.info("开始检测 GitHub Releases 最新版本，url=\(latestReleaseAPIURL.absoluteString, privacy: .public)")
        let (data, response) = try await URLSession.shared.data(from: latestReleaseAPIURL)

        if let httpResponse = response as? HTTPURLResponse {
            logger.info("GitHub Releases 最新版本接口返回，statusCode=\(httpResponse.statusCode, privacy: .public)，bytes=\(data.count, privacy: .public)")
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ReleaseVersionError.badStatusCode(httpResponse.statusCode)
            }
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = jsonObject as? [String: Any],
              let tagName = dictionary["tag_name"] as? String,
              !tagName.isEmpty else {
            throw ReleaseVersionError.missingTagName
        }

        let htmlURL: URL
        if let htmlURLString = dictionary["html_url"] as? String,
           let parsedHTMLURL = URL(string: htmlURLString) {
            htmlURL = parsedHTMLURL
        } else {
            htmlURL = releasesPageURL
        }

        return LatestReleaseInfo(tagName: tagName, htmlURL: htmlURL)
    }

    static func isNewerRelease(currentVersion: String, latestTagName: String) -> Bool {
        guard let currentParts = numericVersionParts(currentVersion),
              let latestParts = numericVersionParts(latestTagName) else {
            return false
        }

        let maxCount = max(currentParts.count, latestParts.count)

        for index in 0..<maxCount {
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            let latestPart = index < latestParts.count ? latestParts[index] : 0
            if latestPart != currentPart {
                return latestPart > currentPart
            }
        }

        return false
    }

    private static func numericVersionParts(_ version: String) -> [Int]? {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionWithoutPrefix = trimmedVersion.hasPrefix("v") || trimmedVersion.hasPrefix("V")
            ? String(trimmedVersion.dropFirst())
            : trimmedVersion
        let coreVersion = versionWithoutPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = coreVersion.split(separator: ".", omittingEmptySubsequences: false)

        guard !parts.isEmpty else {
            return nil
        }

        var numericParts: [Int] = []
        numericParts.reserveCapacity(parts.count)

        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let numericPart = Int(digits) else {
                return nil
            }
            numericParts.append(numericPart)
        }

        return numericParts
    }
}

enum ReleaseVersionError: LocalizedError {
    case badStatusCode(Int)
    case missingTagName

    var errorDescription: String? {
        switch self {
        case .badStatusCode(let statusCode):
            return "GitHub Releases 接口返回异常状态码：\(statusCode)"
        case .missingTagName:
            return "GitHub Releases 响应缺少版本标签"
        }
    }
}
