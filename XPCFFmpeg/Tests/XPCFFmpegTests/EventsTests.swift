import XCTest
@testable import XPCFFmpeg

final class EventsTests: XCTestCase {

    func testProgressMapping() {
        let progress = Progress(Fixture.progress(frame: 240, fps: 29.97, quality: -1.5,
                                                 bitrate: 1536.5, totalSize: 8192, outTime: 10,
                                                 duplicateFrames: 1, droppedFrames: 2, speed: 4,
                                                 finished: true),
                                totalDuration: nil)

        XCTAssertEqual(progress.frame, 240)
        XCTAssertEqual(progress.framesPerSecond, 29.97)
        XCTAssertEqual(progress.quality, -1.5)
        // ffmpeg reports bitrate in kbit/s.
        XCTAssertEqual(progress.bitrate, Bitrate(bitsPerSecond: 1_536_500))
        XCTAssertEqual(progress.bytesWritten, 8192)
        XCTAssertEqual(progress.encodedDuration, 10)
        XCTAssertEqual(progress.duplicateFrames, 1)
        XCTAssertEqual(progress.droppedFrames, 2)
        XCTAssertEqual(progress.speed, 4)
        XCTAssertTrue(progress.isFinished)
    }

    func testAbsentOptionalsStayAbsent() {
        let progress = Progress(Fixture.progress(bitrate: nil, totalSize: nil, outTime: nil, speed: nil),
                                totalDuration: 100)

        XCTAssertNil(progress.bitrate)
        XCTAssertNil(progress.bytesWritten)
        XCTAssertNil(progress.encodedDuration)
        XCTAssertNil(progress.speed)
        XCTAssertNil(progress.fractionCompleted, "no encoded time means no fraction")
    }

    func testFractionCompleted() {
        XCTAssertEqual(Progress(Fixture.progress(outTime: 25), totalDuration: 100).fractionCompleted!,
                       0.25, accuracy: 0.0001)

        // A fraction is only meaningful when the total is known; anything else would be a guess.
        XCTAssertNil(Progress(Fixture.progress(outTime: 25), totalDuration: nil).fractionCompleted)
        XCTAssertNil(Progress(Fixture.progress(outTime: 25), totalDuration: 0).fractionCompleted)
        XCTAssertNil(Progress(Fixture.progress(outTime: 25), totalDuration: -5).fractionCompleted)
    }

    func testFractionIsClamped() {
        // ffmpeg can report past the nominal duration, and a progress bar should not overrun.
        XCTAssertEqual(Progress(Fixture.progress(outTime: 120), totalDuration: 100).fractionCompleted, 1)
        XCTAssertEqual(Progress(Fixture.progress(outTime: -3), totalDuration: 100).fractionCompleted, 0)
    }

    func testProgressDescriptionIsReadable() {
        let text = Progress(Fixture.progress(frame: 42, fps: 24), totalDuration: nil).description
        XCTAssertFalse(text.contains("0x"), "must not fall back to an object address")
        XCTAssertTrue(text.contains("42"))
    }

    func testProgressDescriptionIncludesEverythingItKnows() {
        let text = Progress(Fixture.progress(frame: 42, fps: 24, bitrate: 800,
                                             outTime: 50, droppedFrames: 3, finished: true),
                            totalDuration: 100).description

        XCTAssertTrue(text.contains("50%"), text)
        XCTAssertTrue(text.contains("3 dropped"), text)
        XCTAssertTrue(text.contains("finished"), text)
        XCTAssertTrue(text.contains("800.0 kbits/s"), text)
    }

    func testProgressDescriptionOmitsWhatItDoesNotKnow() {
        let text = Progress(Fixture.progress(bitrate: nil, totalSize: nil, outTime: nil,
                                             droppedFrames: 0, finished: false),
                            totalDuration: nil).description

        XCTAssertFalse(text.contains("%"), text)
        XCTAssertFalse(text.contains("dropped"), text)
        XCTAssertFalse(text.contains("finished"), text)
        XCTAssertFalse(text.contains("kbits"), text)
    }

    func testLogMessageLevels() {
        for (domain, level) in [("panic", LogMessage.Level.panic), ("fatal", .fatal),
                                ("error", .error), ("warning", .warning), ("info", .info),
                                ("verbose", .verbose), ("debug", .debug), ("trace", .trace),
                                ("quiet", .quiet)] {
            XCTAssertEqual(LogMessage(Fixture.status(domain: domain)).level, level)
        }

        // FFmpegStatus.Domain has a case this side does not name, plus its own misspelled unknown.
        XCTAssertEqual(LogMessage(Fixture.status(domain: "os_log")).level, .unknown)
        XCTAssertEqual(LogMessage(Fixture.status(domain: "unkown")).level, .unknown)
    }

    func testIsErrorOnlyForRealFailures() {
        XCTAssertTrue(LogMessage(Fixture.status(domain: "panic")).isError)
        XCTAssertTrue(LogMessage(Fixture.status(domain: "fatal")).isError)
        XCTAssertTrue(LogMessage(Fixture.status(domain: "error")).isError)

        for benign in ["warning", "info", "verbose", "debug", "trace", "quiet", "unkown"] {
            XCTAssertFalse(LogMessage(Fixture.status(domain: benign)).isError, "\(benign)")
        }
    }

    func testLogMessageCarriesText() {
        let message = LogMessage(Fixture.status(domain: "error", message: "No such file or directory"))
        XCTAssertEqual(message.message, "No such file or directory")
    }
}
