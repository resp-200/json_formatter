import Foundation
import JavaScriptCore
import OSLog

public enum JSONFormatterService {
    private static let logger = Logger(subsystem: "local.json-formatter.app", category: "JSONFormatterService")
    private static let decimalNumberParsingLocale = Locale(identifier: "en_US_POSIX")

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

    public static func evaluateQuery(_ input: String, expression: String) throws -> String {
        let jsonObject = try parseForFormatting(input)
        let evaluatedObject = try JSONQueryExpressionEvaluator.evaluate(jsonObject, expression: expression)
        return try serialize(evaluatedObject, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    public static func diff(_ leftInput: String, _ rightInput: String) throws -> JSONDiffResult {
        guard !leftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONDiffError.invalidLeftJSON("内容为空")
        }
        guard !rightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONDiffError.invalidRightJSON("内容为空")
        }

        let leftObject: Any
        do {
            leftObject = try parse(leftInput, postParseTransform: { $0 })
        } catch {
            throw JSONDiffError.invalidLeftJSON(error.localizedDescription)
        }

        let rightObject: Any
        do {
            rightObject = try parse(rightInput, postParseTransform: { $0 })
        } catch {
            throw JSONDiffError.invalidRightJSON(error.localizedDescription)
        }

        var differences: [JSONDifference] = []
        try collectDifferences(left: leftObject, right: rightObject, path: "$", into: &differences)
        return JSONDiffResult(differences: differences)
    }

    private static func transform(_ input: String, options: JSONSerialization.WritingOptions) throws -> String {
        let jsonObject = try parse(input, postParseTransform: { $0 })
        return try serialize(jsonObject, options: options)
    }

    private static func transformForFormatting(_ input: String, options: JSONSerialization.WritingOptions) throws -> String {
        let jsonObject = try parseForFormatting(input)
        return try serialize(jsonObject, options: options)
    }

    private static func parseForFormatting(_ input: String) throws -> Any {
        do {
            return try parse(input, postParseTransform: decodedEscapedJSONIfNeeded)
        } catch {
            guard let decodedObject = try? decodeEscapedJSONObjectOrArrayWithoutOuterQuotes(input) else {
                throw error
            }

            return decodedObject
        }
    }

    private static func parse(
        _ input: String,
        postParseTransform: (Any) throws -> Any
    ) throws -> Any {
        do {
            return try parseStrict(input, postParseTransform: postParseTransform)
        } catch let strictParseError {
            let normalizedInput = normalizeSmartQuotes(input)
            guard normalizedInput != input else {
                throw strictParseError
            }

            do {
                return try parseStrict(normalizedInput, postParseTransform: postParseTransform)
            } catch {
                throw strictParseError
            }
        }
    }

    private static func parseStrict(
        _ input: String,
        postParseTransform: (Any) throws -> Any
    ) throws -> Any {
        let data = Data(input.utf8)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try postParseTransform(jsonObject)
    }

    private static func serialize(_ jsonObject: Any, options: JSONSerialization.WritingOptions) throws -> String {
        let normalizedObject = readableDecimalNumberValue(jsonObject)
        let outputData = try JSONSerialization.data(withJSONObject: normalizedObject, options: options)

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw JSONFormatterError.encodingFailed
        }

        return output
    }

    private static func readableDecimalNumberValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var normalizedDictionary: [String: Any] = [:]
            for (key, value) in dictionary {
                normalizedDictionary[key] = readableDecimalNumberValue(value)
            }
            return normalizedDictionary
        case let dictionary as NSDictionary:
            var normalizedDictionary: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else {
                    return dictionary
                }
                normalizedDictionary[key] = readableDecimalNumberValue(value)
            }
            return normalizedDictionary
        case let array as [Any]:
            return array.map(readableDecimalNumberValue)
        case let array as NSArray:
            return array.map { readableDecimalNumberValue($0) }
        case let number as NSDecimalNumber:
            return number
        case let number as NSNumber:
            return readableDecimalNumber(from: number) ?? number
        default:
            return value
        }
    }

    private static func readableDecimalNumber(from number: NSNumber) -> NSDecimalNumber? {
        guard !isBooleanNumber(number), isFloatingPointNumber(number) else {
            return nil
        }

        let readableNumberText = String(number.doubleValue)
        let decimalNumber = NSDecimalNumber(string: readableNumberText, locale: decimalNumberParsingLocale)
        guard !decimalNumber.isEqual(to: NSDecimalNumber.notANumber) else {
            logger.info("JSON 浮点数可读格式归一化跳过，原始值无法转换为十进制表示，数值类型 \(CFNumberGetType(number).rawValue, privacy: .public)")
            return nil
        }

        return decimalNumber
    }

    private static func isBooleanNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isFloatingPointNumber(_ number: NSNumber) -> Bool {
        switch CFNumberGetType(number) {
        case .floatType, .float32Type, .doubleType, .float64Type, .cgFloatType:
            return true
        default:
            return false
        }
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

    private static func collectDifferences(
        left: Any,
        right: Any,
        path: String,
        into differences: inout [JSONDifference]
    ) throws {
        if let leftObject = stringKeyedDictionary(left), let rightObject = stringKeyedDictionary(right) {
            let allKeys = Set(leftObject.keys).union(rightObject.keys).sorted()
            for key in allKeys {
                let childPath = jsonPath(path, appendingKey: key)
                switch (leftObject[key], rightObject[key]) {
                case (.some(let leftValue), .some(let rightValue)):
                    try collectDifferences(left: leftValue, right: rightValue, path: childPath, into: &differences)
                case (.some(let leftValue), .none):
                    differences.append(JSONDifference(
                        kind: .removed,
                        path: childPath,
                        oldValue: try displayValue(leftValue),
                        newValue: nil
                    ))
                case (.none, .some(let rightValue)):
                    differences.append(JSONDifference(
                        kind: .added,
                        path: childPath,
                        oldValue: nil,
                        newValue: try displayValue(rightValue)
                    ))
                case (.none, .none):
                    break
                }
            }
            return
        }

        if let leftArray = jsonArray(left), let rightArray = jsonArray(right) {
            let commonCount = min(leftArray.count, rightArray.count)
            for index in 0..<commonCount {
                try collectDifferences(
                    left: leftArray[index],
                    right: rightArray[index],
                    path: "\(path)[\(index)]",
                    into: &differences
                )
            }
            if leftArray.count > commonCount {
                for index in commonCount..<leftArray.count {
                    differences.append(JSONDifference(
                        kind: .removed,
                        path: "\(path)[\(index)]",
                        oldValue: try displayValue(leftArray[index]),
                        newValue: nil
                    ))
                }
            } else if rightArray.count > commonCount {
                for index in commonCount..<rightArray.count {
                    differences.append(JSONDifference(
                        kind: .added,
                        path: "\(path)[\(index)]",
                        oldValue: nil,
                        newValue: try displayValue(rightArray[index])
                    ))
                }
            }
            return
        }

        guard scalarValuesAreEqual(left, right) else {
            differences.append(JSONDifference(
                kind: .changed,
                path: path,
                oldValue: try displayValue(left),
                newValue: try displayValue(right)
            ))
            return
        }
    }

    private static func stringKeyedDictionary(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let dictionary = value as? NSDictionary else {
            return nil
        }

        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String else {
                return nil
            }
            result[key] = value
        }
        return result
    }

    private static func jsonArray(_ value: Any) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        return (value as? NSArray)?.map { $0 }
    }

    private static func scalarValuesAreEqual(_ left: Any, _ right: Any) -> Bool {
        if left is NSNull || right is NSNull {
            return left is NSNull && right is NSNull
        }
        if let leftString = left as? String, let rightString = right as? String {
            return leftString == rightString
        }
        if let leftNumber = left as? NSNumber, let rightNumber = right as? NSNumber {
            let leftIsBoolean = isBooleanNumber(leftNumber)
            let rightIsBoolean = isBooleanNumber(rightNumber)
            guard leftIsBoolean == rightIsBoolean else {
                return false
            }
            return leftNumber.compare(rightNumber) == .orderedSame
        }
        return false
    }

    private static func displayValue(_ value: Any) throws -> String {
        try serialize(value, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func jsonPath(_ parent: String, appendingKey key: String) -> String {
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        let isSimpleIdentifier = !key.isEmpty
            && key.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
            && key.unicodeScalars.first.map { !CharacterSet.decimalDigits.contains($0) } == true
        if isSimpleIdentifier {
            return "\(parent).\(key)"
        }

        // JSON encoding also escapes control characters, keeping bracket
        // segments unambiguous and safe to copy.
        let encodedKey = (try? serialize(key, options: [.fragmentsAllowed])) ?? "\"\(key)\""
        return "\(parent)[\(encodedKey)]"
    }
}

public struct JSONDiffResult: Equatable, Sendable {
    public let differences: [JSONDifference]

    public var isIdentical: Bool {
        differences.isEmpty
    }
}

public struct JSONDifference: Equatable, Identifiable, Sendable {
    public let kind: JSONDifferenceKind
    public let path: String
    public let oldValue: String?
    public let newValue: String?

    public var id: String {
        "\(kind.rawValue):\(path)"
    }
}

public enum JSONDifferenceKind: String, Equatable, Sendable {
    case added
    case removed
    case changed
}

public enum JSONDiffError: LocalizedError, Equatable {
    case invalidLeftJSON(String)
    case invalidRightJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLeftJSON(let message):
            return "左侧 JSON 解析失败：\(message)"
        case .invalidRightJSON(let message):
            return "右侧 JSON 解析失败：\(message)"
        }
    }
}

public enum JSONFormatterError: LocalizedError {
    case encodingFailed
    case unsupportedDecodedJSON
    case emptyQueryExpression
    case unsafeQueryExpression(String)
    case queryEvaluationFailed(String)
    case queryReturnedUndefined
    case queryReturnedUnsupportedValue

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "JSON 格式化结果编码失败"
        case .unsupportedDecodedJSON:
            return "解码后的内容不是 JSON 对象或数组"
        case .emptyQueryExpression:
            return "JS 表达式不能为空"
        case .unsafeQueryExpression(let reason):
            return "JS 表达式包含不支持的内容：\(reason)"
        case .queryEvaluationFailed(let message):
            return "JS 表达式执行失败：\(message)"
        case .queryReturnedUndefined:
            return "JS 表达式结果为 undefined，无法转换为 JSON"
        case .queryReturnedUnsupportedValue:
            return "JS 表达式结果不是可序列化的 JSON 值"
        }
    }
}

private enum JSONQueryExpressionEvaluator {
    private static let logger = Logger(subsystem: "local.json-formatter.app", category: "JSONQueryExpressionEvaluator")
    private static let maxExpressionLength = 4_000
    private static let forbiddenKeywords = [
        "eval",
        "Function",
        "constructor",
        "globalThis",
        "this",
        "window",
        "document",
        "process",
        "Deno",
        "Bun",
        "while",
        "for",
        "import",
        "require",
        "fetch",
        "XMLHttpRequest",
        "WebSocket",
        "setTimeout",
        "setInterval",
        "setImmediate",
        "importScripts"
    ]

    static func evaluate(_ jsonObject: Any, expression: String) throws -> Any {
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("开始执行本地 JS JSON 查询，输入类型 \(String(describing: type(of: jsonObject)), privacy: .public)，表达式长度 \(trimmedExpression.count, privacy: .public)")
        try validate(trimmedExpression)

        let inputData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.fragmentsAllowed])
        guard let inputJSONString = String(data: inputData, encoding: .utf8) else {
            throw JSONFormatterError.encodingFailed
        }

        guard let context = JSContext() else {
            throw JSONFormatterError.queryEvaluationFailed("JavaScriptCore 上下文创建失败")
        }

        var capturedException: String?
        context.exceptionHandler = { _, exception in
            capturedException = exception?.toString()
        }
        context.setObject(inputJSONString as NSString, forKeyedSubscript: "__jsonFormatterInputText" as NSString)

        let script = buildScript(for: trimmedExpression)
        guard let result = context.evaluateScript(script) else {
            throw JSONFormatterError.queryEvaluationFailed(capturedException ?? "表达式无返回结果")
        }

        if let capturedException {
            throw JSONFormatterError.queryEvaluationFailed(capturedException)
        }

        if result.isUndefined {
            throw JSONFormatterError.queryReturnedUndefined
        }

        if result.isNull {
            return NSNull()
        }

        let object = result.toObject() ?? NSNull()
        let normalizedResult = try normalizedJSONValue(object)
        logger.info("本地 JS JSON 查询执行成功，结果类型 \(String(describing: type(of: normalizedResult)), privacy: .public)")
        return normalizedResult
    }

    private static func validate(_ expression: String) throws {
        guard !expression.isEmpty else {
            throw JSONFormatterError.emptyQueryExpression
        }

        guard expression.count <= maxExpressionLength else {
            throw JSONFormatterError.unsafeQueryExpression("表达式长度超过 \(maxExpressionLength) 个字符")
        }

        guard !expression.contains(";") else {
            throw JSONFormatterError.unsafeQueryExpression("不支持语句分隔符 ;，请只输入一个表达式")
        }

        for keyword in forbiddenKeywords {
            guard !containsJavaScriptIdentifier(keyword, in: expression) else {
                throw JSONFormatterError.unsafeQueryExpression("不支持使用 \(keyword)")
            }
        }
    }

    private static func buildScript(for expression: String) -> String {
        let restrictedGlobals = """
            var globalThis = undefined;
            var window = undefined;
            var document = undefined;
            var process = undefined;
            var Deno = undefined;
            var Bun = undefined;
            var fetch = undefined;
            var XMLHttpRequest = undefined;
            var WebSocket = undefined;
            var require = undefined;
            var importScripts = undefined;
            var setTimeout = undefined;
            var setInterval = undefined;
            var setImmediate = undefined;
        """

        if expression.hasPrefix(".") || expression.hasPrefix("[") {
            return """
            (function() {
                'use strict';
                var value = JSON.parse(__jsonFormatterInputText);
                var input = value;
                var $ = value;
            \(restrictedGlobals)
                try {
                    return value\(expression);
                } catch (error) {
                    if (!value || Array.isArray(value) || typeof value !== 'object') {
                        throw error;
                    }

                    var objectValues = Object.values(value);
                    if (objectValues.length === 1 && Array.isArray(objectValues[0])) {
                        return objectValues[0]\(expression);
                    }

                    throw error;
                }
            })()
            """
        }

        return """
        (function() {
            'use strict';
            var value = JSON.parse(__jsonFormatterInputText);
            var input = value;
            var $ = value;
        \(restrictedGlobals)
            return (\(expression));
        })()
        """
    }

    private static func containsJavaScriptIdentifier(_ identifier: String, in expression: String) -> Bool {
        let escapedIdentifier = NSRegularExpression.escapedPattern(for: identifier)
        let pattern = "(?<![A-Za-z0-9_$])\(escapedIdentifier)(?![A-Za-z0-9_$])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return expression.contains(identifier)
        }

        let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        return regex.firstMatch(in: expression, range: range) != nil
    }

    private static func normalizedJSONValue(_ value: Any) throws -> Any {
        switch value {
        case _ as NSNull:
            return NSNull()
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let array as [Any]:
            return try array.map(normalizedJSONValue)
        case let array as NSArray:
            return try array.map { try normalizedJSONValue($0) }
        case let dictionary as [String: Any]:
            var normalizedDictionary: [String: Any] = [:]
            for (key, value) in dictionary {
                normalizedDictionary[key] = try normalizedJSONValue(value)
            }
            return normalizedDictionary
        case let dictionary as NSDictionary:
            var normalizedDictionary: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else {
                    throw JSONFormatterError.queryReturnedUnsupportedValue
                }
                normalizedDictionary[key] = try normalizedJSONValue(value)
            }
            return normalizedDictionary
        default:
            throw JSONFormatterError.queryReturnedUnsupportedValue
        }
    }
}
