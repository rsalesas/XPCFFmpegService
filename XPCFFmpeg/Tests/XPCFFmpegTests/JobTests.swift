import XCTest
import XPCFFmpegServiceFramework
@testable import XPCFFmpeg

final class JobTests: XCTestCase {

    private func makeJob(totalDuration: TimeInterval? = nil,
                         onCancel: @escaping (String) -> Void = { _ in })
                         -> (Job, JobStatusListener) {
        let listener = JobStatusListener(totalDuration: totalDuration)
        let job = Job(id: UUID().uuidString, listener: listener, cancelHandler: onCancel)
        return (job, listener)
    }

    func testValueReturnsTheCompletedObject() async throws {
        let (job, _) = makeJob()
        job.complete(with: .success("done"))

        let value = try await job.value()
        XCTAssertEqual(value as? String, "done")
    }

    func testValueThrowsTheCompletedError() async {
        let (job, _) = makeJob()
        job.complete(with: .failure(.cancelled))

        do {
            _ = try await job.value()
            XCTFail("expected a throw")
        } catch FFmpegError.cancelled {
            // as expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testWaitersRegisteredBeforeCompletionAreResumed() async throws {
        let (job, _) = makeJob()

        async let first = job.value()
        async let second = job.value()

        // Give both continuations a chance to register before the result lands.
        try await Task.sleep(nanoseconds: 50_000_000)
        job.complete(with: .success(7))

        let values = try await [first, second]
        XCTAssertEqual(values.compactMap { $0 as? Int }, [7, 7])
    }

    func testOnlyTheFirstCompletionCounts() async throws {
        let (job, _) = makeJob()

        job.complete(with: .success("first"))
        job.complete(with: .failure(.cancelled))
        job.complete(with: .success("third"))

        let value = try await job.value() as? String
        XCTAssertEqual(value, "first")
    }

    func testEventsAreDeliveredToSubscribers() async throws {
        let (job, listener) = makeJob(totalDuration: 100)

        let collected = Task { () -> [JobEvent] in
            var events: [JobEvent] = []
            for await event in job.events { events.append(event) }
            return events
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        listener.progress(progress: Fixture.progress(frame: 10, outTime: 50))
        listener.status(status: Fixture.status(domain: "warning", message: "hmm"))
        job.complete(with: .success(nil))

        let events = await collected.value
        XCTAssertEqual(events.count, 2)

        guard case .progress(let progress) = events[0] else { return XCTFail("expected progress") }
        XCTAssertEqual(progress.frame, 10)
        XCTAssertEqual(progress.fractionCompleted!, 0.5, accuracy: 0.0001)

        guard case .log(let message) = events[1] else { return XCTFail("expected a log message") }
        XCTAssertEqual(message.message, "hmm")
    }

    func testEventsStreamFinishesOnCompletion() async {
        let (job, _) = makeJob()

        let finished = Task { () -> Bool in
            for await _ in job.events {}
            return true
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        job.complete(with: .success(nil))

        let value = await finished.value
        XCTAssertTrue(value, "the stream must terminate rather than hang")
    }

    func testSubscribingAfterCompletionTerminatesImmediately() async {
        let (job, _) = makeJob()
        job.complete(with: .success(nil))

        var count = 0
        for await _ in job.events { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testMultipleConcurrentSubscribersEachSeeEveryEvent() async throws {
        let (job, listener) = makeJob()

        let a = Task { () -> Int in var n = 0; for await _ in job.events { n += 1 }; return n }
        let b = Task { () -> Int in var n = 0; for await _ in job.events { n += 1 }; return n }

        try await Task.sleep(nanoseconds: 60_000_000)
        listener.progress(progress: Fixture.progress())
        listener.progress(progress: Fixture.progress())
        job.complete(with: .success(nil))

        let counts = await [a.value, b.value]
        XCTAssertEqual(counts, [2, 2])
    }

    func testCancelIsForwardedOnce() {
        var cancelledIDs: [String] = []
        let (job, _) = makeJob(onCancel: { cancelledIDs.append($0) })

        job.cancel()
        job.cancel()
        job.cancel()

        XCTAssertEqual(cancelledIDs, [job.id], "repeated cancels must not spam the service")
    }

    func testCancellingTheAwaitingTaskCancelsTheJob() async {
        var cancelledIDs: [String] = []
        let (job, _) = makeJob(onCancel: { cancelledIDs.append($0) })

        let task = Task { try await job.value() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        // Structured cancellation reaches the service; the job still needs its own completion.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(cancelledIDs, [job.id])

        job.complete(with: .failure(.cancelled))
        do {
            _ = try await task.value
            XCTFail("expected a throw")
        } catch FFmpegError.cancelled {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testLogIsCollectedWhetherOrNotAnyoneIsListening() {
        let (job, listener) = makeJob()

        listener.status(status: Fixture.status(domain: "info", message: "one"))
        listener.status(status: Fixture.status(domain: "error", message: "two"))

        XCTAssertEqual(job.log.map { $0.message }, ["one", "two"])
    }

    func testLogIsBoundedButKeepsTheTail() {
        let (job, listener) = makeJob()

        // ffmpeg can produce a great deal of this on a bad file.
        for index in 0..<600 {
            listener.status(status: Fixture.status(domain: "info", message: "line \(index)"))
        }

        XCTAssertEqual(job.log.count, 500)
        XCTAssertEqual(job.log.last?.message, "line 599", "the most recent lines are the useful ones")
    }
}
