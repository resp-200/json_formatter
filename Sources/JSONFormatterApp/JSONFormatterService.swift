import Foundation

public enum JSONFormatterService {
    public static func format(_ input: String) throws -> String {
        try transformForFormatting(input, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
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
        try transform(input, options: options) { $0 }
    }

    private static func transformForFormatting(_ input: String, options: JSONSerialization.WritingOptions) throws -> String {
        do {
            return try transform(input, options: options, postParseTransform: decodedEscapedJSONIfNeeded)
        } catch {
            guard let decodedObject = try? decodeEscapedJSONObjectOrArrayWithoutOuterQuotes(input) else {
                throw error
            }

            return try serialize(decodedObject, options: options)
        }
    }

    private static func transform(
        _ input: String,
        options: JSONSerialization.WritingOptions,
        postParseTransform: (Any) throws -> Any
    ) throws -> String {
        do {
            return try transformStrict(input, options: options, postParseTransform: postParseTransform)
        } catch {
            let normalizedInput = normalizeSmartQuotes(input)
            guard normalizedInput != input else {
                throw error
            }

            do {
                return try transformStrict(normalizedInput, options: options, postParseTransform: postParseTransform)
            } catch {
                throw error
            }
        }
    }

    private static func transformStrict(
        _ input: String,
        options: JSONSerialization.WritingOptions,
        postParseTransform: (Any) throws -> Any
    ) throws -> String {
        let data = Data(input.utf8)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let transformedObject = try postParseTransform(jsonObject)

        return try serialize(transformedObject, options: options)
    }

    private static func serialize(_ jsonObject: Any, options: JSONSerialization.WritingOptions) throws -> String {
        let outputData = try JSONSerialization.data(withJSONObject: jsonObject, options: options)

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw JSONFormatterError.encodingFailed
        }

        return output
    }

    private static func decodedEscapedJSONIfNeeded(_ jsonObject: Any) throws -> Any {
        guard let decodedString = jsonObject as? String,
              let decodedObject = try? parseJSONObjectOrArray(decodedString) else {
            return jsonObject
        }

        return decodedObject
    }

    private static func decodeEscapedJSONObjectOrArrayWithoutOuterQuotes(_ input: String) throws -> Any {
        let wrapper = "\"" + input + "\""
        let data = Data(wrapper.utf8)
        let decodedString = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String

        guard let decodedString else {
            throw JSONFormatterError.unsupportedDecodedJSON
        }

        return try parseJSONObjectOrArray(decodedString)
    }

    private static func parseJSONObjectOrArray(_ input: String) throws -> Any {
        let data = Data(input.utf8)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])

        guard jsonObject is [String: Any] || jsonObject is [Any] else {
            throw JSONFormatterError.unsupportedDecodedJSON
        }

        return jsonObject
    }

    private static func normalizeSmartQuotes(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }
}

public enum JSONFormatterError: LocalizedError {
    case encodingFailed
    case unsupportedDecodedJSON

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "JSON 格式化结果编码失败"
        case .unsupportedDecodedJSON:
            return "解码后的内容不是 JSON 对象或数组"
        }
    }
}
