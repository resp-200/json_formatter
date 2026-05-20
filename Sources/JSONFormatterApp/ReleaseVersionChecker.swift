import Foundation
import OSLog

struct LatestReleaseInfo: Equatable, Sendable {
    let tagName: String
    let htmlURL: URL
}

enum ReleaseVersionChecker {
    static let releasesPageURL = URL(string: "https://github.com/resp-200/json_formatter/releases")!
    private static let latestManifestURL = URL(string: "https://raw.githubusercontent.com/resp-200/json_formatter/main/latest-release.json")!
    private static let releasesAPIURL = URL(string: "https://api.github.com/repos/resp-200/json_formatter/releases?per_page=30")!
    private static let logger = Logger(subsystem: "local.json-formatter.app", category: "ReleaseVersion")

    static func fetchLatestRelease() async throws -> LatestReleaseInfo {
        do {
            return try await fetchLatestManifestRelease()
        } catch {
            logger.error("静态版本清单检测失败，将回退到 GitHub Releases 接口，错误 \(error.localizedDescription, privacy: .public)")
            return try await fetchGitHubRelease()
        }
    }

    static func latestManifestReleaseInfo(from data: Data) throws -> LatestReleaseInfo {
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = jsonObject as? [String: Any],
              let version = dictionary["version"] as? String,
              !version.isEmpty,
              numericVersionParts(version) != nil else {
            throw ReleaseVersionError.missingTagName
        }

        let htmlURL: URL
        if let urlString = dictionary["url"] as? String,
           let parsedHTMLURL = URL(string: urlString),
           parsedHTMLURL.scheme != nil {
            htmlURL = parsedHTMLURL
        } else {
            htmlURL = releasesPageURL
        }

        return LatestReleaseInfo(tagName: version, htmlURL: htmlURL)
    }

    static func latestReleaseInfo(manifestData: Data, fallbackReleasesData: Data) throws -> LatestReleaseInfo {
        do {
            return try latestManifestReleaseInfo(from: manifestData)
        } catch {
            return try latestReleaseInfo(from: fallbackReleasesData)
        }
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

    private static func fetchLatestManifestRelease() async throws -> LatestReleaseInfo {
        logger.info("开始请求静态版本清单，地址 \(latestManifestURL.absoluteString, privacy: .public)")
        let request = makeRequest(url: latestManifestURL, accept: "application/json", timeoutInterval: 10)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            logger.info("静态版本清单请求完成，状态码 \(httpResponse.statusCode, privacy: .public)，响应大小 \(data.count, privacy: .public) 字节")
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ReleaseVersionError.badStatusCode(httpResponse.statusCode)
            }
        }

        return try latestManifestReleaseInfo(from: data)
    }

    private static func fetchGitHubRelease() async throws -> LatestReleaseInfo {
        logger.info("开始检测 GitHub Releases 版本列表，地址 \(releasesAPIURL.absoluteString, privacy: .public)")
        let request = makeRequest(url: releasesAPIURL, accept: "application/vnd.github+json", timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            logger.info("GitHub Releases 版本列表接口返回，状态码 \(httpResponse.statusCode, privacy: .public)，响应大小 \(data.count, privacy: .public) 字节")
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ReleaseVersionError.badStatusCode(httpResponse.statusCode)
            }
        }

        return try latestReleaseInfo(from: data)
    }

    private static func makeRequest(url: URL, accept: String, timeoutInterval: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeoutInterval)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("JSONFormatterApp", forHTTPHeaderField: "User-Agent")
        return request
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
            return "版本检测接口返回异常状态码：\(statusCode)"
        case .missingTagName:
            return "版本检测响应缺少可用版本信息"
        }
    }
}
