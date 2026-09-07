import Foundation
import AppKit
import XPCServiceFramework
import XPCFFmpegServiceFramework

import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j
    

class XPCFFmpegInvokeService: XPCServiceListenerDelegate, XPCFFmpegInvokeProtocol {   

    /// Everything a running job needs kept alive for the duration of the call, and everything that
    /// has to be unwound once it finishes.
    private struct Job {
        let task: FFmpegTaskProcess
        let statusConnection: NSXPCConnection
    }

    private static let automaticTerminationReason = "XPCFFmpegInvoke running long-running command."

    private let mutex = MutexSynchronized()
    private var jobs: [String : Job] = [:]

    private let taskExecutableURL: URL?
    private let gracePeriod: TimeInterval?

    
    /// - Parameters:
    ///   - taskExecutableURL: the FFmpegTask to spawn. Nil means the one embedded beside this
    ///     service, which is what production always wants; tests substitute a stub.
    ///   - gracePeriod: how long a cancelled child gets between escalating signals.
    public init(taskExecutableURL: URL? = nil, gracePeriod: TimeInterval? = nil) {
        self.taskExecutableURL = taskExecutableURL
        self.gracePeriod = gracePeriod

        super.init(interface: XPCFFmpegInterfaces.invoke)
    }

    /// Removes scratch directories nothing is coming back for.
    ///
    /// A retained scratch directory is cleared up by the pass that says it is the last one. If
    /// that pass never runs - the client went away between the two - nobody clears it up, so an
    /// hour is treated as long enough to be sure. Nothing else writes here, and the paths are
    /// named from a UUID, so this cannot reach anything a caller owns.
    static func sweepStaleScratch() {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)

        guard let entries = try? manager.contentsOfDirectory(
                at: manager.temporaryDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return
        }

        for entry in entries where entry.lastPathComponent.hasPrefix("scratch-") {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true,
                  let modified = values?.contentModificationDate, modified < cutoff else {
                continue
            }

            try? manager.removeItem(at: entry)
        }
    }

    func invoke(jobID: String, endpoint: NSXPCListenerEndpoint, request: FFmpegRequest,
                fileTokens: [String], fileHandles: [FileHandle], reply handler: @escaping (CompletionHandler)) {

        guard fileTokens.count == fileHandles.count else {
            os_log("XPCFFmpegInvokeService.invoke->token and handle counts disagree")
            handler(nil, ServiceError.inaccessibleFile)
            return
        }

        // Place each granted descriptor at a number of our choosing in the child, and tell
        // FFmpegTask which is which by substituting the number into the argument vector. The
        // descriptors arrived open from the caller; nothing here has to be able to reach the file
        // by name, which is the whole point.
        var descriptors: [Int32 : FileHandle] = [:]
        var numbers: [String : String] = [:]

        for (index, token) in fileTokens.enumerated() {
            let childDescriptor = ChildProcess.firstMappedDescriptor + Int32(index)
            descriptors[childDescriptor] = fileHandles[index]
            numbers[token] = String(childDescriptor)
        }

        // A scratch token becomes a path in this service's own container. FFmpegTask inherits our
        // sandbox, so somewhere we may write is somewhere it may write - and it is the only way to
        // give ffmpeg a filename for the handful of options that will not take a descriptor.
        //
        // The directory is named by the token rather than by the job, because a two-pass encode is
        // two jobs sharing one pass log. Which of them clears it up is the token's business, not
        // this method's.
        XPCFFmpegInvokeService.sweepStaleScratch()

        var scratchDirectories: [String : URL] = [:]
        var retainedScratch = false

        var arguments: [String] = []
        arguments.reserveCapacity(request.arguments.count)

        for argument in request.arguments {
            if let scratch = FFmpegRequest.scratch(from: argument) {
                let directory = scratchDirectories[scratch.id]
                    ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent("scratch-\(scratch.id)", isDirectory: true)

                if scratchDirectories[scratch.id] == nil {
                    try? FileManager.default.createDirectory(at: directory,
                                                             withIntermediateDirectories: true)
                    scratchDirectories[scratch.id] = directory
                }

                retainedScratch = retainedScratch || scratch.isRetained
                arguments.append(directory.appendingPathComponent("pass").path)
                continue
            }

            guard argument.hasPrefix(FFmpegRequest.tokenPrefix) else {
                arguments.append(argument)
                continue
            }

            guard let number = numbers[argument] else {
                os_log("XPCFFmpegInvokeService.invoke->argument token has no matching descriptor")
                handler(nil, ServiceError.inaccessibleFile)
                return
            }

            arguments.append(number)
        }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = XPCFFmpegInterfaces.status
        connection.resume()

        // TODO: This should be handled in a way that lets the caller retry, etc.
        let service = connection.remoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as! XPCFFmpegStatusProtocol

        // Held for as long as the job actually runs. The previous version paired this with a defer
        // in the same scope, so it was re-enabled the instant invoke() returned - which is
        // immediately, since the work happens on the child process.
        ProcessInfo.processInfo.disableAutomaticTermination(XPCFFmpegInvokeService.automaticTerminationReason)

        let ffmpegTaskProcess = FFmpegTaskProcess(statusService: service,
                                                  executableURL: taskExecutableURL,
                                                  gracePeriod: gracePeriod ?? 2.0,
                                                  completionHandler: { [weak self] result in
            self?.finish(jobID: jobID)

            // Whatever the job scribbled goes with it, unless a later pass still needs it.
            // Removed on every other path, cancelled and failed included, since a half-written
            // pass log is worse than none - and a cancelled first pass has no second pass coming.
            if !retainedScratch || (try? result.get()) == nil {
                for directory in scratchDirectories.values {
                    try? FileManager.default.removeItem(at: directory)
                }
            }

            switch result {
            case .success(let object):
                handler(object, nil)

            case .failure(let error):
                handler(nil, error)
            }
        })

        // Registered before launching so that a cancel arriving in the gap between the two still
        // finds the job. The registry is also what owns the task for the duration of the call.
        mutex.synchronize {
            jobs[jobID] = Job(task: ffmpegTaskProcess, statusConnection: connection)
        }

        ffmpegTaskProcess.invoke(arguments: [request.request] + arguments, descriptors: descriptors)
    }

    func cancel(jobID: String) {
        os_log("XPCFFmpegInvokeService.cancel(%@)", jobID)

        // Unknown or already-finished IDs are ignored: a cancel racing a natural completion is
        // normal, and the caller has its result either way.
        let task = mutex.synchronize { jobs[jobID]?.task }
        task?.cancel()
    }

    /// Unwinds everything invoke() set up. Safe to call for an ID that is already gone.
    private func finish(jobID: String) {
        guard let job = mutex.synchronize({ jobs.removeValue(forKey: jobID) }) else { return }

        job.statusConnection.invalidate()

        ProcessInfo.processInfo.enableAutomaticTermination(XPCFFmpegInvokeService.automaticTerminationReason)
    }
    
}
