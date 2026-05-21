import Foundation

struct JSONTreeNode: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let summary: String
    let children: [JSONTreeNode]

    var isExpandable: Bool {
        !children.isEmpty
    }

    func allExpandableNodeIDs() -> Set<String> {
        var ids = Set<String>()
        collectExpandableNodeIDs(into: &ids)
        return ids
    }

    func searchMatches(query: String, limit: Int = 2_000) -> [JSONTreeSearchMatch] {
        let normalizedQuery = JSONTreeSearchNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        var matches: [JSONTreeSearchMatch] = []
        collectSearchMatches(query: normalizedQuery, ancestors: [], limit: max(limit, 0), into: &matches)
        return matches
    }

    private func collectExpandableNodeIDs(into ids: inout Set<String>) {
        if isExpandable {
            ids.insert(id)
        }

        for child in children {
            child.collectExpandableNodeIDs(into: &ids)
        }
    }

    private func collectSearchMatches(
        query: String,
        ancestors: [String],
        limit: Int,
        into matches: inout [JSONTreeSearchMatch]
    ) {
        guard matches.count < limit else {
            return
        }

        let searchableText = JSONTreeSearchNormalizer.normalize(label + " " + summary)
        if searchableText.contains(query) {
            matches.append(JSONTreeSearchMatch(nodeID: id, ancestorIDs: ancestors))
        }

        guard matches.count < limit else {
            return
        }

        let childAncestors = isExpandable ? ancestors + [id] : ancestors
        for child in children {
            child.collectSearchMatches(query: query, ancestors: childAncestors, limit: limit, into: &matches)
            guard matches.count < limit else {
                return
            }
        }
    }
}

struct JSONTreeSearchMatch: Equatable, Sendable {
    let nodeID: String
    let ancestorIDs: [String]
}

enum JSONTreeBuilder {
    static func build(from text: String) throws -> JSONTreeNode {
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return buildNode(label: "$", value: object, path: "$")
    }

    private static func buildNode(label: String, value: Any, path: String) -> JSONTreeNode {
        switch value {
        case let dictionary as [String: Any]:
            let sortedKeys = dictionary.keys.sorted()
            let children = sortedKeys.map { key in
                buildNode(label: key, value: dictionary[key] ?? NSNull(), path: pathComponent(parent: path, key: key))
            }
            return JSONTreeNode(id: path, label: label, summary: objectSummary(count: sortedKeys.count), children: children)
        case let dictionary as NSDictionary:
            let keys = dictionary.allKeys.compactMap { $0 as? String }.sorted()
            let children = keys.map { key in
                buildNode(label: key, value: dictionary[key] ?? NSNull(), path: pathComponent(parent: path, key: key))
            }
            return JSONTreeNode(id: path, label: label, summary: objectSummary(count: keys.count), children: children)
        case let array as [Any]:
            let children = array.enumerated().map { index, value in
                buildNode(label: "[\(index)]", value: value, path: "\(path)[\(index)]")
            }
            return JSONTreeNode(id: path, label: label, summary: arraySummary(count: array.count), children: children)
        case let array as NSArray:
            let children = array.enumerated().map { index, value in
                buildNode(label: "[\(index)]", value: value, path: "\(path)[\(index)]")
            }
            return JSONTreeNode(id: path, label: label, summary: arraySummary(count: array.count), children: children)
        case let string as String:
            return JSONTreeNode(id: path, label: label, summary: quotedSummary(string), children: [])
        case let number as NSNumber:
            return JSONTreeNode(id: path, label: label, summary: numberSummary(number), children: [])
        case _ as NSNull:
            return JSONTreeNode(id: path, label: label, summary: "null", children: [])
        default:
            return JSONTreeNode(id: path, label: label, summary: String(describing: value), children: [])
        }
    }

    private static func objectSummary(count: Int) -> String {
        count == 0 ? "{ }" : "{ \(count) \(count == 1 ? "key" : "keys") }"
    }

    private static func arraySummary(count: Int) -> String {
        count == 0 ? "[ ]" : "[ \(count) \(count == 1 ? "item" : "items") ]"
    }

    private static func quotedSummary(_ string: String) -> String {
        let clippedString = string.count > 120 ? String(string.prefix(120)) + "…" : string
        if let data = try? JSONSerialization.data(withJSONObject: clippedString, options: [.fragmentsAllowed]),
           let quoted = String(data: data, encoding: .utf8) {
            return quoted
        }

        return "\"\(clippedString)\""
    }

    private static func numberSummary(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }

        return number.stringValue
    }

    private static func pathComponent(parent: String, key: String) -> String {
        let escapedKey = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "\(parent).\(escapedKey)"
    }
}

private enum JSONTreeSearchNormalizer {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
