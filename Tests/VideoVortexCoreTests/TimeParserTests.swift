import Testing
@testable import VideoVortexCore

@Suite("TimeParser")
struct TimeParserTests {

    // MARK: - Colon notation (the search → clip contract)

    @Test("Parses HH:MM:SS — the format SRTSearcher emits for vvx clip")
    func parseHHMMSS() {
        #expect(TimeParser.parseToSeconds("00:14:32") == 872.0)
        #expect(TimeParser.parseToSeconds("01:00:00") == 3600.0)
        #expect(TimeParser.parseToSeconds("00:00:00") == 0.0)
    }

    @Test("Parses HH:MM:SS with milliseconds")
    func parseHHMMSSMillis() {
        let result = TimeParser.parseToSeconds("00:14:32.500")
        #expect(result == 872.5)
    }

    @Test("Parses MM:SS shorthand")
    func parseMMSS() {
        #expect(TimeParser.parseToSeconds("1:30") == 90.0)
        #expect(TimeParser.parseToSeconds("14:32") == 872.0)
        #expect(TimeParser.parseToSeconds("0:05") == 5.0)
    }

    // MARK: - Raw seconds

    @Test("Parses integer seconds")
    func parseRawInteger() {
        #expect(TimeParser.parseToSeconds("90") == 90.0)
        #expect(TimeParser.parseToSeconds("0") == 0.0)
        #expect(TimeParser.parseToSeconds("3600") == 3600.0)
    }

    @Test("Parses decimal seconds")
    func parseRawDecimal() {
        #expect(TimeParser.parseToSeconds("90.5") == 90.5)
        #expect(TimeParser.parseToSeconds("0.25") == 0.25)
    }

    // MARK: - Shorthand notation

    @Test("Parses XmYs shorthand")
    func parseMinutesSeconds() {
        #expect(TimeParser.parseToSeconds("1m30s") == 90.0)
        #expect(TimeParser.parseToSeconds("14m32s") == 872.0)
    }

    @Test("Parses XhYmZs shorthand")
    func parseFullShorthand() {
        #expect(TimeParser.parseToSeconds("1h0m0s") == 3600.0)
        #expect(TimeParser.parseToSeconds("2h1m30s") == 7290.0)
    }

    @Test("Parses partial shorthand (seconds only, hours only)")
    func parsePartialShorthand() {
        #expect(TimeParser.parseToSeconds("45s") == 45.0)
        #expect(TimeParser.parseToSeconds("1h") == 3600.0)
        #expect(TimeParser.parseToSeconds("1h30s") == 3630.0)
    }

    @Test("Parses fractional seconds in shorthand")
    func parseFractionalShorthand() {
        #expect(TimeParser.parseToSeconds("1.5s") == 1.5)
    }

    // MARK: - Edge cases

    @Test("Returns nil for empty string")
    func emptyString() {
        #expect(TimeParser.parseToSeconds("") == nil)
    }

    @Test("Returns nil for garbage input")
    func garbageInput() {
        #expect(TimeParser.parseToSeconds("abc") == nil)
        #expect(TimeParser.parseToSeconds("not:a:time:at:all") == nil)
        #expect(TimeParser.parseToSeconds("--30") == nil)
    }

    @Test("Trims whitespace before parsing")
    func whitespace() {
        #expect(TimeParser.parseToSeconds("  90  ") == 90.0)
        #expect(TimeParser.parseToSeconds(" 1:30 ") == 90.0)
    }

    // MARK: - Formatting

    @Test("formatHHMMSS produces correct output")
    func formatHHMMSS() {
        #expect(TimeParser.formatHHMMSS(0) == "00:00:00")
        #expect(TimeParser.formatHHMMSS(90) == "00:01:30")
        #expect(TimeParser.formatHHMMSS(872) == "00:14:32")
        #expect(TimeParser.formatHHMMSS(3661) == "01:01:01")
    }

    @Test("formatCompact produces human-friendly file name tags")
    func formatCompact() {
        #expect(TimeParser.formatCompact(5) == "05s")
        #expect(TimeParser.formatCompact(90) == "01m30s")
        #expect(TimeParser.formatCompact(872) == "14m32s")
        #expect(TimeParser.formatCompact(3661) == "01h01m01s")
    }

    // MARK: - Round-trip: search emits → clip parses

    @Test("SRTSearcher timestamp format round-trips through TimeParser")
    func searchClipRoundTrip() {
        let searchEmitted = "00:14:32"
        let seconds = TimeParser.parseToSeconds(searchEmitted)
        #expect(seconds == 872.0)
        #expect(TimeParser.formatHHMMSS(seconds!) == "00:14:32")
    }
}
