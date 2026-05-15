import Foundation

enum JSONFormatterService {
    static func format(_ input: String) throws -> String {
        try transform(input, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    static func compact(_ input: String) throws -> String {
        try transform(input, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func transform(_ input: String, options: JSONSerialization.WritingOptions) throws -> String {
        let data = Data(input.utf8)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let outputData = try JSONSerialization.data(withJSONObject: jsonObject, options: options)

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw JSONFormatterError.encodingFailed
        }

        return output
    }
}

enum JSONFormatterError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "JSON 格式化结果编码失败"
        }
    }
}
