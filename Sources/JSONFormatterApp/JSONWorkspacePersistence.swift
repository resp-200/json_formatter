import Foundation

struct JSONWorkspacePersistenceDocument: Codable, Equatable, Sendable {
    var version: Int
    var pages: [JSONWorkspacePersistencePage]
    var selectedPageID: UUID?
    var nextPageNumber: Int
}

struct JSONWorkspacePersistencePage: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var inputText: String
    var outputText: String
    var errorMessage: String
    var queryExpression: String
    var searchQuery: String
    var outputDisplayMode: String
    var updatedAt: Date
}

enum JSONWorkspacePersistenceError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法定位 Application Support 目录"
        }
    }
}

enum JSONWorkspacePersistence {
    static let documentVersion = 1
    static let directoryName = "JSON Formatter"
    static let fileName = "workspace.json"

    static func workspaceFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw JSONWorkspacePersistenceError.applicationSupportUnavailable
        }

        return applicationSupportURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func loadDocument(fileManager: FileManager = .default) throws -> JSONWorkspacePersistenceDocument? {
        let fileURL = try workspaceFileURL(fileManager: fileManager)
        return try loadDocument(from: fileURL, fileManager: fileManager)
    }

    static func loadDocument(from fileURL: URL, fileManager: FileManager = .default) throws -> JSONWorkspacePersistenceDocument? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(JSONWorkspacePersistenceDocument.self, from: data)
    }

    static func save(_ document: JSONWorkspacePersistenceDocument, fileManager: FileManager = .default) throws {
        let fileURL = try workspaceFileURL(fileManager: fileManager)
        try save(document, to: fileURL, fileManager: fileManager)
    }

    static func save(_ document: JSONWorkspacePersistenceDocument, to fileURL: URL, fileManager: FileManager = .default) throws {
        // 工作区只保存可恢复的文本和页面元数据，树形节点等派生对象重新构建。
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic])
    }
}
