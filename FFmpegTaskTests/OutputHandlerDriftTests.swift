import XCTest

/// One test per request verb, asserting that FFmpeg's current output still parses completely.
///
/// These fail the day an FFmpeg upgrade moves a column. That is the whole reason they exist: three
/// parsers had already drifted before this suite was written, and all three failed silently -
/// -pix_fmts and -filters produced nothing whatsoever, and -formats quietly dropped every device.
final class OutputHandlerDriftTests: XCTestCase {

    // MARK: - Every row still matches

    func testCodecsAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegCodecs.RegExPattern, verb: "codecs", after: " ---")
    }

    func testDecodersAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegDecoders.RegExPattern, verb: "decoders", after: " ---")
    }

    func testFormatsAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegFormats.RegExPattern, verb: "formats", after: " ---")
    }

    func testMuxersAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegFormats.RegExPattern, verb: "muxers", after: " --")
    }

    func testDemuxersAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegFormats.RegExPattern, verb: "demuxers", after: " --")
    }

    func testDevicesAccountsForEveryRow() throws {
        // -devices omits the device column, so the same pattern has to cope with a shorter field.
        try assertEveryRowMatches(FFmpegFormats.RegExPattern, verb: "devices", after: " ---")
    }

    func testPixelFormatsAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegPixelFormats.RegExPattern, verb: "pix_fmts", after: "-----")
    }

    func testFiltersAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegFilters.RegExPattern, verb: "filters", after: "  ------")
    }

    func testBitstreamFiltersAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegBitstreamFilters.RegExPattern, verb: "bsfs", droppingFirst: 1)
    }

    func testSampleFormatsAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegSampleFormats.RegExPattern, verb: "sample_fmts", droppingFirst: 1)
    }

    func testColorsAccountsForEveryRow() throws {
        try assertEveryRowMatches(FFmpegColors.RegExPattern, verb: "colors", droppingFirst: 1)
    }

    // MARK: - Parsers that never return nil

    func testNoParserSilentlyReturnsNil() throws {
        // The failure mode that started all this: a parser matches nothing, returns nil, and the
        // caller is handed an empty success.
        let parsers: [(String, (Data) -> Data?)] = [
            ("codecs",      { FFmpegCodecs(from: $0)?.JSON }),
            ("decoders",    { FFmpegDecoders(from: $0)?.JSON }),
            ("formats",     { FFmpegFormats(from: $0)?.JSON }),
            ("muxers",      { FFmpegFormats(from: $0)?.JSON }),
            ("demuxers",    { FFmpegFormats(from: $0)?.JSON }),
            ("devices",     { FFmpegFormats(from: $0)?.JSON }),
            ("protocols",   { FFmpegProtocols(from: $0)?.JSON }),
            ("bsfs",        { FFmpegBitstreamFilters(from: $0)?.JSON }),
            ("pix_fmts",    { FFmpegPixelFormats(from: $0)?.JSON }),
            ("filters",     { FFmpegFilters(from: $0)?.JSON }),
            ("sample_fmts", { FFmpegSampleFormats(from: $0)?.JSON }),
            ("colors",      { FFmpegColors(from: $0)?.JSON }),
            ("layouts",     { FFmpegLayouts(from: $0)?.JSON }),
            ("version",     { FFmpegVersion(from: $0)?.JSON }),
            ("license",     { FFmpegLicense(from: $0)?.JSON }),
        ]

        for (verb, parse) in parsers {
            let json = parse(try Fixture.data(verb))
            XCTAssertNotNil(json, "\(verb): the parser matched nothing")
            XCTAssertGreaterThan(json?.count ?? 0, 2, "\(verb): produced an empty object")
        }
    }

    /// Guards against the opposite failure: a pattern loosened until it swallows the legend too.
    func testPreamblesAreNotMistakenForData() throws {
        let cases: [(String, String)] = [
            (FFmpegCodecs.RegExPattern, " D..... = Decoding supported"),
            (FFmpegFormats.RegExPattern, " D.. = Demuxing supported"),
            (FFmpegFilters.RegExPattern, "  T.. = Timeline support"),
            (FFmpegPixelFormats.RegExPattern, "I.... = Supported Input  format for conversion"),
        ]

        for (pattern, legendLine) in cases {
            let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
            let range = NSRange(legendLine.startIndex..., in: legendLine)
            XCTAssertNil(regex.firstMatch(in: legendLine, range: range),
                         "a legend line is being parsed as data: |\(legendLine)|")
        }
    }
}
