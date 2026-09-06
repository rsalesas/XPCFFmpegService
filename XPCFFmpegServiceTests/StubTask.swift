import Foundation
import XPCFFmpegServiceFramework

/// Stands in for FFmpegTask.
///
/// The service's job is to launch a child, read framed JSON off its pipes and turn its exit status
/// into a result. None of that needs FFmpeg to be involved, and a stub makes the awkward cases -
/// a child that ignores SIGTERM, one that exits 123, one that emits nonsense - reachable at all.
struct StubTask {

    let directory: URL
    let url: URL

    private init(directory: URL, url: URL) {
        self.directory = directory
        self.url = url
    }

    /// Wraps each record the way FFmpegTask does, so a stub speaks the same pipe protocol.
    /// Passing `framed: false` produces raw bytes instead, which is how a desynchronised stream is
    /// reached deliberately.
    static func records(_ payloads: [String], framed: Bool = true) -> Data {
        var data = Data()
        for payload in payloads {
            let bytes = Data(payload.utf8)
            data.append(framed ? (PipeFraming.frame(bytes) ?? Data()) : bytes)
        }
        return data
    }

    static func make(standardOutput: String = "", standardError: String = "",
                     exitCode: Int32 = 0, body: String? = nil) -> StubTask {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stub-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Payloads go in files rather than inline, so no amount of JSON quoting can break the shell.
        let outFile = directory.appendingPathComponent("out")
        let errFile = directory.appendingPathComponent("err")
        try! frameIfNeeded(standardOutput).write(to: outFile)
        try! frameIfNeeded(standardError).write(to: errFile)

        let script = body ?? """
        #!/bin/sh
        cat "\(outFile.path)"
        cat "\(errFile.path)" >&2
        exit \(exitCode)
        """

        let url = directory.appendingPathComponent("FFmpegTask")
        try! Data(script.utf8).write(to: url)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        return StubTask(directory: directory, url: url)
    }

    /// A child that refuses to die on SIGTERM, so escalation to SIGKILL is observable.
    static func unkillable(standardError: String = "") -> StubTask {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stub-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let errFile = directory.appendingPathComponent("err")
        try! frameIfNeeded(standardError).write(to: errFile)

        return make(body: """
        #!/bin/sh
        trap '' TERM
        cat "\(errFile.path)" >&2
        while true; do sleep 0.2; done
        """)
    }

    /// Records the argv it was handed, so argument substitution can be asserted on.
    static func recordingArguments(to record: URL) -> StubTask {
        return make(body: """
        #!/bin/sh
        for arg in "$@"; do echo "$arg" >> "\(record.path)"; done
        exit 0
        """)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Text handed to the stub is treated as one record per line, framed. A caller that has
    /// already produced bytes - to test a malformed stream - passes them through untouched by
    /// prefixing with the raw marker.
    private static func frameIfNeeded(_ text: String) -> Data {
        guard !text.isEmpty else { return Data() }

        if let raw = text.stripping(prefix: rawMarker) { return Data(raw.utf8) }

        let lines = text.split(separator: "\n").map(String.init)
        return records(lines)
    }

    /// Marks a payload that must reach the reader exactly as written, unframed.
    static let rawMarker = "\u{1}RAW\u{1}"

    static func raw(_ text: String) -> String { rawMarker + text }
}


/// Collects what the service reports back, in place of the client's anonymous listener.
final class RecordingStatusService: NSObject, XPCFFmpegStatusProtocol {

    private let lock = NSLock()
    private var _progress: [FFmpegProgress] = []
    private var _statuses: [FFmpegStatus] = []

    var progressUpdates: [FFmpegProgress] { lock.lock(); defer { lock.unlock() }; return _progress }
    var statuses: [FFmpegStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }

    func progress(progress: FFmpegProgress) {
        lock.lock(); _progress.append(progress); lock.unlock()
    }

    func status(status: FFmpegStatus) {
        lock.lock(); _statuses.append(status); lock.unlock()
    }
}


/// A real anonymous listener, so the service gets a genuine endpoint to connect back to.
final class StatusEndpointHost: NSObject, NSXPCListenerDelegate, XPCFFmpegStatusProtocol {

    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var _progress: [FFmpegProgress] = []
    private var _statuses: [FFmpegStatus] = []

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    var progressUpdates: [FFmpegProgress] { lock.lock(); defer { lock.unlock() }; return _progress }
    var statuses: [FFmpegStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func invalidate() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = XPCFFmpegInterfaces.status
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func progress(progress: FFmpegProgress) { lock.lock(); _progress.append(progress); lock.unlock() }
    func status(status: FFmpegStatus) { lock.lock(); _statuses.append(status); lock.unlock() }
}


extension String {
    func stripping(prefix: String) -> String? {
        return hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}


enum Payload {
    static func progress(frame: Int = 10, finished: Bool = false) -> String {
        return """
        {"progress":{"frame":\(frame),"fps":25,"input":0,"stream":0,"quality":-1,\
        "duplicateFrames":0,"droppedFrames":0,"finished":\(finished)}}
        """
    }

    static func status(domain: String = "error", message: String = "boom") -> String {
        return #"{"status":{"domain":"\#(domain)","message":"\#(message)","indent":0}}"#
    }
}
