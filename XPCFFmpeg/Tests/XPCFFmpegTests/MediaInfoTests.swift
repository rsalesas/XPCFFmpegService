import XCTest
@testable import XPCFFmpeg

final class MediaInfoTests: XCTestCase {

    private func info(_ json: [String : Any]) throws -> MediaInfo {
        return try MediaInfo(response: json, log: [])
    }

    func testFormatAndStreams() throws {
        let media = try info([
            "format": ["format_name": "mov,mp4,m4a", "format_long_name": "QuickTime / MOV",
                       "duration": "0:00:40.000000", "size": "1015090", "bit_rate": "203018",
                       "tags": ["title": "Clip", "track": 3]],
            "streams": [
                ["index": 0, "codec_type": "video", "codec_name": "h264",
                 "codec_long_name": "H.264", "width": 640, "height": 480,
                 "r_frame_rate": "30000/1001", "duration": "0:00:40.000000", "bit_rate": "200000"],
                ["index": 1, "codec_type": "audio", "codec_name": "aac",
                 "sample_rate": "48000", "channels": 2]
            ]
        ])

        XCTAssertEqual(media.format?.formatName, "mov,mp4,m4a")
        XCTAssertEqual(media.format?.formatLongName, "QuickTime / MOV")
        XCTAssertEqual(media.format?.size, 1_015_090)
        XCTAssertEqual(media.format?.bitrate, Bitrate(bitsPerSecond: 203_018))
        XCTAssertEqual(media.format?.tags["title"], "Clip")
        // A numeric tag still arrives as a string, because tags are string-valued by contract.
        XCTAssertEqual(media.format?.tags["track"], "3")

        XCTAssertEqual(media.streams.count, 2)
        XCTAssertEqual(media.videoStreams.count, 1)
        XCTAssertEqual(media.audioStreams.count, 1)

        let video = media.videoStreams[0]
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.codecName, "h264")
        XCTAssertEqual(video.codecLongName, "H.264")
        XCTAssertEqual(video.frameSize, FrameSize(width: 640, height: 480))
        XCTAssertEqual(video.frameRate!, 29.97, accuracy: 0.01)
        XCTAssertEqual(video.bitrate, Bitrate(bitsPerSecond: 200_000))

        let audio = media.audioStreams[0]
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertNil(audio.frameSize)
    }

    // FFmpegTask runs ffprobe with -sexagesimal, so this is the form durations actually arrive in.
    func testSexagesimalDurations() throws {
        let cases: [(String, TimeInterval)] = [
            ("0:00:40.000000", 40),
            ("1:02:03.500000", 3723.5),
            ("12:30.250000", 750.25),
            ("9.5", 9.5)
        ]

        for (text, expected) in cases {
            let media = try info(["format": ["format_name": "x", "duration": text]])
            XCTAssertEqual(media.duration!, expected, accuracy: 0.001, "parsing \(text)")
        }
    }

    func testNumericDurationAlsoAccepted() throws {
        // -sexagesimal can be turned off through the escape hatch, so both forms must work.
        let media = try info(["format": ["format_name": "x", "duration": 12.75]])
        XCTAssertEqual(media.duration!, 12.75, accuracy: 0.001)
    }

    func testMalformedDurationIsNilRatherThanWrong() throws {
        for bad in ["not a time", "1:2:3:4", "", "a:b"] {
            let media = try info(["format": ["format_name": "x", "duration": bad]])
            XCTAssertNil(media.format?.duration, "should not have parsed \(bad)")
        }
    }

    func testDurationFallsBackToLongestStream() throws {
        // Some containers genuinely do not declare one.
        let media = try info([
            "format": ["format_name": "matroska"],
            "streams": [["index": 0, "codec_type": "video", "duration": "0:00:10.000000"],
                        ["index": 1, "codec_type": "audio", "duration": "0:00:12.000000"]]
        ])

        XCTAssertNil(media.format?.duration)
        XCTAssertEqual(media.duration!, 12, accuracy: 0.001)
    }

    func testFrameRateForms() throws {
        let media = try info(["streams": [
            ["index": 0, "codec_type": "video", "r_frame_rate": "25/1"],
            ["index": 1, "codec_type": "video", "r_frame_rate": "30"],
            ["index": 2, "codec_type": "video", "r_frame_rate": "0/0"],
            ["index": 3, "codec_type": "video", "r_frame_rate": "nonsense"],
            ["index": 4, "codec_type": "video"]
        ]])

        XCTAssertEqual(media.streams[0].frameRate, 25)
        XCTAssertEqual(media.streams[1].frameRate, 30)
        XCTAssertNil(media.streams[2].frameRate, "a zero denominator must not divide")
        XCTAssertNil(media.streams[3].frameRate)
        XCTAssertNil(media.streams[4].frameRate)
    }

    func testStreamKinds() throws {
        let media = try info(["streams": [
            ["index": 0, "codec_type": "video"], ["index": 1, "codec_type": "audio"],
            ["index": 2, "codec_type": "subtitle"], ["index": 3, "codec_type": "data"],
            ["index": 4, "codec_type": "attachment"], ["index": 5, "codec_type": "something new"],
            ["index": 6]
        ]])

        XCTAssertEqual(media.streams.map { $0.kind },
                       [.video, .audio, .subtitle, .data, .attachment, .unknown, .unknown])
    }

    func testDecodesFromRawData() throws {
        let json = #"{"format":{"format_name":"wav","duration":"0:00:01.000000"}}"#
        let media = try MediaInfo(response: Data(json.utf8), log: [])
        XCTAssertEqual(media.format?.formatName, "wav")
    }

    func testRejectsResponsesThatAreNotProbeOutput() {
        for response in [nil, "a string" as Any?, 42 as Any?, Data("not json".utf8) as Any?] {
            XCTAssertThrowsError(try MediaInfo(response: response, log: [])) { error in
                guard case FFmpegError.unexpectedResponse = error else {
                    return XCTFail("expected unexpectedResponse, got \(error)")
                }
            }
        }
    }

    func testRejectsJSONWithNeitherFormatNorStreams() {
        XCTAssertThrowsError(try MediaInfo(response: ["programs": []], log: [])) { error in
            guard case FFmpegError.unexpectedResponse = error else {
                return XCTFail("expected unexpectedResponse, got \(error)")
            }
        }
    }

    func testStreamsOnlyIsAcceptable() throws {
        let media = try info(["streams": [["index": 0, "codec_type": "video"]]])
        XCTAssertNil(media.format)
        XCTAssertEqual(media.streams.count, 1)
    }

    func testMissingTagsBecomeEmpty() throws {
        let media = try info(["format": ["format_name": "x"], "streams": [["index": 0, "codec_type": "video"]]])
        XCTAssertTrue(media.format!.tags.isEmpty)
        XCTAssertTrue(media.streams[0].tags.isEmpty)
    }
}
