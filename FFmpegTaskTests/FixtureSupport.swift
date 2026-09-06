import XCTest

/// Real FFmpeg output, captured from the build, one file per request verb.
///
/// These are the whole point of this suite. Hand-written samples would encode someone's reading of
/// the format and would have gone on passing while -pix_fmts and -filters parsed nothing at all.
/// Regenerate them with Scripts/ffmpeg-fixtures.sh when FFmpeg is upgraded.
enum Fixture {

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func data(_ verb: String) throws -> Data {
        return try Data(contentsOf: directory.appendingPathComponent("\(verb).txt"))
    }

    static func text(_ verb: String) throws -> String {
        return String(decoding: try data(verb), as: UTF8.self)
    }

    /// The rows FFmpeg actually listed, with its banner and legend removed.
    ///
    /// Every verb prints a preamble - a title, a key to the flag characters, sometimes a `---`
    /// rule - and none of it is data. `after` is the last line of that preamble.
    static func dataLines(_ verb: String, after separator: String? = nil,
                          droppingFirst: Int = 0) throws -> [String] {
        var lines = try text(verb).components(separatedBy: "\n")

        if let separator = separator {
            guard let index = lines.firstIndex(where: { $0.hasPrefix(separator) }) else {
                XCTFail("\(verb): no line starting with \"\(separator)\" - the preamble has changed")
                return []
            }
            lines = Array(lines[(index + 1)...])
        }

        lines = Array(lines.dropFirst(droppingFirst))
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}


extension XCTestCase {

    /// Asserts that a parser's pattern accounts for every row FFmpeg printed.
    ///
    /// This is the drift check. A regex that stops matching does not fail loudly - the handler
    /// keeps whatever still matches and silently discards the rest, so the output stays
    /// well-formed while losing rows. Counting entries is not enough either: a column added at the
    /// end of the line breaks every row at once, and a count assertion just looks like FFmpeg
    /// removed some codecs. Only line-by-line accounting distinguishes the two.
    func assertEveryRowMatches(_ pattern: String, verb: String, after separator: String? = nil,
                               droppingFirst: Int = 0,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let lines = try Fixture.dataLines(verb, after: separator, droppingFirst: droppingFirst)
        XCTAssertFalse(lines.isEmpty, "\(verb): no data rows found at all", file: file, line: line)

        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)

        let unmatched = lines.filter { row in
            regex.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)) == nil
        }

        if !unmatched.isEmpty {
            let sample = unmatched.prefix(5).map { "    |\($0)|" }.joined(separator: "\n")
            XCTFail("""
                \(verb): \(unmatched.count) of \(lines.count) rows no longer match the parser.
                FFmpeg's output format has changed. First few:
                \(sample)
                """, file: file, line: line)
        }
    }

    /// Decodes a handler's JSON back into something assertable.
    func parsed(_ json: Data?, file: StaticString = #filePath, line: UInt = #line) throws -> [String : Any] {
        let json = try XCTUnwrap(json, "the parser returned nil - it matched nothing at all",
                                 file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String : Any],
                             file: file, line: line)
    }

    /// Finds one entry in a handler's list output by the value of `key`.
    func entry(_ name: String, in json: [String : Any], list: String, key: String,
               file: StaticString = #filePath, line: UInt = #line) throws -> [String : Any] {
        let entries = try XCTUnwrap(json[list] as? [[String : Any]],
                                    "no \"\(list)\" array in the output", file: file, line: line)
        return try XCTUnwrap(entries.first { $0[key] as? String == name },
                             "\(name) is missing from \(list)", file: file, line: line)
    }
}
