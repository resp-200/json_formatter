import Foundation
import OSLog

struct LatestReleaseInfo: Equatable, Sendable {
    let tagName: String
    let htmlURL: URL
}

enum ReleaseVersionChecker {
    static let releasesPageURL = URL(string: "https://github.com/resp-200/json_formatter/releases")!
    private static let releasesAPIURL = URL(string: "https://api.github.com/repos/resp-200/json_formatter/releases?per_page=30")!
    private static let logger = Logger(subsystem: "local.json-formatter.app", category: "ReleaseVersion")

    static func fetchLatestRelease() async throws -> LatestReleaseInfo {
        logger.info("开始检测 GitHub Releases 版本列表，url=\(releasesAPIURL.absoluteString, privacy: .public)")
        var request = URLRequest(url: releasesAPIURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("JSONFormatterApp", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            logger.info("GitHub Releases 版本列表接口返回，statusCode=\(httpResponse.statusCode, privacy: .public)，bytes=\(data.count, privacy: .public)")
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ReleaseVersionError.badStatusCode(httpResponse.statusCode)
            }
        }

        return try latestReleaseInfo(from: data)
    }

    static func latestReleaseInfo(from data: Data) throws -> LatestReleaseInfo {
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard let releaseDictionaries = jsonObject as? [[String: Any]] else {
            throw ReleaseVersionError.missingTagName
        }

        let releaseInfo = releaseDictionaries.compactMap { dictionary -> LatestReleaseInfo? in
            guard dictionary["draft"] as? Bool != true,
                  dictionary["prerelease"] as? Bool != true,
                  let tagName = dictionary["tag_name"] as? String,
                  !tagName.isEmpty,
                  numericVersionParts(tagName) != nil else {
                return nil
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
        .max { left, right in
            compareVersions(left.tagName, right.tagName) == .orderedAscending
        }

        guard let releaseInfo else {
            throw ReleaseVersionError.missingTagName
        }

        return releaseInfo
    }

    static func isNewerRelease(currentVersion: String, latestTagName: String) -> Bool {
        compareVersions(currentVersion, latestTagName) == .orderedAscending
    }

    private static func compareVersions(_ leftVersion: String, _ rightVersion: String) -> ComparisonResult {
        guard let leftParts = numericVersionParts(leftVersion),
              let rightParts = numericVersionParts(rightVersion) else {
            return .orderedSame
        }

        let maxCount = max(leftParts.count, rightParts.count)

        for index in 0..<maxCount {
            let leftPart = index < leftParts.count ? leftParts[index] : 0
            let rightPart = index < rightParts.count ? rightParts[index] : 0
            if leftPart != rightPart {
                return leftPart < rightPart ? .orderedAscending : .orderedDescending
            }
        }

        return .orderedSame
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
            return "GitHub Releases 响应缺少可用版本标签"
        }
    }
}
