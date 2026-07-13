import AppKit
import Foundation
import Testing
@testable import JSONFormatterApp

@Test @MainActor func editableJSONTextViewDoesNotTrackScrollViewportHeight() {
    let textView = NSTextView()

    JSONInputTextViewLayout.configure(textView)

    #expect(textView.isHorizontallyResizable)
    #expect(textView.isVerticallyResizable)
    #expect(textView.autoresizingMask.contains(.width))
    #expect(!textView.autoresizingMask.contains(.height))
    #expect(textView.textContainer?.widthTracksTextView == false)
    #expect(textView.textContainer?.heightTracksTextView == false)
    #expect(textView.textContainer?.containerSize.width == CGFloat.greatestFiniteMagnitude)
    #expect(textView.textContainer?.containerSize.height == CGFloat.greatestFiniteMagnitude)
}

@Test func jsonDiffIgnoresObjectKeyOrderAtEveryLevel() throws {
    let left = """
    {"a":1,"nested":{"x":true,"y":[1,2]},"b":2}
    """
    let right = """
    {"b":2,"nested":{"y":[1,2],"x":true},"a":1}
    """

    let result = try JSONFormatterService.diff(left, right)

    #expect(result.isIdentical)
    #expect(result.differences.isEmpty)
}

@Test func jsonDiffPreservesArrayOrder() throws {
    let result = try JSONFormatterService.diff("{\"items\":[1,2]}", "{\"items\":[2,1]}")

    #expect(!result.isIdentical)
    #expect(result.differences.map(\.path) == ["$.items[0]", "$.items[1]"])
    #expect(result.differences.allSatisfy { $0.kind == .changed })
}

@Test func jsonDiffReportsStableAddedRemovedAndChangedPaths() throws {
    let left = """
    {"removed":1,"changed":"old","nested":{"same":true},"array":[1]}
    """
    let right = """
    {"added":2,"changed":"new","nested":{"same":true},"array":[1,3]}
    """

    let result = try JSONFormatterService.diff(left, right)

    #expect(result.differences.map(\.path) == ["$.added", "$.array[1]", "$.changed", "$.removed"])
    #expect(result.differences.map(\.kind) == [.added, .added, .changed, .removed])
    #expect(result.differences[0].newValue == "2")
    #expect(result.differences[2].oldValue == "\"old\"")
    #expect(result.differences[2].newValue == "\"new\"")
    #expect(result.differences[3].oldValue == "1")
}

@Test func jsonDiffUsesEscapedBracketPathsForNonIdentifierKeys() throws {
    let result = try JSONFormatterService.diff(
        "{\"a.b\":1,\"line\\nkey\":true}",
        "{\"a.b\":2,\"line\\nkey\":false}"
    )

    #expect(result.differences.map(\.path) == ["$[\"a.b\"]", "$[\"line\\nkey\"]"])
}

@Test func jsonDiffDistinguishesBooleanNumbersAndContainerTypes() throws {
    let booleanAndNumber = try JSONFormatterService.diff("true", "1")
    let objectAndArray = try JSONFormatterService.diff("{}", "[]")
    let encodedObjectStringAndObject = try JSONFormatterService.diff("\"{\\\"a\\\":1}\"", "{\"a\":1}")

    #expect(booleanAndNumber.differences.map(\.path) == ["$"])
    #expect(booleanAndNumber.differences[0].oldValue == "true")
    #expect(booleanAndNumber.differences[0].newValue == "1")
    #expect(objectAndArray.differences.map(\.path) == ["$"])
    #expect(objectAndArray.differences[0].oldValue == "{}")
    #expect(objectAndArray.differences[0].newValue == "[]")
    #expect(encodedObjectStringAndObject.differences.map(\.path) == ["$"])
    #expect(encodedObjectStringAndObject.differences[0].oldValue == "\"{\\\"a\\\":1}\"")
    #expect(encodedObjectStringAndObject.differences[0].newValue == "{\"a\":1}")
}

@Test func jsonDiffReportsEmptyInputSide() {
    do {
        _ = try JSONFormatterService.diff(" \n", "{}")
        Issue.record("Expected the empty left input to fail")
    } catch let error as JSONDiffError {
        #expect(error == .invalidLeftJSON("内容为空"))
    } catch {
        Issue.record("Expected JSONDiffError, got \(error)")
    }

    do {
        _ = try JSONFormatterService.diff("{}", "\t")
        Issue.record("Expected the empty right input to fail")
    } catch let error as JSONDiffError {
        #expect(error == .invalidRightJSON("内容为空"))
    } catch {
        Issue.record("Expected JSONDiffError, got \(error)")
    }
}

@Test func jsonDiffIdentifiesTheInvalidInputSide() {
    #expect(throws: JSONDiffError.self) {
        try JSONFormatterService.diff("{bad}", "{}")
    }

    do {
        _ = try JSONFormatterService.diff("{}", "{bad}")
        Issue.record("Expected the right-side parse to fail")
    } catch let error as JSONDiffError {
        #expect(error.errorDescription?.hasPrefix("右侧 JSON 解析失败") == true)
    } catch {
        Issue.record("Expected JSONDiffError, got \(error)")
    }
}

@Test func formatObjectJSON() throws {
    let output = try JSONFormatterService.format("{\"b\":2,\"a\":1}")

    #expect(output.contains("\n"))
    #expect(output.contains("  \"a\" : 1"))
    #expect(output.contains("  \"b\" : 2"))
}

@Test func formatJSONEscapedObjectWithOuterQuotes() throws {
    let output = try JSONFormatterService.format("\"{\\\"b\\\":2,\\\"a\\\":1}\"")

    #expect(output.contains("\n"))
    #expect(output.contains("  \"a\" : 1"))
    #expect(output.contains("  \"b\" : 2"))
    #expect(!output.contains("\\\\\"a\\\\\""))
}

@Test func formatJSONEscapedObjectWithoutOuterQuotes() throws {
    let output = try JSONFormatterService.format("{\\\"b\\\":2,\\\"a\\\":1}")

    #expect(output.contains("\n"))
    #expect(output.contains("  \"a\" : 1"))
    #expect(output.contains("  \"b\" : 2"))
    #expect(!output.contains("\\\\\"a\\\\\""))
}

@Test func formatJSONEscapedArrayWithOuterQuotes() throws {
    let output = try JSONFormatterService.format("\"[\\\"b\\\",2,{\\\"a\\\":1}]\"")

    #expect(output.contains("\n"))
    #expect(output.contains("  \"b\""))
    #expect(output.contains("    \"a\" : 1"))
}

@Test func formatJSONEscapedArrayWithoutOuterQuotes() throws {
    let output = try JSONFormatterService.format("[\\\"b\\\",2,{\\\"a\\\":1}]")

    #expect(output.contains("\n"))
    #expect(output.contains("  \"b\""))
    #expect(output.contains("    \"a\" : 1"))
}

@Test func formatJSONStringWithoutEmbeddedJSONKeepsStringBehavior() throws {
    let output = try JSONFormatterService.format("\"hello\"")

    #expect(output == "\"hello\"")
}

@Test func formatDecimalNumbersKeepsReadablePrecision() throws {
    let input = """
    {
        "request": {
            "modelId": 17903,
            "cateId": 1100000172,
            "brandId": 11499,
            "latitude": 39.91,
            "longitude": 116.40
        }
    }
    """

    let output = try JSONFormatterService.format(input)

    #expect(output.contains("    \"latitude\" : 39.91"))
    #expect(output.contains("    \"longitude\" : 116.4"))
    #expect(!output.contains("39.909999999999997"))
    #expect(!output.contains("116.40000000000001"))
}

@Test func compactDecimalNumbersKeepsReadablePrecision() throws {
    let output = try JSONFormatterService.compact("{\"latitude\":39.91,\"longitude\":116.40}")

    #expect(output == "{\"latitude\":39.91,\"longitude\":116.4}")
}

@Test func compactDoesNotDecodeEscapedJSONString() throws {
    let output = try JSONFormatterService.compact("\"{\\\"b\\\":2,\\\"a\\\":1}\"")

    #expect(output == "\"{\\\"b\\\":2,\\\"a\\\":1}\"")
}

@Test func compactObjectJSON() throws {
    let output = try JSONFormatterService.compact("{\n  \"b\" : 2,\n  \"a\" : 1\n}")

    #expect(output == "{\"a\":1,\"b\":2}")
}

@Test func jsonTreeBuilderBuildsStableTreePaths() throws {
    let root = try JSONTreeBuilder.build(from: "{\"items\":[{\"name\":\"first\"}],\"meta\":{\"count\":1}}")

    #expect(root.id == "$")
    #expect(root.children.map(\.label) == ["items", "meta"])
    #expect(root.children[0].children[0].id == "$.items[0]")
    #expect(root.children[1].children[0].label == "count")
}

@Test func jsonTreeSearchMatchesLabelAndSummaryAndReturnsAncestors() throws {
    let root = try JSONTreeBuilder.build(from: "{\"items\":[{\"name\":\"first\",\"enabled\":true}],\"meta\":{\"count\":1}}")
    let labelMatches = root.searchMatches(query: "name")
    let summaryMatches = root.searchMatches(query: "FIRST")

    #expect(labelMatches.map(\.nodeID).contains("$.items[0].name"))
    #expect(labelMatches.first(where: { $0.nodeID == "$.items[0].name" })?.ancestorIDs == ["$", "$.items", "$.items[0]"])
    #expect(summaryMatches.map(\.nodeID).contains("$.items[0].name"))
}

@Test func jsonTreeExpandableIDsIncludeContainersOnly() throws {
    let root = try JSONTreeBuilder.build(from: "{\"items\":[{\"name\":\"first\"}],\"empty\":[]}")
    let expandableIDs = root.allExpandableNodeIDs()

    #expect(expandableIDs.contains("$"))
    #expect(expandableIDs.contains("$.items"))
    #expect(expandableIDs.contains("$.items[0]"))
    #expect(!expandableIDs.contains("$.items[0].name"))
    #expect(!expandableIDs.contains("$.empty"))
}

@Test func queryExpressionMapsNestedArray() throws {
    let output = try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: ".hi.map(x => x * 2)")

    #expect(output == "[\n  2,\n  4,\n  6\n]")
}

@Test func queryExpressionFiltersAndMapsArray() throws {
    let output = try JSONFormatterService.evaluateQuery(
        "[{\"name\":\"a\",\"score\":1},{\"name\":\"b\",\"score\":3},{\"name\":\"c\",\"score\":5}]",
        expression: ".filter(x => x.score >= 3).map(x => x.name)"
    )

    #expect(output == "[\n  \"b\",\n  \"c\"\n]")
}

@Test func queryExpressionFiltersSingleNestedArrayByChain() throws {
    let output = try JSONFormatterService.evaluateQuery(
        "{\"items\":[{\"name\":\"a\",\"score\":1},{\"name\":\"b\",\"score\":3}]}",
        expression: ".filter(x => x.score >= 3)"
    )

    #expect(output.contains("    \"name\" : \"b\""))
    #expect(!output.contains("\"name\" : \"a\""))
}

@Test func queryExpressionCanUseValueAlias() throws {
    let output = try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: "value.hi.filter(x => x > 1)")

    #expect(output == "[\n  2,\n  3\n]")
}

@Test func queryExpressionCanUseInputAndDollarAliases() throws {
    let inputAliasOutput = try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: "input.hi.map(x => x + 1)")
    let dollarAliasOutput = try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: "$.hi.filter(x => x < 3)")

    #expect(inputAliasOutput == "[\n  2,\n  3,\n  4\n]")
    #expect(dollarAliasOutput == "[\n  1,\n  2\n]")
}

@Test func queryExpressionRejectsInvalidExpression() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: ".hi.map(")
    }
}

@Test func queryExpressionRejectsUnsafeExpression() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: "Function('return 1')()")
    }
}

@Test func queryExpressionRejectsGlobalAccess() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: "globalThis")
    }
}

@Test func queryExpressionRejectsSemicolonStatements() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: "value.hi; value")
    }
}

@Test func queryExpressionRejectsUnsupportedResult() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.evaluateQuery("{\"hi\":[1,2,3]}", expression: "value.hi.map")
    }
}

@Test func escapeObjectJSON() throws {
    let output = try JSONFormatterService.escape("{\n  \"b\" : 2,\n  \"a\" : \"hello\"\n}")

    #expect(output == "\"{\\\"a\\\":\\\"hello\\\",\\\"b\\\":2}\"")
}

@Test func escapedObjectJSONCanDecodeBackToCompactedJSONString() throws {
    let output = try JSONFormatterService.escape("{\"text\":\"line1\\nline2\",\"quote\":\"\\\"hi\\\"\"}")
    let data = try #require(output.data(using: .utf8))
    let decoded = try #require(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String)

    #expect(decoded == "{\"quote\":\"\\\"hi\\\"\",\"text\":\"line1\\nline2\"}")
}

@Test func escapeRejectsInvalidJSON() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.escape("{bad json}")
    }
}

@Test func releaseVersionCheckerDetectsNewerSemverTag() {
    #expect(ReleaseVersionChecker.isNewerRelease(currentVersion: "1.0.1", latestTagName: "v1.0.2"))
    #expect(ReleaseVersionChecker.isNewerRelease(currentVersion: "1.0.1", latestTagName: "1.1.0"))
    #expect(ReleaseVersionChecker.isNewerRelease(currentVersion: "v1.0.1", latestTagName: "v1.0.2"))
    #expect(ReleaseVersionChecker.isNewerRelease(currentVersion: "1.0.1", latestTagName: "v1.0.2-beta"))
    #expect(!ReleaseVersionChecker.isNewerRelease(currentVersion: "1.0.1", latestTagName: "v1.0.1"))
    #expect(!ReleaseVersionChecker.isNewerRelease(currentVersion: "1.0.1", latestTagName: "v1.0.0"))
    #expect(!ReleaseVersionChecker.isNewerRelease(currentVersion: "开发版", latestTagName: "v1.0.2"))
}

@Test func releaseVersionCheckerParsesLatestManifest() throws {
    let manifestJSON = """
    {"version":"1.0.7","url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.7"}
    """
    let data = try #require(manifestJSON.data(using: .utf8))

    let releaseInfo = try ReleaseVersionChecker.latestManifestReleaseInfo(from: data)

    #expect(releaseInfo.tagName == "1.0.7")
    #expect(releaseInfo.htmlURL.absoluteString == "https://github.com/resp-200/json_formatter/releases/tag/v1.0.7")
}

@Test func releaseVersionCheckerManifestFallsBackToReleasesPageWithoutURL() throws {
    let manifestJSON = """
    {"version":"v1.0.5"}
    """
    let data = try #require(manifestJSON.data(using: .utf8))

    let releaseInfo = try ReleaseVersionChecker.latestManifestReleaseInfo(from: data)

    #expect(releaseInfo.tagName == "v1.0.5")
    #expect(releaseInfo.htmlURL == ReleaseVersionChecker.releasesPageURL)
}

@Test func releaseVersionCheckerUsesManifestBeforeFallbackData() throws {
    let manifestJSON = """
    {"version":"1.0.7","url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.7"}
    """
    let releasesJSON = """
    [
      {"tag_name":"v9.0.0","html_url":"https://github.com/resp-200/json_formatter/releases","draft":false,"prerelease":false}
    ]
    """
    let manifestData = try #require(manifestJSON.data(using: .utf8))
    let releasesData = try #require(releasesJSON.data(using: .utf8))

    let releaseInfo = try ReleaseVersionChecker.latestReleaseInfo(manifestData: manifestData, fallbackReleasesData: releasesData)

    #expect(releaseInfo.tagName == "1.0.7")
    #expect(releaseInfo.htmlURL.absoluteString == "https://github.com/resp-200/json_formatter/releases/tag/v1.0.7")
}

@Test func releaseVersionCheckerFallsBackWhenManifestInvalid() throws {
    let manifestJSON = """
    {"version":"开发版","url":"https://github.com/resp-200/json_formatter/releases/tag/dev"}
    """
    let releasesJSON = """
    [
      {"tag_name":"v1.0.7","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.7","draft":false,"prerelease":false}
    ]
    """
    let manifestData = try #require(manifestJSON.data(using: .utf8))
    let releasesData = try #require(releasesJSON.data(using: .utf8))

    let releaseInfo = try ReleaseVersionChecker.latestReleaseInfo(manifestData: manifestData, fallbackReleasesData: releasesData)

    #expect(releaseInfo.tagName == "v1.0.7")
    #expect(releaseInfo.htmlURL.absoluteString == "https://github.com/resp-200/json_formatter/releases/tag/v1.0.7")
}

@Test func releaseVersionCheckerSelectsHighestStableReleaseFromList() throws {
    let releasesJSON = """
    [
      {"tag_name":"v1.0.3","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.3","draft":false,"prerelease":false},
      {"tag_name":"v1.0.5-beta","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.5-beta","draft":false,"prerelease":true},
      {"tag_name":"v1.0.4","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.4","draft":false,"prerelease":false},
      {"tag_name":"v1.0.7","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.7","draft":true,"prerelease":false}
    ]
    """
    let data = try #require(releasesJSON.data(using: .utf8))

    let releaseInfo = try ReleaseVersionChecker.latestReleaseInfo(from: data)

    #expect(releaseInfo.tagName == "v1.0.4")
    #expect(releaseInfo.htmlURL.absoluteString == "https://github.com/resp-200/json_formatter/releases/tag/v1.0.4")
}

@Test func releaseVersionCheckerHandlesUnorderedReleaseList() throws {
    let releasesJSON = """
    [
      {"tag_name":"v1.0.2","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.2","draft":false,"prerelease":false},
      {"tag_name":"v1.0.10","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.10","draft":false,"prerelease":false},
      {"tag_name":"v1.0.4","html_url":"https://github.com/resp-200/json_formatter/releases/tag/v1.0.4","draft":false,"prerelease":false}
    ]
    """
    let data = try #require(releasesJSON.data(using: .utf8))

    let releaseInfo = try ReleaseVersionChecker.latestReleaseInfo(from: data)

    #expect(releaseInfo.tagName == "v1.0.10")
}

@Test func formatUserFeedbackJSONAfterClearingInput() throws {
    let output = try JSONFormatterService.format("{\"name\":\"test\",\"items”:[1,2,3,4,5]}")

    #expect(output.contains("  \"items\" : ["))
    #expect(output.contains("  \"name\" : \"test\""))
}

@Test func compactUserFeedbackJSONAfterClearingInput() throws {
    let output = try JSONFormatterService.compact("{\"name\":\"test\",\"items”:[1,2,3,4,5]}")

    #expect(output == "{\"items\":[1,2,3,4,5],\"name\":\"test\"}")
}

@Test func preserveSmartQuoteCharactersWhenStrictJSONIsValid() throws {
    let output = try JSONFormatterService.compact("{\"quote\":\"items”\"}")

    #expect(output == "{\"quote\":\"items”\"}")
}

@Test func throwErrorForInvalidJSON() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.format("{bad json}")
    }
}

@Test func throwErrorForInvalidJSONAfterSmartQuoteRetry() {
    #expect(throws: (any Error).self) {
        try JSONFormatterService.format("{\"name\":\"test\",\"items”:[1,2,,3]}")
    }
}

@Test func clipboardAutoFormatterFormatsValidJSON() {
    var formatter = ClipboardJSONAutoFormatter()

    let decision = formatter.decision(changeCount: 1, text: " {\"b\":2,\"a\":1} ")

    #expect(decision == .shouldFormat("{\"b\":2,\"a\":1}"))
}

@Test func clipboardAutoFormatterRejectsInvalidJSON() {
    var formatter = ClipboardJSONAutoFormatter()

    let decision = formatter.decision(changeCount: 1, text: "{bad json}")

    #expect(decision == .invalidJSON)
}

@Test func clipboardAutoFormatterDoesNotRepeatSameChangeCount() {
    var formatter = ClipboardJSONAutoFormatter()

    #expect(formatter.decision(changeCount: 1, text: "{\"a\":1}") == .shouldFormat("{\"a\":1}"))
    #expect(formatter.decision(changeCount: 1, text: "{\"a\":1}") == .duplicateChangeCount)
}

@Test func clipboardAutoFormatterIgnoresEmptyText() {
    var formatter = ClipboardJSONAutoFormatter()

    #expect(formatter.decision(changeCount: 1, text: "  \n\t  ") == .noText)
}

@Test func clipboardAutoFormatterIgnoresMissingText() {
    var formatter = ClipboardJSONAutoFormatter()

    #expect(formatter.decision(changeCount: 1, text: nil) == .noText)
}

@Test func workspacePersistenceRoundTripsDocument() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = temporaryDirectory.appendingPathComponent("workspace.json")
    let pageID = UUID()
    let selectedPageID = UUID()
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let document = JSONWorkspacePersistenceDocument(
        version: JSONWorkspacePersistence.documentVersion,
        pages: [
            JSONWorkspacePersistencePage(
                id: pageID,
                title: "接口响应",
                inputText: "{\"a\":1}",
                outputText: "{\n  \"a\" : 1\n}",
                workspaceMode: "diff",
                diffRightText: "{\"a\":2}",
                errorMessage: "",
                queryExpression: ".items",
                searchQuery: "a",
                outputDisplayMode: "tree",
                updatedAt: updatedAt
            )
        ],
        selectedPageID: selectedPageID,
        nextPageNumber: 4
    )

    try JSONWorkspacePersistence.save(document, to: fileURL)
    let restoredDocument = try #require(JSONWorkspacePersistence.loadDocument(from: fileURL))

    #expect(restoredDocument == document)
    try? FileManager.default.removeItem(at: temporaryDirectory)
}

@Test func workspacePersistenceReturnsNilForMissingDocument() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = temporaryDirectory.appendingPathComponent("workspace.json")

    let restoredDocument = try JSONWorkspacePersistence.loadDocument(from: fileURL)

    #expect(restoredDocument == nil)
}
