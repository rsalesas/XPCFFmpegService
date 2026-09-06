//
//  ServiceTransport.swift
//  XPCFFmpeg
//
//  The one place that knows about NSXPCConnection.
//
//  Kept behind a protocol so the session's orchestration - the job registry, error mapping, the
//  probe-then-convert sequence - can be exercised without an XPC service to talk to. Internal, so
//  none of this widens the public API.
//

import Foundation
import XPCFFmpegServiceFramework


protocol ServiceTransport: AnyObject {

    /// Starts a job. Exactly one of the two completions must be delivered: `reply` when the
    /// service answers, `failure` when the connection itself fails - NSXPCConnection calls its
    /// error handler *instead of* the reply block, not as well as it.
    func invoke(jobID: String,
                endpoint: NSXPCListenerEndpoint,
                request: FFmpegRequest,
                fileTokens: [String],
                fileHandles: [FileHandle],
                reply: @escaping (Any?, Error?) -> Void,
                failure: @escaping (Error) -> Void)

    /// One-way; there is no reply to lose.
    func cancel(jobID: String)

    func invalidate()
}


final class XPCServiceTransport: ServiceTransport {

    private let connection: NSXPCConnection

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = XPCFFmpegInterfaces.invoke
        connection.resume()
    }

    func invoke(jobID: String,
                endpoint: NSXPCListenerEndpoint,
                request: FFmpegRequest,
                fileTokens: [String],
                fileHandles: [FileHandle],
                reply: @escaping (Any?, Error?) -> Void,
                failure: @escaping (Error) -> Void) {

        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            failure(error)
        } as! XPCFFmpegInvokeProtocol

        remote.invoke(jobID: jobID, endpoint: endpoint, request: request,
                      fileTokens: fileTokens, fileHandles: fileHandles, reply: reply)
    }

    func cancel(jobID: String) {
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in
            // Nothing to deliver: the outcome reaches the caller through the job's invoke reply.
        } as! XPCFFmpegInvokeProtocol

        remote.cancel(jobID: jobID)
    }

    func invalidate() {
        connection.invalidate()
    }
}
