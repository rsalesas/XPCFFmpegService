//
//  XPCFFmegProtocols.swift
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation


// TODO: Look at @functionbuilder as a way of creating the arguments for filters, inputs, etc.
// Class subscripts?
// https://www.objc.io/issues/14-mac/xpc


// Shim for (_ result: ServiceResult) -> Void as Result<> cannot be passed through Ojective-C
public typealias CompletionHandler = (_ success: Any?, _ error: Error?) -> Void

public typealias ServiceResult = Swift.Result<Any, ServiceError>


public enum ServiceError : Int32, Error, Codable {
    case failure = 1                        // General FFmpeg failures
    case insufficientArguments = 2          // FFmpegTask failures
    case invalidArgument = 3
    case unknownRequest = 4
    case uncaughtSignal = 5                 // XPCFFmpegService failures
    case invalidResponse = 6
    case unableToInvoke = 7
    case cancelled = 8                      // The caller asked for the job to be abandoned
    case hardExit = 9                       // ffmpeg bailed out of its own signal handler
    case inaccessibleFile = 10             // A file could not be opened for the job
    case unexpectedExit = 11                // An exit code outside anything we know how to name

    /// Maps a child process exit status onto a ServiceError.
    ///
    /// FFmpegTask normalises its own failures to 1...4 (see FFmpegTask.ExitCode), but it is not
    /// the only thing that can set the exit status. ffmpeg's sigterm_handler calls exit(123)
    /// directly once it has seen more than three signals, bypassing FFmpegTask entirely, and
    /// ffmpeg's main() returns 255 when it stops because of a signal. Neither can be allowed to
    /// trap here - this runs inside the XPC service, so a fatalError on an unexpected code takes
    /// the service down along with every other conversion it is hosting.
    public init (exitCode: Int32) {
        switch exitCode {
        case 1...4:
            self = ServiceError(rawValue: exitCode) ?? .unexpectedExit

        case 123:
            // fftools/ffmpeg.c: "Received > 3 system signals, hard exiting"
            self = .hardExit

        case 255:
            // fftools/ffmpeg.c main(): ret = received_nb_signals ? 255 : ...
            self = .uncaughtSignal

        default:
            self = .unexpectedExit
        }
    }
}

/// Errors are bridged to NSError on their way across the connection, so without this the caller
/// only ever sees "The operation couldn't be completed. (ServiceError error 11.)".
extension ServiceError: LocalizedError, CustomNSError {

    public static var errorDomain: String {
        return "com.siliconink.XPCFFmpegService.ServiceError"
    }

    public var errorCode: Int {
        return Int(rawValue)
    }

    public var errorUserInfo: [String : Any] {
        return [NSLocalizedDescriptionKey : errorDescription ?? "Unknown error"]
    }

    public var errorDescription: String? {
        switch self {
        case .failure:               return "FFmpeg was unable to complete the operation."
        case .insufficientArguments: return "Not enough arguments were supplied for the request."
        case .invalidArgument:       return "One or more of the supplied arguments is not permitted."
        case .unknownRequest:        return "The request is not one FFmpegTask knows how to service."
        case .uncaughtSignal:        return "FFmpegTask was stopped by a signal."
        case .invalidResponse:       return "FFmpegTask sent a response that could not be understood."
        case .unableToInvoke:        return "FFmpegTask could not be launched."
        case .cancelled:             return "The operation was cancelled."
        case .hardExit:              return "FFmpeg stopped responding to termination requests and exited abruptly."
        case .inaccessibleFile:      return "A file needed for the operation could not be opened."
        case .unexpectedExit:        return "FFmpegTask exited with an unrecognised status."
        }
    }
}

@objc public class FFmpegStatus: NSObject, NSSecureCoding, Codable, LocalizedError {
    
    public enum Domain: String, Codable {
        case unkown
        case os_log
        case quiet
        case panic
        case fatal
        case error
        case warning
        case info
        case verbose
        case debug
        case trace
    }
    
    public let domain: Domain
    public let message: String
    public let indent: Int
    
    // Previously a stored-property-style `localizedDescription`, which shadows rather than
    // satisfies Error's - so nothing that went through Error ever saw it.
    public var errorDescription: String? {
        return "The operation could not be completed (\(self.domain): \(self.message))"
    }

    public override var description: String {
        return "\(self.domain): \(self.message)"
    }

    public static var supportsSecureCoding: Bool {
        return true
    }

    public func encode(with coder: NSCoder) {
        coder.encode(domain.rawValue as NSString, forKey: "domain")
        coder.encode(message as NSString, forKey: "message")
        coder.encode(indent, forKey: "indent")
    }

    public required init?(coder: NSCoder) {
        let rawDomain = coder.decodeObject(of: NSString.self, forKey: "domain") as String? ?? ""
        domain = Domain(rawValue: rawDomain) ?? .unkown
        message = coder.decodeObject(of: NSString.self, forKey: "message") as String? ?? ""
        indent = coder.decodeInteger(forKey: "indent")
    }
}

@objc public class FFmpegProgress: NSObject, NSSecureCoding, Codable {
    public var frame: Int
    public var fps: Double
    public var input: Int
    public var stream: Int
    public var quality: Double
    public var bitrate: Double?
    public var totalSize: Int?
    public var outTime: TimeInterval?
    public var duplicateFrames: Int
    public var droppedFrames: Int
    /// Encoding speed as a multiple of realtime. Fractional: ffmpeg prints "0.997x"
    /// as readily as "12x".
    public var speed: Double?
    public var finished: Bool

    public override var description: String {
        var parts = ["frame \(frame)", String(format: "%.1f fps", fps)]

        if let outTime = outTime {
            parts.append(String(format: "%.2fs", outTime))
        }
        if let bitrate = bitrate {
            parts.append(String(format: "%.1f kbits/s", bitrate))
        }
        if let totalSize = totalSize {
            parts.append("\(totalSize) bytes")
        }
        if droppedFrames > 0 {
            parts.append("\(droppedFrames) dropped")
        }
        if finished {
            parts.append("finished")
        }

        return parts.joined(separator: ", ")
    }

    public static var supportsSecureCoding: Bool {
        return true
    }

    public func encode(with coder: NSCoder) {
        coder.encode(frame, forKey: "frame")
        coder.encode(fps, forKey: "fps")
        coder.encode(input, forKey: "input")
        coder.encode(stream, forKey: "stream")
        coder.encode(quality, forKey: "quality")
        coder.encode(bitrate.map { NSNumber(value: $0) }, forKey: "bitrate")
        coder.encode(totalSize.map { NSNumber(value: $0) }, forKey: "totalSize")
        coder.encode(outTime.map { NSNumber(value: $0) }, forKey: "outTime")
        coder.encode(duplicateFrames, forKey: "duplicateFrames")
        coder.encode(droppedFrames, forKey: "droppedFrames")
        coder.encode(speed.map { NSNumber(value: $0) }, forKey: "speed")
        coder.encode(finished, forKey: "finished")
    }

    public required init?(coder: NSCoder) {
        frame = coder.decodeInteger(forKey: "frame")
        fps = coder.decodeDouble(forKey: "fps")
        input = coder.decodeInteger(forKey: "input")
        stream = coder.decodeInteger(forKey: "stream")
        quality = coder.decodeDouble(forKey: "quality")
        bitrate = coder.decodeObject(of: NSNumber.self, forKey: "bitrate")?.doubleValue
        totalSize = coder.decodeObject(of: NSNumber.self, forKey: "totalSize")?.intValue
        outTime = coder.decodeObject(of: NSNumber.self, forKey: "outTime")?.doubleValue
        duplicateFrames = coder.decodeInteger(forKey: "duplicateFrames")
        droppedFrames = coder.decodeInteger(forKey: "droppedFrames")
        speed = coder.decodeObject(of: NSNumber.self, forKey: "speed")?.doubleValue
        finished = coder.decodeBool(forKey: "finished")
    }
}

@objc public class FFmpegVersion: NSObject, NSSecureCoding, Codable {
    public let version: String
    public let compiler: String
    public let ffmpegCopyright: String
    public let configuration: String
    public var libraries: [String : String] = [:]
    
    public static var supportsSecureCoding: Bool {
      return true
    }
    
    public func encode(with coder: NSCoder) {
        coder.encode(version as NSString, forKey: "version")
        coder.encode(compiler as NSString, forKey: "compiler")
        coder.encode(ffmpegCopyright as NSString, forKey: "ffmpegCopyright")
        coder.encode(configuration as NSString, forKey: "configuration")
        coder.encode(libraries as NSDictionary, forKey: "libraries")
    }
    
    public required init?(coder: NSCoder) {
        version = coder.decodeObject(of: NSString.self, forKey: "version") as String? ?? ""
        compiler = coder.decodeObject(of: NSString.self, forKey: "compiler") as String? ?? ""
        ffmpegCopyright = coder.decodeObject(of: NSString.self, forKey: "ffmpegCopyright") as String? ?? ""
        configuration = coder.decodeObject(of: NSString.self, forKey: "configuration") as String? ?? ""
        libraries = coder.decodeObject(of: [NSDictionary.self, NSString.self], forKey: "libraries") as? [String : String] ?? [:]
    }
}


/// One ffmpeg/ffprobe invocation.
///
/// `arguments` is the command line after the verb. Wherever FFmpegTask needs a descriptor number,
/// the client leaves a token, and the service replaces it with the number that descriptor was
/// given in the child.
///
/// File access travels as open descriptors, not as paths or bookmarks, because a descriptor is the
/// only thing that survives the two process hops from the app, through this service, to FFmpegTask.
/// A sandbox extension is a right that has to be exercised by whoever opens the file: it can cross
/// one hop and not two, and an app-scoped bookmark cannot even be resolved outside the app that
/// made it. A descriptor is access already exercised, so it travels as far as it is passed.
@objc public final class FFmpegRequest: NSObject, NSSecureCoding {

    /// A placeholder for a descriptor number in `arguments`.
    public static let tokenPrefix = "\u{1}xpcffmpeg.fd."
    public static let tokenTerminator: Character = "\u{1}"

    /// A placeholder for a scratch *path* in `arguments`, which the service fills in with a
    /// location inside its own container.
    ///
    /// The exception that proves the descriptor rule. Almost everything ffmpeg touches can be
    /// handed to it already open, but a few options take a filename it opens for itself, and
    /// `-passlogfile` - the statistics a two-pass encode writes between passes - is the one that
    /// matters. There is no descriptor form of it. Since FFmpegTask inherits the service's
    /// sandbox, the service is the process that can name somewhere both of them may write, so it
    /// picks the path and removes what was left there when the job ends.
    ///
    /// Nothing the caller names ever becomes a scratch path: this is a private scribbling place,
    /// not a way to reach a file by name.
    public static let scratchTokenPrefix = "\u{1}xpcffmpeg.scratch."

    /// Marks a scratch token whose contents have to outlive the job that wrote them.
    ///
    /// A two-pass encode is two jobs: the first writes the statistics and the second reads them,
    /// so the first cannot take its scratch directory with it. Both passes use the same token id,
    /// and only the last one asks for it to be cleaned up.
    public static let scratchRetainedMarker = "keep."

    public static func token(for id: UUID = UUID()) -> String {
        return "\(tokenPrefix)\(id.uuidString)\(tokenTerminator)"
    }

    /// - Parameter retained: leave the directory in place when this job finishes, because a later
    ///   one still needs what is in it.
    public static func scratchToken(for id: UUID = UUID(), retained: Bool = false) -> String {
        let marker = retained ? scratchRetainedMarker : ""
        return "\(scratchTokenPrefix)\(marker)\(id.uuidString)\(tokenTerminator)"
    }

    /// The identity and lifetime encoded in a scratch token, or nil if it is not one.
    public static func scratch(from token: String) -> (id: String, isRetained: Bool)? {
        guard token.hasPrefix(scratchTokenPrefix) else { return nil }

        var body = String(token.dropFirst(scratchTokenPrefix.count))
        if body.last == tokenTerminator { body.removeLast() }

        let isRetained = body.hasPrefix(scratchRetainedMarker)
        if isRetained { body.removeFirst(scratchRetainedMarker.count) }

        // The id has to be exactly what a UUID looks like: it names a directory, and a token is
        // the one part of a request the caller composes freely.
        guard UUID(uuidString: body) != nil else { return nil }

        return (body, isRetained)
    }

    /// The FFmpegTask request verb: "-ffmpeg", "-ffprobe", "-codecs", "-version", and so on.
    public let request: String

    /// The full argument vector after the verb, with descriptor tokens where numbers belong.
    public let arguments: [String]

    public init(request: String, arguments: [String]) {
        self.request = request
        self.arguments = arguments
    }

    public static var supportsSecureCoding: Bool {
        return true
    }

    public func encode(with coder: NSCoder) {
        coder.encode(request as NSString, forKey: "request")
        coder.encode(arguments as NSArray, forKey: "arguments")
    }

    public required init?(coder: NSCoder) {
        guard let request = coder.decodeObject(of: NSString.self, forKey: "request") as String?,
              let arguments = coder.decodeObject(of: [NSArray.self, NSString.self], forKey: "arguments") as? [String]
        else {
            return nil
        }

        self.request = request
        self.arguments = arguments
    }
}


/// Out-of-band updates for a job in flight, delivered to the anonymous listener the caller passes
/// into invoke(). These carry the decoded objects rather than a rendered string: the service has
/// already parsed FFmpegTask's JSON, and flattening it to text at that point threw the numbers away
/// before the caller ever saw them.
@objc public protocol XPCFFmpegStatusProtocol {

    @objc(reportProgress:)
    func progress(progress: FFmpegProgress)

    @objc(reportStatus:)
    func status(status: FFmpegStatus)

}


@objc public protocol XPCFFmpegInvokeProtocol {

    /// Starts a job. `jobID` is chosen by the caller rather than handed back in the reply so that
    /// a cancel can be issued at any point after the call is made - including before the service
    /// has got as far as spawning anything.
    /// - Parameters:
    ///   - fileTokens: the tokens in `request.arguments`, in the same order as `fileHandles`.
    ///   - fileHandles: descriptors the caller has already opened. NSXPC transfers the descriptor
    ///     itself, which is what carries the access; nothing else about the file is sent.
    @objc(invokeJob:endpoint:request:fileTokens:fileHandles:reply:)
    func invoke(jobID: String, endpoint: NSXPCListenerEndpoint, request: FFmpegRequest, fileTokens: [String], fileHandles: [FileHandle], reply handler: @escaping (CompletionHandler))

    /// Asks the service to abandon `jobID`. The outcome is delivered through that job's original
    /// invoke reply as ServiceError.cancelled; unknown or already-finished job IDs are ignored.
    @objc(cancelJob:)
    func cancel(jobID: String)

}


/// Pre-configured NSXPCInterfaces for the protocols above.
///
/// Both ends of a connection have to agree on these, so they are built here rather than with a
/// bare NSXPCInterface(with:) at each call site. The invoke reply passes `Any?` (ffprobe returns
/// arbitrary JSON), and NSXPCConnection silently refuses to decode any class it has not been
/// explicitly told to expect - so every container and leaf type JSONSerialization can produce has
/// to be whitelisted here. The status interface needs no such treatment: its arguments are
/// concrete NSSecureCoding classes, which NSXPCInterface works out from the signature.
public enum XPCFFmpegInterfaces {

    public static let invokeSelector = NSSelectorFromString("invokeJob:endpoint:request:fileTokens:fileHandles:reply:")

    public static var invoke: NSXPCInterface {
        let interface = NSXPCInterface(with: XPCFFmpegInvokeProtocol.self)

        let replyClasses = NSSet(array: [
            NSDictionary.self, NSArray.self, NSString.self, NSNumber.self,
            NSData.self, NSDate.self, NSNull.self, FFmpegVersion.self
        ]) as! Set<AnyHashable>

        interface.setClasses(replyClasses, for: invokeSelector, argumentIndex: 0, ofReply: true)

        let handleClasses = NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>
        interface.setClasses(handleClasses, for: invokeSelector, argumentIndex: 4, ofReply: false)

        return interface
    }

    public static var status: NSXPCInterface {
        return NSXPCInterface(with: XPCFFmpegStatusProtocol.self)
    }
}
