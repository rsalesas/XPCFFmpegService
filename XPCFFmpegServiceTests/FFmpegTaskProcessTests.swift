import XCTest
import XPCFFmpegServiceFramework

final class FFmpegTaskProcessTests: XCTestCase {

    private var stubs: [StubTask] = []

    override func tearDown() {
        stubs.forEach { $0.cleanUp() }
        stubs = []
        super.tearDown()
    }

    private func stub(_ task: StubTask) -> StubTask {
        stubs.append(task)
        return task
    }

    /// Runs a task to its single completion.
    private func run(_ task: StubTask, arguments: [String] = ["-ffprobe"],
                     gracePeriod: TimeInterval = 0.4,
                     status: RecordingStatusService = RecordingStatusService(),
                     timeout: TimeInterval = 10,
                     before: ((FFmpegTaskProcess) -> Void)? = nil,
                     after: ((FFmpegTaskProcess) -> Void)? = nil) -> (ServiceResult?, Int) {
        let finished = expectation(description: "completed")
        let lock = NSLock()
        var result: ServiceResult?
        var calls = 0

        let process = FFmpegTaskProcess(statusService: status, executableURL: task.url,
                                        gracePeriod: gracePeriod) { outcome in
            lock.lock()
            calls += 1
            if calls == 1 { result = outcome; finished.fulfill() }
            lock.unlock()
        }

        before?(process)
        process.invoke(arguments: arguments)
        after?(process)

        wait(for: [finished], timeout: timeout)

        // Anything arriving late - a termination handler firing after a cancel already replied -
        // has to be swallowed, not delivered as a second result.
        Thread.sleep(forTimeInterval: gracePeriod * 3 + 0.5)

        lock.lock(); defer { lock.unlock() }
        return (result, calls)
    }

    // MARK: - Completion

    func testCleanExitWithNoOutputStillReplies() {
        // A transcode writes to a file and reports progress on stderr, so it produces no stdout
        // JSON at all. Without this the reply block was never invoked and the caller hung.
        let (result, calls) = run(stub(.make(exitCode: 0)))

        XCTAssertEqual(calls, 1)
        guard case .success(let object)? = result else { return XCTFail("expected success, got \(result as Any)") }
        XCTAssertEqual(object as? String, "Success")
    }

    func testJSONOnStandardOutputIsParsedAndReturned() {
        let (result, calls) = run(stub(.make(standardOutput: #"{"format":{"duration":"0:00:10.000000"}}"#)))

        XCTAssertEqual(calls, 1)
        guard case .success(let object)? = result else { return XCTFail("expected success") }
        let dictionary = object as? [String : Any]
        XCTAssertNotNil(dictionary?["format"])
    }

    func testAVersionObjectIsDecodedRatherThanPassedThroughAsJSON() {
        let json = #"{"version":{"version":"n9.0.1","compiler":"clang","ffmpegCopyright":"c","configuration":"x","libraries":{}}}"#
        let (result, _) = run(stub(.make(standardOutput: json)))

        guard case .success(let object)? = result else { return XCTFail("expected success") }
        XCTAssertEqual((object as? FFmpegVersion)?.version, "n9.0.1")
    }

    func testEmptyJSONObjectIsIgnoredAndTheExitStatusDecides() {
        let (result, calls) = run(stub(.make(standardOutput: "{}")))

        XCTAssertEqual(calls, 1)
        guard case .success(let object)? = result else { return XCTFail("expected success") }
        XCTAssertEqual(object as? String, "Success")
    }

    // MARK: - Exit statuses

    func testFFmpegTaskExitCodesMapToNamedErrors() {
        for (code, expected) in [(Int32(1), ServiceError.failure),
                                 (2, .insufficientArguments),
                                 (3, .invalidArgument),
                                 (4, .unknownRequest)] {
            let (result, calls) = run(stub(.make(exitCode: code)))
            XCTAssertEqual(calls, 1, "exit \(code)")
            guard case .failure(let error)? = result else { return XCTFail("expected failure for \(code)") }
            XCTAssertEqual(error, expected)
        }
    }

    func testFFmpegsOwnHardExitDoesNotTakeTheServiceDown() {
        // ffmpeg's sigterm_handler calls exit(123) after more than three signals, bypassing
        // FFmpegTask's own exit-code mapping. This used to reach a fatalError.
        let (result, calls) = run(stub(.make(exitCode: 123)))

        XCTAssertEqual(calls, 1)
        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .hardExit)
    }

    func testAnUnrecognisedExitStatusIsNamedRatherThanFatal() {
        let (result, _) = run(stub(.make(exitCode: 42)))

        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .unexpectedExit)
    }

    func testAChildKilledBySignalReportsUncaughtSignal() {
        let task = stub(.make(body: """
        #!/bin/sh
        kill -SEGV $$
        """))
        let (result, calls) = run(task)

        XCTAssertEqual(calls, 1)
        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .uncaughtSignal)
    }

    func testAMissingExecutableIsReportedNotTrapped() {
        let task = stub(.make())
        try? FileManager.default.removeItem(at: task.url)

        let (result, calls) = run(task)
        XCTAssertEqual(calls, 1)
        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .unableToInvoke)
    }

    // MARK: - Status forwarding

    func testProgressAndStatusOnStandardErrorAreForwarded() {
        let status = RecordingStatusService()
        let stderr = [Payload.progress(frame: 1), Payload.progress(frame: 2, finished: true),
                      Payload.status(domain: "warning", message: "deprecated")].joined(separator: "\n")

        let (result, _) = run(stub(.make(standardError: stderr)), status: status)

        guard case .success? = result else { return XCTFail("expected success") }
        XCTAssertEqual(status.progressUpdates.map { $0.frame }, [1, 2])
        XCTAssertTrue(status.progressUpdates.last!.finished)
        XCTAssertEqual(status.statuses.map { $0.message }, ["deprecated"])
    }

    func testADesynchronisedStreamEndsTheJobExactlyOnce() {
        // Bytes that are not a frame leave the reader unable to trust anything that follows, so
        // the job is abandoned. What matters here is that it still produces one reply rather than
        // trapping or replying twice.
        let (result, calls) = run(stub(.make(standardError: StubTask.raw("not a frame at all"))))

        XCTAssertEqual(calls, 1)
        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .invalidResponse)
    }

    func testABalancedButInvalidRecordIsSkippedRatherThanFatal() {
        // The stream validator only balances braces, so it can hand up a chunk that is not valid
        // JSON. Debug builds used to assert on that - on data from another process.
        let status = RecordingStatusService()
        let stderr = "{,}\n" + Payload.progress(frame: 7)

        let (result, calls) = run(stub(.make(standardError: stderr)), status: status)

        XCTAssertEqual(calls, 1)
        guard case .success? = result else { return XCTFail("expected success, got \(result as Any)") }
        XCTAssertEqual(status.progressUpdates.map { $0.frame }, [7],
                       "the good record after the bad one must still arrive")
    }

    func testUnparseableJSONOnStandardOutputEndsTheJob() {
        let (result, calls) = run(stub(.make(standardOutput: "{\"unexpected\": [1, 2, 3]}")))

        XCTAssertEqual(calls, 1, "an invalid response must still produce exactly one reply")
        XCTAssertNotNil(result)
    }

    // MARK: - Cancellation

    func testCancelRepliesOnceAndReapsTheChild() {
        let task = stub(.make(body: """
        #!/bin/sh
        while true; do sleep 0.2; done
        """))

        var pid: Int32 = 0
        let (result, calls) = run(task, gracePeriod: 0.3, after: { process in
            Thread.sleep(forTimeInterval: 0.4)
            pid = process.processIdentifier
            process.cancel()
        })

        XCTAssertEqual(calls, 1, "the termination handler must not deliver a second result")
        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .cancelled)

        XCTAssertNotEqual(pid, 0)
        XCTAssertEqual(kill(pid, 0), -1, "the child should be gone")
    }

    func testCancelEscalatesToSIGKILLWhenSIGTERMIsIgnored() {
        // ffmpeg's own handler exits(123) on the fourth signal; we stop short of that and kill.
        let task = stub(.unkillable())

        var pid: Int32 = 0
        let (result, calls) = run(task, gracePeriod: 0.3, timeout: 15, after: { process in
            Thread.sleep(forTimeInterval: 0.5)
            pid = process.processIdentifier
            process.cancel()
        })

        XCTAssertEqual(calls, 1)
        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .cancelled)
        XCTAssertEqual(kill(pid, 0), -1, "escalation should have reached SIGKILL")
    }

    func testRepeatedCancelsAreHarmless() {
        let task = stub(.make(body: """
        #!/bin/sh
        while true; do sleep 0.2; done
        """))

        let (_, calls) = run(task, gracePeriod: 0.3, after: { process in
            Thread.sleep(forTimeInterval: 0.4)
            process.cancel()
            process.cancel()
            process.cancel()
        })

        XCTAssertEqual(calls, 1)
    }

    func testCancelBeforeLaunchNeverStartsTheChild() {
        let record = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let task = stub(.recordingArguments(to: record))

        let (result, calls) = run(task, gracePeriod: 0.2, before: { $0.cancel() })

        XCTAssertEqual(calls, 1)
        guard case .failure(let error)? = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path),
                       "the child must not have run at all")
    }

    // MARK: - Arguments

    func testArgumentsReachTheChildUnaltered() {
        let record = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let task = stub(.recordingArguments(to: record))

        _ = run(task, arguments: ["-ffmpeg", "-y", "-i", "/tmp/in.mov", "/tmp/out.mp4"])

        let written = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
        XCTAssertEqual(written.split(separator: "\n").map(String.init),
                       ["-ffmpeg", "-y", "-i", "/tmp/in.mov", "/tmp/out.mp4"])
    }

    func testTheBundledTaskSitsBesideTheServiceExecutable() {
        // Production never passes an executable URL, so the default has to be right.
        let expected = URL(fileURLWithPath: Bundle.main.executablePath!)
            .deletingLastPathComponent()
            .appendingPathComponent("FFmpegTask")
        XCTAssertEqual(FFmpegTaskProcess.bundledTaskURL(), expected)
    }
}
