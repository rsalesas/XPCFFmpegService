//
//  FFmpeg.swift
//  XPCFFmpeg
//
//  The entry point. Owns the connection to the XPC service; jobs come from it.
//
//  There is no per-job initialiser on purpose: you cannot hold a handle to something you have not
//  started yet. What the session is for is the connection itself, the concurrency limit, and the
//  questions that are not jobs at all - what codecs are available, what version this is.
//

import Foundation
import XPCServiceFramework
import XPCFFmpegServiceFramework


public final class FFmpeg {

    public static let defaultServiceName = "com.siliconink.XPCFFmpegService"

    private let transport: ServiceTransport
    private let lock = NSLock()
    private var liveJobs: [String : Job] = [:]

    /// - Parameter serviceName: the bundle identifier of the embedded XPC service. The default
    ///   matches the service shipped with this project; override it if you have rebranded it.
    public convenience init(serviceName: String = FFmpeg.defaultServiceName) {
        self.init(transport: XPCServiceTransport(serviceName: serviceName))
    }

    init(transport: ServiceTransport) {
        self.transport = transport
    }

    deinit {
        transport.invalidate()
    }

    // MARK: - Conversion

    /// Starts a conversion and returns immediately. Await `value()` on the job, or iterate its
    /// events, or neither - it runs either way.
    ///
    /// Deliberately not another `convert` overload: one that returns a Job and one that is async
    /// differ only in effect, and `try await convert(c)` binds to this one and returns straight
    /// away, because `await` on a non-async call is merely a warning.
    public func startConversion(_ conversion: Conversion) throws -> Job {
        return start(try RequestBuilder.request(for: conversion), totalDuration: nil)
    }

    /// Runs a conversion to completion. Probes the source first so that progress can report a
    /// meaningful `fractionCompleted`. Returns the first output's URL.
    @discardableResult
    public func convert(_ conversion: Conversion,
                        onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> URL? {
        // Probing first is what lets progress report a fraction rather than just a frame count.
        // A source we cannot probe is not a reason to refuse the conversion.
        var duration: TimeInterval?
        if let first = conversion.inputs.first {
            duration = await probeDuration(of: first.url)
        }

        let job = start(try RequestBuilder.request(for: conversion), totalDuration: duration)

        if let onProgress = onProgress {
            Task { [events = job.events] in
                for await event in events {
                    if case .progress(let progress) = event { onProgress(progress) }
                }
            }
        }

        _ = try await job.value()
        return conversion.outputs.first?.url
    }

    // MARK: - Probing

    /// Reads a file's format and streams.
    public func probe(_ url: URL, options: ProbeOptions = .default) async throws -> MediaInfo {
        let job = start(try RequestBuilder.probeRequest(for: url, options: options), totalDuration: nil)
        let response = try await job.value()

        return try MediaInfo(response: response, log: job.log)
    }

    // MARK: - Capabilities

    /// The FFmpeg build backing the service.
    public func version() async throws -> FFmpegVersion {
        let job = start(RequestBuilder.Built(request: FFmpegRequest(request: "-version", arguments: []),
                                            tokens: [], handles: [], placeholders: []),
                        totalDuration: nil)
        let response = try await job.value()

        guard let version = response as? FFmpegVersion else {
            throw FFmpegError.unexpectedResponse("expected a version, got \(type(of: response))")
        }

        return version
    }

    // MARK: - Escape hatch

    /// Runs a request this package does not model. `arguments` is the command line after the verb;
    /// every file it needs must be listed in `files` so the service can be granted access to it.
    /// Runs a request this package does not model.
    ///
    /// `arguments` is the command line after the verb. Every file it needs must be listed in
    /// `files`; each is opened here and the path it appears under in `arguments` is replaced with
    /// ffmpeg's "-fd N ... fd:" form, since the service reaches files only through descriptors.
    public func run(request verb: String, arguments: [String], files: [URL] = []) throws -> Job {
        let built = try RequestBuilder.raw(verb: verb, arguments: arguments, files: files)
        return start(built, totalDuration: nil)
    }

    // MARK: - Plumbing

    private func probeDuration(of url: URL) async -> TimeInterval? {
        return try? await probe(url).duration
    }

    /// Internal rather than private so the capability queries in Capabilities.swift can reach
    /// it: they are jobs like any other, just ones that carry no files and report no progress.
    func start(_ built: RequestBuilder.Built, totalDuration: TimeInterval?) -> Job {
        let request = built.request
        let placeholders = built.placeholders
        let id = UUID().uuidString
        let listener = JobStatusListener(totalDuration: totalDuration)
        listener.resume()

        let job = Job(id: id, listener: listener, cancelHandler: { [weak self] id in
            self?.transport.cancel(jobID: id)
        })

        lock.lock()
        liveJobs[id] = job
        lock.unlock()

        transport.invoke(jobID: id, endpoint: listener.endpoint, request: request,
                         fileTokens: built.tokens, fileHandles: built.handles,
                         reply: { [weak self] object, error in
            self?.forget(id)

            if let error = error {
                FFmpeg.discardUnwritten(placeholders)
                job.complete(with: .failure(FFmpeg.mapped(error, log: job.log)))
            } else {
                job.complete(with: .success(object))
            }

        }, failure: { [weak self] error in
            // The connection itself failed, so no reply is coming and the job has to be completed
            // from here or the caller waits forever.
            self?.forget(id)
            FFmpeg.discardUnwritten(placeholders)
            job.complete(with: .failure(.serviceUnavailable(error)))
        })

        return job
    }

    private func forget(_ id: String) {
        lock.lock()
        liveJobs[id] = nil
        lock.unlock()
    }

    /// Removes destinations we created only so they could be bookmarked, when the job left them
    /// empty. A file the job actually wrote to is left alone, however it ended.
    private static func discardUnwritten(_ placeholders: [URL]) {
        for url in placeholders {
            // Via FileManager rather than URL.resourceValues: a URL caches what it has been asked
            // for, and this one was already used to make a bookmark before the job ran.
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            if size == 0 { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func mapped(_ error: Error, log: [LogMessage]) -> FFmpegError {
        let ns = error as NSError

        guard ns.domain == ServiceError.errorDomain,
              let serviceError = ServiceError(rawValue: Int32(ns.code)) else {
            return .serviceUnavailable(error)
        }

        return serviceError == .cancelled ? .cancelled : .failed(serviceError, log: log)
    }
}
