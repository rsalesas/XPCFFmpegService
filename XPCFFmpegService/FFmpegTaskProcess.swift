//
//  FFmpegTaskProcess.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 7/4/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import XPCFFmpegServiceFramework

import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j




class FFmpegTaskProcess {
    
    public typealias CompletionHandler = (_ result: ServiceResult) -> Void

    private struct StandardErrorResponse: Codable {
        let status: FFmpegStatus?
        let progress: FFmpegProgress?
    }
    
    public struct StandardOutputResponse: Codable {
        let version: FFmpegVersion?
    }

    // Cancellation escalation. The first SIGTERM makes ffmpeg's decode_interrupt_cb return true so
    // it unwinds and flushes; a second one pushes it harder. We deliberately stop short of the
    // fourth signal, which is where ffmpeg's own sigterm_handler gives up and calls exit(123)
    // (fftools/ffmpeg.c), and go straight to SIGKILL instead - that is at least unambiguous.
    private static let defaultGracePeriod: TimeInterval = 2.0
    private static let escalationQueue = DispatchQueue(label: "com.siliconink.XPCFFmpegService.escalation", qos: .utility)

        
    private let mutex = MutexSynchronized()
    private let process: ChildProcess
    private let statusService: XPCFFmpegStatusProtocol

    // Set to nil the moment a result is delivered. Every completion path funnels through
    // complete(_:), which makes the XPC reply block fire exactly once - invoking it a second time
    // raises inside NSXPCConnection and takes the whole service down with it. That matters most on
    // the cancel path, where the reply goes out immediately and the process's own termination
    // handler then arrives moments later with an uncaughtSignal it must not report.
    private var handler: CompletionHandler?

    private let stdOutPipe: Pipe
    private var stdOutReader = FrameReader()
    
    private let stdErrPipe: Pipe
    private var stdErrReader = FrameReader()
    
    private var cancelled = false
    private var finished = false

    private let gracePeriod: TimeInterval
    
    
    /// Delivers `result` to the caller, at most once, and then tears down everything holding this
    /// object alive. Must be called with the mutex held.
    private func complete(_ result: ServiceResult) {
        guard let handler = self.handler else {
            os_log("FFmpegTaskProcess.complete->already completed, ignoring")
            return
        }

        self.handler = nil
        handler(result)

        teardown()
    }
    
    /// Drops the readability and termination callbacks and closes our ends of the pipes. Without
    /// this the pipes' dispatch sources keep reading forever and every conversion leaks its
    /// FFmpegTaskProcess, both Pipes and both validators for the lifetime of the service.
    private func teardown() {
        // Dropping the handlers is enough. The descriptors are closed when the Pipes deallocate,
        // which now actually happens - closing them here instead would mean closing a FileHandle
        // from inside its own readability handler, which is exactly where complete() is usually
        // called from.
        stdOutPipe.fileHandleForReading.readabilityHandler = nil
        stdErrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }
    
    private func stdOutReadabilityHandler(fileHandle: FileHandle) {
        mutex.synchronize {
            os_log("FFmpegTaskProcess.stdOutReadabilityHandler")

            let availableData = fileHandle.availableData
            if availableData.isEmpty {
                os_log("  FFmpegTaskProcess.stdOutReadabilityHandler::nil")
                stdOutPipe.fileHandleForReading.readabilityHandler = nil
                return
            }

            os_log("  FFmpegTaskProcess.stdOutReadabilityHandler (%d)", availableData.count)
            stdOutReader.append(availableData)

            let records: [Data]
            do {
                records = try stdOutReader.drain()
            } catch {
                os_log("    FFmpegTaskProcess.stdOut->stream desynchronised")
                terminateWithError(error: ServiceError.invalidResponse)
                return
            }

            for data in records {
                if let response = try? JSONDecoder().decode(StandardOutputResponse.self, from: data) {
                    if let ffmpegVersion = response.version {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->FFmpegProgress")
                        complete(.success(ffmpegVersion))
                    
                    } else if data.isEmptyJSON {
                        
                    } else if let json = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) {
                        complete(.success(json))
                        
                    } else {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->InvalidJSON")
                        terminateWithError(error: ServiceError.invalidResponse)
                    }

                }
            }
        }
    }
    
    private func stdErrReadabilityHandler(fileHandle: FileHandle) {
        self.mutex.synchronize {
            os_log("FFmpegTaskProcess.stdErrReadabilityHandler")
            
            let availableData = fileHandle.availableData
            if availableData.isEmpty {
                os_log("  FFmpegTaskProcess.stdErrReadabilityHandler::nil")
                stdErrPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
    
            os_log("  FFmpegTaskProcess.stdErrReadabilityHandler (%d)", availableData.count)
            stdErrReader.append(availableData)

            let records: [Data]
            do {
                records = try stdErrReader.drain()
            } catch {
                os_log("    FFmpegTaskProcess.stdErr->stream desynchronised")
                terminateWithError(error: ServiceError.invalidResponse)
                return
            }

            for data in records {
                // Deliberately not an assert. This is data from another process, and a debug build
                // that traps on a malformed progress line is worse than one that logs and carries on.
                if !data.isValidJSON {
                    // continue, not return: this loop replaced a forEach closure, where returning
                    // skipped one record. Returning here would abandon every record after it.
                    os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->non-JSON on stderr, skipping")
                    continue
                }

                if let response = try? JSONDecoder().decode(StandardErrorResponse.self, from: data) {
                    if let ffmpegProgress = response.progress {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->FFmpegProgress")
                        statusService.progress(progress: ffmpegProgress)

                    } else if let ffmpegStatus = response.status {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->FFmpegStatus")
                        statusService.status(status: ffmpegStatus)

                    } else if !data.isEmptyJSON {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->InvalidResponse")
                        terminateWithError(error: ServiceError.invalidResponse)
                    }

                }
            }
        }
    }

    /// Abandons the job at the caller's request. The reply goes out straight away with
    /// ServiceError.cancelled; the child is wound down in the background behind it.
    func cancel() {
        mutex.synchronize {
            os_log("FFmpegTaskProcess.cancel")

            guard !cancelled else { return }
            cancelled = true

            complete(.failure(ServiceError.cancelled))
            signalAndEscalate()
        }
    }
    
    /// Ends the job because we could not make sense of what the child was telling us.
    func terminateWithError(error: ServiceError) {
        mutex.synchronize {
            os_log("FFmpegTaskProcess.terminate")

            cancelled = true
            complete(.failure(error))
            signalAndEscalate()
        }
    }
    
    /// SIGTERM, then SIGTERM again, then SIGKILL - each step only if the child is still there.
    /// Deliberately never blocks the calling thread: the old version slept inside the lock, which
    /// stalled whichever readability handler happened to trigger the abort.
    private func signalAndEscalate() {
        guard process.isRunning else { return }
        process.terminate()

        // The escalation captures the Process, not self. The reply has already been delivered by
        // the time we get here, so the service has dropped this job from its registry and self is
        // on its way out - a weak capture would simply skip the rest of the escalation and leave a
        // wedged ffmpeg running forever.
        let process = self.process
        let gracePeriod = self.gracePeriod

        FFmpegTaskProcess.escalationQueue.asyncAfter(deadline: .now() + gracePeriod) {
            guard process.isRunning else { return }
            os_log("FFmpegTaskProcess.signalAndEscalate->second SIGTERM")
            process.terminate()

            FFmpegTaskProcess.escalationQueue.asyncAfter(deadline: .now() + gracePeriod) {
                guard process.isRunning else { return }
                os_log("FFmpegTaskProcess.signalAndEscalate->SIGKILL")
                process.forceKill()
            }
        }
    }
    
    /// - Parameters:
    ///   - executableURL: the FFmpegTask to run. Defaults to the one sitting beside this service in
    ///     the bundle, which is the only thing production ever wants; tests substitute a stub.
    ///   - gracePeriod: how long a cancelled child gets between escalating signals.
    init(statusService: XPCFFmpegStatusProtocol,
         executableURL: URL? = nil,
         gracePeriod: TimeInterval = FFmpegTaskProcess.defaultGracePeriod,
         completionHandler handler: @escaping CompletionHandler) {
        os_log("FFmpegTaskProcess.init")
                
        self.handler = handler
        self.statusService = statusService
        self.gracePeriod = gracePeriod
        self.process = ChildProcess(executableURL: executableURL ?? FFmpegTaskProcess.bundledTaskURL())

        stdOutPipe = Pipe()
        stdErrPipe = Pipe()

        // Every callback below captures self weakly. The object is kept alive for the duration of
        // the job by the service's job registry instead, which is also what makes cancel()
        // reachable - previously the callbacks retained self to stop it being deallocated, and
        // nothing ever broke that cycle.
        stdOutPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            self?.stdOutReadabilityHandler(fileHandle: fileHandle)
        }
        self.process.standardOutput = stdOutPipe

        stdErrPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            self?.stdErrReadabilityHandler(fileHandle: fileHandle)
        }
        self.process.standardError = stdErrPipe

        
        process.terminationHandler = { [weak self] termination in
            guard let self = self else { return }

            self.mutex.synchronize {
                os_log("FFmpegTaskProcess.init.terminationHandler")

                self.finished = true

                // A cancel has already replied. Anything the child says on its way out - an
                // uncaughtSignal from our own SIGTERM, most obviously - is exactly what we asked
                // for and must not be reported as a second, contradictory result.
                if self.cancelled {
                    os_log("  FFmpegTaskProcess.init.terminationHandler->cancelled, result already delivered")
                    self.teardown()
                    return
                }

                if termination.wasSignalled {
                    os_log("  FFmpegTaskProcess.init.terminationHandler->.uncaughtSignal")
                    self.complete(.failure(ServiceError.uncaughtSignal))

                } else if termination.status != 0 {
                    os_log("  FFmpegTaskProcess.init.terminationHandler->.terminationStatus(%d)", termination.status)
                    self.complete(.failure(ServiceError(exitCode: termination.status)))

                } else {
                    // A clean exit that produced no parseable stdout - which is the normal outcome
                    // for a transcode, since ffmpeg writes to the output file and reports progress
                    // on stderr. Without this the reply block was simply never invoked and the
                    // caller waited forever on a job that had already succeeded.
                    os_log("  FFmpegTaskProcess.init.terminationHandler->success")
                    self.complete(.success("Success"))
                }
            }
        }
    }
    
    /// The child's pid, or 0 before it has launched.
    var processIdentifier: Int32 {
        return mutex.synchronize { process.isRunning ? process.processIdentifier : 0 }
    }
    
    /// The FFmpegTask embedded alongside this service.
    static func bundledTaskURL() -> URL {
        guard let executablePath = Bundle.main.executablePath else {
            fatalError("Invalid state; unable to retrieve bundle executable path")
        }

        return URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent("FFmpegTask")
    }
    
    /// - Parameter descriptors: granted files, keyed by the number FFmpegTask should see them as.
    ///   These are the caller's own open files; a descriptor is the only file access that survives
    ///   the two process hops from the app to here to FFmpegTask.
    func invoke(arguments: [String], descriptors: [Int32 : FileHandle] = [:]) {
        os_log("FFmpegTaskProcess.invoke")

        mutex.synchronize {
            // A cancel that raced ahead of the spawn - the reply has already gone out, so there is
            // nothing left to start.
            guard !cancelled else {
                os_log("  FFmpegTaskProcess.invoke->cancelled before launch")
                return
            }

            do {
                process.arguments = arguments
                process.mappedDescriptors = descriptors.mapValues { $0.fileDescriptor }
                try process.run()

            } catch {
                os_log("FFmpegTaskProcess.invoke, error: %@", error.localizedDescription)
                complete(.failure(ServiceError.unableToInvoke))
            }
        }
    }
    
}
