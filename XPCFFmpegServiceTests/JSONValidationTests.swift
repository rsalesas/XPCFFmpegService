import XCTest

/// `isEmptyJSON` decides whether a record from FFmpegTask carries an answer. Getting it wrong is
/// silent in both directions: a record wrongly called empty is discarded and the caller is told
/// the job merely succeeded, and one wrongly called non-empty is handed back as a result.
final class JSONValidationTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testEmptyContainersAreEmpty() {
        XCTAssertTrue(data("{}").isEmptyJSON)
        XCTAssertTrue(data("[]").isEmptyJSON)
        XCTAssertTrue(data("{ }").isEmptyJSON)
        XCTAssertTrue(data("{\n  \n}").isEmptyJSON)
    }

    /// The regression. The old implementation kept only braces and checked the first two were
    /// "{}", so any flat object whose values contained no braces of their own read as empty -
    /// which is exactly what -license produces, and what made it return nothing at all.
    func testAFlatObjectWithNoBracesInItIsNotEmpty() {
        XCTAssertFalse(data(#"{"license": "GNU General Public License, version 3"}"#).isEmptyJSON)
        XCTAssertFalse(data(#"{"a": "b"}"#).isEmptyJSON)
        XCTAssertFalse(data(#"{"name": "yuv420p", "depth": 8}"#).isEmptyJSON)
    }

    func testNestedAndListRecordsAreNotEmpty() {
        XCTAssertFalse(data(#"{"codecs": [{"format": "h264"}]}"#).isEmptyJSON)
        XCTAssertFalse(data(#"["a", "b"]"#).isEmptyJSON)
    }

    func testNonJSONIsNotEmpty() {
        XCTAssertFalse(data("").isEmptyJSON)
        XCTAssertFalse(data("Success").isEmptyJSON)
    }

    func testValidityIsSeparateFromEmptiness() {
        XCTAssertTrue(data("{}").isValidJSON)
        XCTAssertTrue(data(#"{"a": 1}"#).isValidJSON)
        XCTAssertFalse(data("{").isValidJSON)
        XCTAssertFalse(data("not json").isValidJSON)
    }
}
