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

        var arguments: [String] = []
        arguments.reserveCapacity(request.arguments.count)

        for argument in request.arguments {
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
