import Foundation
import XPCFFmpegServiceFramework
@testable import XPCFFmpeg

/// These types have no public memberwise init - they exist to be decoded off the wire - so tests
/// build them the same way the service does.
enum Fixture {

    static func progress(frame: Int = 100, fps: Double = 25, quality: Double = -1,
                         bitrate: Double? = 1536.5, totalSize: Int? = 4096,
                         outTime: Double? = 4, duplicateFrames: Int = 0, droppedFrames: Int = 0,
                         speed: Int? = 3, finished: Bool = false) -> FFmpegProgress {
        var fields: [String] = [
            "\"frame\":\(frame)", "\"fps\":\(fps)", "\"input\":0", "\"stream\":0",
            "\"quality\":\(quality)", "\"duplicateFrames\":\(duplicateFrames)",
            "\"droppedFrames\":\(droppedFrames)", "\"finished\":\(finished)"
        ]
        if let bitrate = bitrate { fields.append("\"bitrate\":\(bitrate)") }
        if let totalSize = totalSize { fields.append("\"totalSize\":\(totalSize)") }
        if let outTime = outTime { fields.append("\"outTime\":\(outTime)") }
        if let speed = speed { fields.append("\"speed\":\(speed)") }

        let json = "{\(fields.joined(separator: ","))}"
        return try! JSONDecoder().decode(FFmpegProgress.self, from: Data(json.utf8))
    }

    static func status(domain: String = "error", message: String = "something went wrong",
                       indent: Int = 0) -> FFmpegStatus {
        let json = "{\"domain\":\"\(domain)\",\"message\":\"\(message)\",\"indent\":\(indent)}"
        return try! JSONDecoder().decode(FFmpegStatus.self, from: Data(json.utf8))
    }

    /// A directory that cleans itself up, with a real file in it so bookmarks can be made.
    final class Sandbox {
        let directory: URL
        let existingFile: URL

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            existingFile = directory.appendingPathComponent("in.mov")
            try! Data("not really a movie".utf8).write(to: existingFile)
        }

        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }
}


/// Stands in for the XPC service. Records what it was asked to do, and lets a test drive the
/// replies - including the out-of-band progress the real service sends back over the job's
/// anonymous listener, which is a real XPC round trip even here.
final class FakeTransport: ServiceTransport {

    struct Invocation {
        let jobID: String
        let request: FFmpegRequest
        let endpoint: NSXPCListenerEndpoint
        let fileHandles: [FileHandle]
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    private var _cancelled: [String] = []
    private var _invalidated = false
    private var replies: [String : (Any?, Error?) -> Void] = [:]
    private var failures: [String : (Error) -> Void] = [:]

    /// Answers each invoke automatically with this, if set. Otherwise the test drives it by hand.
    var automaticReply: ((FFmpegRequest) -> (Any?, Error?))?

    var invocations: [Invocation] { lock.lock(); defer { lock.unlock() }; return _invocations }
    var cancelled: [String] { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var didInvalidate: Bool { lock.lock(); defer { lock.unlock() }; return _invalidated }

    func invoke(jobID: String, endpoint: NSXPCListenerEndpoint, request: FFmpegRequest,
                fileTokens: [String], fileHandles: [FileHandle],
                reply: @escaping (Any?, Error?) -> Void, failure: @escaping (Error) -> Void) {
        lock.lock()
        _invocations.append(Invocation(jobID: jobID, request: request, endpoint: endpoint,
                                       fileHandles: fileHandles))
        replies[jobID] = reply
        failures[jobID] = failure
        let auto = automaticReply
        lock.unlock()

        if let auto = auto {
            let (object, error) = auto(request)
            reply(object, error)
        }
    }

    func cancel(jobID: String) {
        lock.lock(); _cancelled.append(jobID); lock.unlock()
    }

    func invalidate() {
        lock.lock(); _invalidated = true; lock.unlock()
    }

    // MARK: - Driving a job from the "service" side

    func reply(to jobID: String, object: Any?, error: Error?) {
        lock.lock(); let handler = replies[jobID]; lock.unlock()
        handler?(object, error)
    }

    func failConnection(for jobID: String, error: Error) {
        lock.lock(); let handler = failures[jobID]; lock.unlock()
        handler?(error)
    }

    /// Connects back to the job's anonymous listener the way the real service does.
    func statusProxy(for jobID: String) -> (XPCFFmpegStatusProtocol, NSXPCConnection)? {
        lock.lock()
        let endpoint = _invocations.first(where: { $0.jobID == jobID })?.endpoint
        lock.unlock()

        guard let endpoint = endpoint else { return nil }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = XPCFFmpegInterfaces.status
        connection.resume()

        return (connection.remoteObjectProxy as! XPCFFmpegStatusProtocol, connection)
    }
}
