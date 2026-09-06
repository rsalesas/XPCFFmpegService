import XCTest
import XPCFFmpegServiceFramework

final class XPCFFmpegInvokeServiceTests: XCTestCase {

    private var stubs: [StubTask] = []
    private var hosts: [StatusEndpointHost] = []
    private var directory: URL!
    private var existingFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        existingFile = directory.appendingPathComponent("in.mov")
        try Data("not really a movie".utf8).write(to: existingFile)
    }

    override func tearDown() {
        stubs.forEach { $0.cleanUp() }
        hosts.forEach { $0.invalidate() }
        stubs = []
        hosts = []
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func stub(_ task: StubTask) -> StubTask { stubs.append(task); return task }

    private func host() -> StatusEndpointHost {
        let host = StatusEndpointHost()
        hosts.append(host)
        return host
    }

    /// Runs one job through the service, returning its single reply.
    @discardableResult
    private func invoke(_ request: FFmpegRequest, task: StubTask,
                        tokens: [String] = [], handles: [FileHandle] = [],
                        gracePeriod: TimeInterval = 0.3, jobID: String = UUID().uuidString,
                        timeout: TimeInterval = 15,
                        statusHost: StatusEndpointHost? = nil,
                        after: ((XPCFFmpegInvokeService, String) -> Void)? = nil)
                        -> (object: Any?, error: Error?, calls: Int) {
        let service = XPCFFmpegInvokeService(taskExecutableURL: task.url, gracePeriod: gracePeriod)
        let endpointHost = statusHost ?? host()

        let replied = expectation(description: "replied")
        let lock = NSLock()
        var object: Any?
        var error: Error?
        var calls = 0

        service.invoke(jobID: jobID, endpoint: endpointHost.endpoint, request: request,
                       fileTokens: tokens, fileHandles: handles) { o, e in
            lock.lock()
            calls += 1
            if calls == 1 { object = o; error = e; replied.fulfill() }
            lock.unlock()
        }

        after?(service, jobID)
        wait(for: [replied], timeout: timeout)
        Thread.sleep(forTimeInterval: gracePeriod * 3 + 0.5)

        lock.lock(); defer { lock.unlock() }
        return (object, error, calls)
    }

    private func request(arguments: [String], verb: String = "-ffprobe") -> FFmpegRequest {
        return FFmpegRequest(request: verb, arguments: arguments)
    }

    /// A token and the open descriptor it stands for, as the client would supply them.
    private func granted(_ url: URL, forWriting: Bool = false) throws -> (String, FileHandle) {
        let token = FFmpegRequest.token()
        if forWriting {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            return (token, FileHandle(fileDescriptor: fd, closeOnDealloc: true))
        }
        return (token, try FileHandle(forReadingFrom: url))
    }

    // MARK: - Happy path

    func testAJobRunsAndReplies() throws {
        let task = stub(.make(standardOutput: #"{"format":{"format_name":"mov"}}"#))
        let (token, handle) = try granted(existingFile)

        let result = invoke(request(arguments: ["-fd", token, "-i", "fd:"]), task: task,
                            tokens: [token], handles: [handle])

        XCTAssertEqual(result.calls, 1)
        XCTAssertNil(result.error)
        XCTAssertNotNil((result.object as? [String : Any])?["format"])
    }

    func testTokensBecomeTheDescriptorNumbersTheChildSees() throws {
        let record = directory.appendingPathComponent("argv")
        let task = stub(.recordingArguments(to: record))
        let (token, handle) = try granted(existingFile)

        invoke(request(arguments: ["-show_format", "-fd", token, "-i", "fd:"]), task: task,
               tokens: [token], handles: [handle])

        let argv = ((try? String(contentsOf: record, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)

        XCTAssertEqual(argv.first, "-ffprobe", "the verb leads the argument vector")
        XCTAssertEqual(argv, ["-ffprobe", "-show_format", "-fd",
                              String(ChildProcess.firstMappedDescriptor), "-i", "fd:"])
        XCTAssertFalse(argv.contains(where: { $0.hasPrefix(FFmpegRequest.tokenPrefix) }))
        XCTAssertFalse(argv.contains(existingFile.path), "no path should reach the child")
    }

    func testEachFileGetsItsOwnDescriptorNumber() throws {
        let second = directory.appendingPathComponent("in2.mov")
        try Data("second".utf8).write(to: second)
        let output = directory.appendingPathComponent("out.mp4")

        let record = directory.appendingPathComponent("argv")
        let task = stub(.recordingArguments(to: record))

        let (t1, h1) = try granted(existingFile)
        let (t2, h2) = try granted(second)
        let (t3, h3) = try granted(output, forWriting: true)

        invoke(request(arguments: ["-fd", t1, "-i", "fd:", "-fd", t2, "-i", "fd:", "-fd", t3, "fd:"],
                       verb: "-ffmpeg"),
               task: task, tokens: [t1, t2, t3], handles: [h1, h2, h3])

        let argv = ((try? String(contentsOf: record, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let base = ChildProcess.firstMappedDescriptor

        XCTAssertEqual(argv, ["-ffmpeg",
                              "-fd", String(base), "-i", "fd:",
                              "-fd", String(base + 1), "-i", "fd:",
                              "-fd", String(base + 2), "fd:"])
    }

    func testTheChildCanActuallyReadThroughTheDescriptor() throws {
        // The point of the whole design: the descriptor the client opened is usable in a
        // grandchild process, two hops away.
        let record = directory.appendingPathComponent("readback")
        let task = stub(.make(body: """
        #!/bin/sh
        head -c 6 <&\(ChildProcess.firstMappedDescriptor) > "\(record.path)" 2>/dev/null
        exit 0
        """))
        let (token, handle) = try granted(existingFile)

        invoke(request(arguments: ["-fd", token, "-i", "fd:"]), task: task,
               tokens: [token], handles: [handle])

        let read = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
        XCTAssertEqual(read, "not re", "the child read the file through the inherited descriptor")
    }

    func testProgressReachesTheCallersEndpoint() throws {
        let stderr = [Payload.progress(frame: 3), Payload.status(domain: "warning", message: "hm")]
            .joined(separator: "\n")
        let task = stub(.make(standardError: stderr))
        let (token, handle) = try granted(existingFile)
        let endpointHost = host()

        invoke(request(arguments: ["-fd", token, "-i", "fd:"]), task: task,
               tokens: [token], handles: [handle], statusHost: endpointHost)

        let deadline = Date().addingTimeInterval(5)
        while endpointHost.progressUpdates.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertEqual(endpointHost.progressUpdates.map { $0.frame }, [3])
        XCTAssertEqual(endpointHost.statuses.map { $0.message }, ["hm"])
    }

    // MARK: - Bad requests

    func testMismatchedTokenAndHandleCountsAreRejected() {
        let task = stub(.make())
        let result = invoke(request(arguments: []), task: task,
                            tokens: [FFmpegRequest.token()], handles: [])

        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.error as? ServiceError, .inaccessibleFile)
    }

    func testATokenWithNoMatchingDescriptorIsRejected() {
        let task = stub(.make())
        let result = invoke(request(arguments: ["-fd", FFmpegRequest.token(), "-i", "fd:"]), task: task)

        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.error as? ServiceError, .inaccessibleFile)
    }

    func testAFailingChildIsReportedToTheCaller() throws {
        let task = stub(.make(exitCode: 1))
        let (token, handle) = try granted(existingFile)

        let result = invoke(request(arguments: ["-fd", token, "-i", "fd:"]), task: task,
                            tokens: [token], handles: [handle])

        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.error as? ServiceError, .failure)
        XCTAssertNil(result.object)
    }

    // MARK: - Cancellation

    func testCancelStopsTheJobAndRepliesOnce() throws {
        let task = stub(.make(body: """
        #!/bin/sh
        while true; do sleep 0.2; done
        """))
        let (token, handle) = try granted(existingFile)

        let result = invoke(request(arguments: ["-fd", token, "-i", "fd:"]), task: task,
                            tokens: [token], handles: [handle],
                            after: { service, jobID in
            Thread.sleep(forTimeInterval: 0.5)
            service.cancel(jobID: jobID)
        })

        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.error as? ServiceError, .cancelled)
    }

    func testCancellingAnUnknownJobIsIgnored() throws {
        let task = stub(.make())
        let (token, handle) = try granted(existingFile)

        // A cancel racing a natural completion is normal, and must not disturb the job that ran.
        let result = invoke(request(arguments: ["-fd", token, "-i", "fd:"]), task: task,
                            tokens: [token], handles: [handle],
                            after: { service, _ in service.cancel(jobID: "no-such-job") })

        XCTAssertEqual(result.calls, 1)
        XCTAssertNil(result.error)
    }

    func testCancelAfterCompletionIsIgnored() throws {
        let task = stub(.make())
        let (token, handle) = try granted(existingFile)

        let service = XPCFFmpegInvokeService(taskExecutableURL: task.url, gracePeriod: 0.3)
        let replied = expectation(description: "replied")
        let jobID = UUID().uuidString

        service.invoke(jobID: jobID, endpoint: host().endpoint,
                       request: request(arguments: ["-fd", token, "-i", "fd:"]),
                       fileTokens: [token], fileHandles: [handle]) { _, _ in
            replied.fulfill()
        }

        wait(for: [replied], timeout: 15)
        service.cancel(jobID: jobID)   // the registry has already forgotten it
    }

    // MARK: - Concurrency

    func testConcurrentJobsDoNotInterfere() throws {
        let task = stub(.make(standardOutput: #"{"format":{"format_name":"mov"}}"#))
        let service = XPCFFmpegInvokeService(taskExecutableURL: task.url, gracePeriod: 0.3)

        let expectations = (0..<6).map { expectation(description: "job \($0)") }
        let lock = NSLock()
        var replies = 0

        for index in 0..<6 {
            let (token, handle) = try granted(existingFile)
            service.invoke(jobID: UUID().uuidString, endpoint: host().endpoint,
                           request: request(arguments: ["-fd", token, "-i", "fd:"]),
                           fileTokens: [token], fileHandles: [handle]) { object, error in
                lock.lock(); replies += 1; lock.unlock()
                XCTAssertNil(error)
                XCTAssertNotNil(object)
                expectations[index].fulfill()
            }
        }

        wait(for: expectations, timeout: 30)
        Thread.sleep(forTimeInterval: 1)

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(replies, 6, "each job replies exactly once")
    }

    func testTheServiceDefaultsToTheEmbeddedTask() {
        // The production initialiser takes no arguments and must still stand up.
        _ = XPCFFmpegInvokeService()
    }
}
