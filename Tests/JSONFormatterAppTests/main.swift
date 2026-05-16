import Testing
@testable import JSONFormatterApp

@Test func formatObjectJSON() throws {
    let output = try JSONFormatterService.format("{\"b\":2,\"a\":1}")

    #expect(output.contains("\n"))
    #expect(output.contains("  \"a\" : 1"))
    #expect(output.contains("  \"b\" : 2"))
}

@Test func compactObjectJSON() throws {
    let output = try JSONFormatterService.compact("{\n  \"b\" : 2,\n  \"a\" : 1\n}")

    #expect(output == "{\"a\":1,\"b\":2}")
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
