import XCTest
import XPCFFmpegServiceFramework
@testable import XPCFFmpeg

/// Exercises the session's orchestration against a stand-in for the service.
final class FFmpegSessionTests: XCTestCase {

    private var transport: FakeTransport!
    private var ffmpeg: FFmpeg!
    private var sandbox: Fixture.Sandbox!

    override func setUp() {
        super.setUp()
        transport = FakeTransport()
        ffmpeg = FFmpeg(transport: transport)
        sandbox = Fixture.Sandbox()
    }

    override func tearDown() {
        ffmpeg = nil
        transport = nil
        sandbox = nil
        super.tearDown()
    }

    private static let probeJSON: [String : Any] = [
        "format": ["format_name": "mov,mp4,m4a", "duration": "0:00:40.000000"],
        "streams": [["index": 0, "codec_type": "video", "codec_name": "h264",
                     "width": 640, "height": 480, "r_frame_rate": "25/1"]]
    ]

    // MARK: - Probe

    func testProbeDecodesTheReply() async throws {
        transport.automaticReply = { _ in (FFmpegSessionTests.probeJSON, nil) }

        let info = try await ffmpeg.probe(sandbox.existingFile)
        XCTAssertEqual(info.duration!, 40, accuracy: 0.001)
        XCTAssertEqual(info.videoStreams.first?.frameSize, FrameSize(width: 640, height: 480))

        let request = transport.invocations[0].request
        XCTAssertEqual(request.request, "-ffprobe")
        XCTAssertTrue(request.arguments.contains("-show_format"))
        XCTAssertTrue(request.arguments.contains("-show_streams"))
        XCTAssertEqual(transport.invocations[0].fileHandles.count, 1)
    }

    func testProbeOptionsReachTheRequest() async throws {
        transport.automaticReply = { _ in (FFmpegSessionTests.probeJSON, nil) }

        _ = try await ffmpeg.probe(sandbox.existingFile,
                                   options: ProbeOptions(showFormat: false, showStreams: true,
                                                         showChapters: true,
                                                         additionalOptions: ["-count_frames"]))

        let arguments = transport.invocations[0].request.arguments
        XCTAssertFalse(arguments.contains("-show_format"))
        XCTAssertTrue(arguments.contains("-show_chapters"))
        XCTAssertTrue(arguments.contains("-count_frames"))
    }

    func testProbeOfAnUnreachableFileThrowsBeforeAnyInvoke() async {
        // Nothing can be bookmarked, so there is no request worth sending.
        do {
            _ = try await ffmpeg.probe(sandbox.url("nested/missing/file.mp4"))
            XCTFail("expected a throw")
        } catch FFmpegError.inaccessibleFile {
            XCTAssertTrue(transport.invocations.isEmpty)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Conversion

    func testStartConversionReturnsWithoutWaiting() throws {
        let job = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile,
                                                        to: sandbox.url("out.mp4")))
        XCTAssertEqual(transport.invocations.count, 1)
        XCTAssertEqual(transport.invocations[0].jobID, job.id)
        XCTAssertEqual(transport.invocations[0].request.request, "-ffmpeg")
    }

    func testConvertProbesTheSourceFirstSoProgressHasATotal() async throws {
        transport.automaticReply = { request -> (Any?, Error?) in
            request.request == "-ffprobe" ? (FFmpegSessionTests.probeJSON, nil) : ("Success", nil)
        }

        let destination = sandbox.url("out.mp4")
        let result = try await ffmpeg.convert(Conversion(from: sandbox.existingFile, to: destination))

        XCTAssertEqual(result, destination)
        XCTAssertEqual(transport.invocations.map { $0.request.request }, ["-ffprobe", "-ffmpeg"])
    }

    func testConvertStillRunsWhenTheSourceCannotBeProbed() async throws {
        // An unprobeable source costs a progress fraction, not the conversion.
        transport.automaticReply = { request -> (Any?, Error?) in
            request.request == "-ffprobe" ? (nil, ServiceError.failure) : ("Success", nil)
        }

        _ = try await ffmpeg.convert(Conversion(from: sandbox.existingFile, to: sandbox.url("out.mp4")))
        XCTAssertEqual(transport.invocations.map { $0.request.request }, ["-ffprobe", "-ffmpeg"])
    }

    func testConvertForwardsProgressToTheCallback() async throws {
        transport.automaticReply = nil

        let received = Expectation()
        let destination = sandbox.url("out.mp4")

        let task = Task {
            try await ffmpeg.convert(Conversion(from: sandbox.existingFile, to: destination)) { progress in
                received.fulfil(progress.frame)
            }
        }

        // First the probe, which this test answers by hand so the conversion has a known duration.
        try await waitFor { self.transport.invocations.count == 1 }
        transport.reply(to: transport.invocations[0].jobID, object: FFmpegSessionTests.probeJSON, error: nil)

        try await waitFor { self.transport.invocations.count == 2 }
        let conversionID = transport.invocations[1].jobID

        guard let (status, connection) = transport.statusProxy(for: conversionID) else {
            return XCTFail("the job exposed no status endpoint")
        }
        defer { connection.invalidate() }

        status.progress(progress: Fixture.progress(frame: 99))
        try await waitFor { received.value != nil }
        XCTAssertEqual(received.value, 99)

        transport.reply(to: conversionID, object: "Success", error: nil)
        _ = try await task.value
    }

    // MARK: - Errors

    func testServiceErrorsBecomeFFmpegErrors() async throws {
        for (serviceError, check) in [
            (ServiceError.cancelled, { (e: FFmpegError) in if case .cancelled = e { return true }; return false }),
            (ServiceError.failure, { (e: FFmpegError) in if case .failed = e { return true }; return false }),
            (ServiceError.inaccessibleFile, { (e: FFmpegError) in if case .failed = e { return true }; return false })
        ] {
            transport.automaticReply = { _ in (nil, serviceError) }
            let job = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: sandbox.url("o.mp4")))

            do {
                _ = try await job.value()
                XCTFail("expected a throw for \(serviceError)")
            } catch let error as FFmpegError {
                XCTAssertTrue(check(error), "wrong mapping for \(serviceError): \(error)")
            }
        }
    }

    func testAnErrorFromOutsideTheServiceDomainIsTreatedAsTransportFailure() async throws {
        transport.automaticReply = { _ in (nil, NSError(domain: NSCocoaErrorDomain, code: 4097)) }
        let job = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: sandbox.url("o.mp4")))

        do {
            _ = try await job.value()
            XCTFail("expected a throw")
        } catch FFmpegError.serviceUnavailable {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAConnectionFailureCompletesTheJob() async throws {
        // NSXPCConnection calls its error handler *instead of* the reply block; if that does not
        // complete the job, the caller waits forever. This is the regression that hid a hang.
        let job = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: sandbox.url("o.mp4")))
        transport.failConnection(for: job.id, error: NSError(domain: NSCocoaErrorDomain, code: 4097))

        do {
            _ = try await job.value()
            XCTFail("expected a throw")
        } catch FFmpegError.serviceUnavailable {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFailureCarriesFFmpegsOwnWords() async throws {
        let job = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: sandbox.url("o.mp4")))

        guard let (status, connection) = transport.statusProxy(for: job.id) else {
            return XCTFail("no status endpoint")
        }
        defer { connection.invalidate() }

        status.status(status: Fixture.status(domain: "info", message: "just noise"))
        status.status(status: Fixture.status(domain: "error", message: "Invalid data found"))
        try await waitFor { job.log.count == 2 }

        transport.reply(to: job.id, object: nil, error: ServiceError.failure)

        do {
            _ = try await job.value()
            XCTFail("expected a throw")
        } catch let error as FFmpegError {
            XCTAssertEqual(error.localizedDescription, "Invalid data found",
                           "the last real error beats the generic service message")
        }
    }

    // MARK: - Cancel

    func testCancelReachesTheTransportWithTheRightJob() throws {
        let first = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: sandbox.url("a.mp4")))
        let second = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: sandbox.url("b.mp4")))

        second.cancel()

        XCTAssertEqual(transport.cancelled, [second.id])
        XCTAssertFalse(transport.cancelled.contains(first.id))
    }

    // MARK: - Escape hatch

    func testAFailedConversionRemovesTheDestinationItCreated() async throws {
        // The destination is created only so it can be bookmarked; a job that never wrote to it
        // should not leave an empty file behind.
        let destination = sandbox.url("never-written.mp4")
        transport.automaticReply = { _ in (nil, ServiceError.failure) }

        let job = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: destination))
        _ = try? await job.value()

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testASuccessfulConversionKeepsItsOutput() async throws {
        let destination = sandbox.url("written.mp4")
        transport.automaticReply = { _ in ("Success", nil) }

        let job = try ffmpeg.startConversion(Conversion(from: sandbox.existingFile, to: destination))
        _ = try await job.value()

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRunSubstitutesTokensForTheFilesItIsGiven() throws {
        let job = try ffmpeg.run(request: "-ffprobe",
                                 arguments: ["-show_packets", "-i", sandbox.existingFile.path],
                                 files: [sandbox.existingFile])

        let request = transport.invocations[0].request
        XCTAssertEqual(request.request, "-ffprobe")
        XCTAssertEqual(transport.invocations[0].fileHandles.count, 1)
        XCTAssertFalse(request.arguments.contains(sandbox.existingFile.path),
                       "the raw path must be replaced by a token")
        XCTAssertTrue(request.arguments.contains { $0.hasPrefix(FFmpegRequest.tokenPrefix) })
        XCTAssertTrue(request.arguments.contains("-show_packets"))
        XCTAssertFalse(job.id.isEmpty)
    }

    func testRunWithNoFilesSendsArgumentsUntouched() throws {
        _ = try ffmpeg.run(request: "-codecs", arguments: [])

        XCTAssertEqual(transport.invocations[0].request.request, "-codecs")
        XCTAssertTrue(transport.invocations[0].fileHandles.isEmpty)
    }

    func testRunRejectsAFileItCannotBookmark() {
        XCTAssertThrowsError(try ffmpeg.run(request: "-ffprobe", arguments: [],
                                            files: [sandbox.url("nested/missing/x.mp4")])) { error in
            guard case FFmpegError.inaccessibleFile = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - Version

    func testVersionUnwrapsTheReply() async throws {
        let version = try JSONDecoder().decode(FFmpegVersion.self, from: Data(#"""
        {"version":"n9.0.1","compiler":"clang","ffmpegCopyright":"(c) the FFmpeg developers",
         "configuration":"--enable-gpl","libraries":{"libavcodec":"62.11.100"}}
        """#.utf8))

        transport.automaticReply = { _ in (version, nil) }

        let result = try await ffmpeg.version()
        XCTAssertEqual(result.version, "n9.0.1")
        XCTAssertEqual(transport.invocations[0].request.request, "-version")
    }

    func testVersionRejectsAReplyOfTheWrongShape() async {
        transport.automaticReply = { _ in ("just a string", nil) }

        do {
            _ = try await ffmpeg.version()
            XCTFail("expected a throw")
        } catch FFmpegError.unexpectedResponse {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Lifetime

    func testTheConnectionIsTornDownWithTheSession() {
        let transport = FakeTransport()
        do { _ = FFmpeg(transport: transport) }
        XCTAssertTrue(transport.didInvalidate)
    }

    // MARK: - Helpers

    /// A tiny thread-safe box, since callbacks arrive off the test's thread.
    final class Expectation {
        private let lock = NSLock()
        private var _value: Int?
        var value: Int? { lock.lock(); defer { lock.unlock() }; return _value }
        func fulfil(_ v: Int) { lock.lock(); _value = v; lock.unlock() }
    }

    private func waitFor(timeout: TimeInterval = 5,
                         _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for condition"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
