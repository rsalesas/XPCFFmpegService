//
//  Job.swift
//  XPCFFmpeg
//
//  A running invocation. Owns the anonymous listener the service reports back on, so the caller
//  never has to know one exists.
//

import Foundation
import XPCServiceFramework
import XPCFFmpegServiceFramework


/// Receives the service's out-of-band updates for one job.
///
/// Separate from Job itself because XPCAnonymousListenerDelegate is the exported object on its own
/// connection, and the delivered result must not depend on the caller still holding the Job.
final class JobStatusListener: XPCAnonymousListenerDelegate, XPCFFmpegStatusProtocol {

    private let lock = NSLock()
    private var onEvent: ((JobEvent) -> Void)?
    private var totalDuration: TimeInterval?
    private var log: [LogMessage] = []

    init(totalDuration: TimeInterval?) {
        self.totalDuration = totalDuration
        super.init(interface: XPCFFmpegInterfaces.status)
    }

    /// Everything ffmpeg said, kept so a failure can be explained with ffmpeg's own words rather
    /// than just an exit status.
    var collectedLog: [LogMessage] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func setHandler(_ handler: ((JobEvent) -> Void)?) {
        lock.lock(); onEvent = handler; lock.unlock()
    }

    func progress(progress: FFmpegProgress) {
        lock.lock()
        let total = totalDuration
        let handler = onEvent
        lock.unlock()

        handler?(.progress(Progress(progress, totalDuration: total)))
    }

    func status(status: FFmpegStatus) {
        let message = LogMessage(status)

        lock.lock()
        log.append(message)
        // ffmpeg is capable of producing a great deal of this on a bad file; keep the tail.
        if log.count > 500 { log.removeFirst(log.count - 500) }
        let handler = onEvent
        lock.unlock()

        handler?(.log(message))
    }
}


/// A job in flight.
///
/// Await `value()` for the result, or iterate `events` to follow it. Both are safe to use at once,
/// and safe to ignore entirely - the job runs regardless.
public final class Job {

    public let id: String

    private let listener: JobStatusListener
    private let cancelHandler: (String) -> Void

    private let lock = NSLock()
    private var completion: Result<Any?, FFmpegError>?
    private var waiters: [CheckedContinuation<Any?, Error>] = []
    private var eventContinuations: [UUID : AsyncStream<JobEvent>.Continuation] = [:]
    private var isCancelled = false

    init(id: String, listener: JobStatusListener, cancelHandler: @escaping (String) -> Void) {
        self.id = id
        self.listener = listener
        self.cancelHandler = cancelHandler

        listener.setHandler { [weak self] event in
            self?.deliver(event)
        }
    }

    /// Progress and log lines as they arrive.
    ///
    /// A stream created after the job has already finished yields nothing and terminates
    /// immediately rather than hanging.
    public var events: AsyncStream<JobEvent> {
        return AsyncStream { continuation in
            let key = UUID()

            lock.lock()
            let finished = completion != nil
            if !finished { eventContinuations[key] = continuation }
            lock.unlock()

            if finished {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock()
                self.eventContinuations[key] = nil
                self.lock.unlock()
            }
        }
    }

    /// Everything ffmpeg logged, whether or not the job succeeded.
    public var log: [LogMessage] { return listener.collectedLog }

    /// Asks the service to abandon the job. One-way: the outcome arrives through `value()` as
    /// FFmpegError.cancelled, so there is still exactly one completion for the job.
    public func cancel() {
        lock.lock()
        let alreadyCancelled = isCancelled
        isCancelled = true
        lock.unlock()

        guard !alreadyCancelled else { return }
        cancelHandler(id)
    }

    /// Waits for the job to finish. Throws FFmpegError.cancelled if it was cancelled.
    @discardableResult
    public func value() async throws -> Any? {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()

                if let completion = completion {
                    lock.unlock()
                    continuation.resume(with: completion.mapError { $0 as Error })
                    return
                }

                waiters.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            // Structured cancellation of the awaiting Task cancels the conversion too, which is
            // what anyone writing `try await` in a cancellable context will expect.
            cancel()
        }
    }

    private func deliver(_ event: JobEvent) {
        lock.lock()
        let continuations = Array(eventContinuations.values)
        lock.unlock()

        continuations.forEach { $0.yield(event) }
    }

    func complete(with result: Result<Any?, FFmpegError>) {
        lock.lock()

        guard completion == nil else {
            lock.unlock()
            return
        }

        completion = result
        let resumers = waiters
        let continuations = Array(eventContinuations.values)
        waiters.removeAll()
        eventContinuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.finish() }
        resumers.forEach { $0.resume(with: result.mapError { $0 as Error }) }

        listener.setHandler(nil)
        listener.invalidate()
    }
}
