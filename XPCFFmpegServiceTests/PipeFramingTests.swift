import XCTest

final class PipeFramingTests: XCTestCase {

    private func drain(_ reader: inout FrameReader, _ chunks: [Data]) throws -> [String] {
        var out: [String] = []
        for chunk in chunks {
            reader.append(chunk)
            out += try reader.drain().map { String(decoding: $0, as: UTF8.self) }
        }
        return out
    }

    func testRoundTrip() throws {
        var reader = FrameReader()
        let framed = try XCTUnwrap(PipeFraming.frame(Data("hello".utf8)))

        XCTAssertEqual(try drain(&reader, [framed]), ["hello"])
        XCTAssertEqual(reader.pending, 0)
    }

    func testSeveralRecordsInOneChunk() throws {
        // A pipe coalesces writes, so this is the common case for fast producers.
        var reader = FrameReader()
        var chunk = Data()
        for text in ["one", "two", "three"] {
            chunk.append(try XCTUnwrap(PipeFraming.frame(Data(text.utf8))))
        }

        XCTAssertEqual(try drain(&reader, [chunk]), ["one", "two", "three"])
    }

    func testARecordSplitAcrossReads() throws {
        // The old brace scanner existed to cope with this; the reader has to as well.
        var reader = FrameReader()
        let framed = try XCTUnwrap(PipeFraming.frame(Data("a record split in half".utf8)))

        let first = framed.prefix(9)
        let second = framed.dropFirst(9)

        var out = try drain(&reader, [first])
        XCTAssertTrue(out.isEmpty, "a partial record must not be delivered")
        XCTAssertGreaterThan(reader.pending, 0)

        out = try drain(&reader, [second])
        XCTAssertEqual(out, ["a record split in half"])
        XCTAssertEqual(reader.pending, 0)
    }

    func testAHeaderSplitAcrossReads() throws {
        // The nastiest split: the length itself arrives in pieces.
        var reader = FrameReader()
        let framed = try XCTUnwrap(PipeFraming.frame(Data("x".utf8)))

        XCTAssertTrue(try drain(&reader, [framed.prefix(1)]).isEmpty)
        XCTAssertTrue(try drain(&reader, [framed.dropFirst(1).prefix(2)]).isEmpty)
        XCTAssertEqual(try drain(&reader, [framed.dropFirst(3)]), ["x"])
    }

    func testOneByteAtATime() throws {
        var reader = FrameReader()
        var stream = Data()
        for text in ["alpha", "beta"] {
            stream.append(try XCTUnwrap(PipeFraming.frame(Data(text.utf8))))
        }

        let out = try drain(&reader, stream.map { Data([$0]) })
        XCTAssertEqual(out, ["alpha", "beta"])
    }

    func testPayloadsAreOpaqueBytes() throws {
        // Framing says nothing about the content, which is the point of moving off brace counting.
        var reader = FrameReader()
        let awkward = "{unbalanced [ \"quotes\\\\ \u{0}\u{1}\u{2} braces}}}"
        let framed = try XCTUnwrap(PipeFraming.frame(Data(awkward.utf8)))

        XCTAssertEqual(try drain(&reader, [framed]), [awkward])
    }

    func testLargePayload() throws {
        // ffprobe on a big file, or -codecs, run to hundreds of kilobytes.
        var reader = FrameReader()
        let big = String(repeating: "x", count: 500_000)
        let framed = try XCTUnwrap(PipeFraming.frame(Data(big.utf8)))

        XCTAssertEqual(try drain(&reader, [framed]).first?.count, 500_000)
    }

    func testEmptyPayloadIsNotFramed() {
        XCTAssertNil(PipeFraming.frame(Data()), "there is nothing to deliver")
    }

    func testAbsurdLengthIsRejectedRatherThanAllocated() {
        var reader = FrameReader()
        reader.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        XCTAssertThrowsError(try reader.drain()) { error in
            guard case FrameReader.Failure.desynchronised = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testZeroLengthIsRejected() {
        var reader = FrameReader()
        reader.append(Data([0, 0, 0, 0]))

        XCTAssertThrowsError(try reader.drain())
    }

    func testUnframedBytesAreRejected() {
        // What a stray write to the pipe looks like. Text starting with "{" gives a length of
        // 0x7B22... - far past the cap - so the stream is caught rather than mis-read.
        var reader = FrameReader()
        reader.append(Data(#"{"progress":{"frame":1}}"#.utf8))

        XCTAssertThrowsError(try reader.drain())
    }

    func testRecordsSurviveInterleavedProducers() throws {
        // stderr carries status and progress from two connectors. They are written whole under a
        // lock, so the reader sees complete records in some order - never a torn one.
        var reader = FrameReader()
        var stream = Data()
        for index in 0..<50 {
            let text = index.isMultiple(of: 2) ? "progress-\(index)" : "status-\(index)"
            stream.append(try XCTUnwrap(PipeFraming.frame(Data(text.utf8))))
        }

        let out = try drain(&reader, [stream])
        XCTAssertEqual(out.count, 50)
        XCTAssertEqual(out.first, "progress-0")
        XCTAssertEqual(out.last, "status-49")
    }
}
