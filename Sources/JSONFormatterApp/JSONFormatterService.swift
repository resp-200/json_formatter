import Foundation

public enum JSONFormatterService {
    public static func format(_ input: String) throws -> String {
        try transform(input, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    public static func compact(_ input: String) throws -> String {
        try transform(input, options: [.sortedKeys, .fragmentsAllowed])
    }

    public static func escape(_ input: String) throws -> String {
        // 先复用压缩入口完成 JSON 校验，再编码成可直接粘贴的 JSON 字符串。
        let compactedJSON = try compact(input)
        let outputData = try JSONSerialization.data(withJSONObject: compactedJSON, options: [.fragmentsAllowed])

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw JSONFormatterError.encodingFailed
        }

        return output
    }

    private static func transform(_ input: String, options: JSONSerialization.WritingOptions) throws -> String {
        do {
            return try transformStrict(input, options: options)
        } catch {
            let normalizedInput = normalizeSmartQuotes(input)
            guard normalizedInput != input else {
                throw error
            }

            do {
                return try transformStrict(normalizedInput, options: options)
            } catch {
                throw error
            }
        }
    }

    private static func transformStrict(_ input: String, options: JSONSerialization.WritingOptions) throws -> String {
        let data = Data(input.utf8)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let outputData = try JSONSerialization.data(withJSONObject: jsonObject, options: options)

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw JSONFormatterError.encodingFailed
        }

        return output
    }

    private static func normalizeSmartQuotes(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }
}

public enum JSONFormatterError: LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "JSON 格式化结果编码失败"
        }
    }
}
