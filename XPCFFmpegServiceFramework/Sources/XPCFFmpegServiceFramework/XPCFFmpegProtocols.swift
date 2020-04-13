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
    
    public init (exitCode: Int32) {
        if exitCode == 0 {
            fatalError("ServiceError cannot be created with exitCode value \"0\".")
        } else if exitCode < 1 || exitCode > 4 {
            fatalError("ServiceError can only be created with exitCode values between \"1\" and \"4\" inclusive.")
        } else {
            self.init(rawValue: exitCode)!
        }
    }
}

@objc public class FFmpegStatus: NSObject, Error, Codable {
    
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
    
    public var localizedDescription: String {
        return "The operation could not be completed (\(self.domain): \(self.message))"
    }

}

@objc public class FFmpegProgress: NSObject, Codable {
    var frame: Int
    var fps: Double
    var input: Int
    var stream: Int
    var quality: Double
    var bitrate: Double?
    var totalSize: Int?
    var outTime: TimeInterval?
    var duplicateFrames: Int
    var droppedFrames: Int
    var speed: Int?
    var finished: Bool
}

//@objc public class FFmpegVersion: NSObject, Codable {
//    public let version: String
//    public let compiler: String
//    public let ffmpegCopyright: String
//    public let configuration: String
//    public var libraries: [String : String] = [:]
//}

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
    }
    
    public required init?(coder: NSCoder) {
        version = coder.decodeObject(of: NSString.self, forKey: "version") as String? ?? ""
        compiler = coder.decodeObject(of: NSString.self, forKey: "compiler") as String? ?? ""
        ffmpegCopyright = coder.decodeObject(of: NSString.self, forKey: "ffmpegCopyright") as String? ?? ""
        configuration = coder.decodeObject(of: NSString.self, forKey: "configuration") as String? ?? ""
        libraries = [:]
    }
}


@objc public protocol XPCFFmpegStatusProtocol {

    func progress(progress: String)

}


@objc public protocol XPCFFmpegInvokeProtocol {
    
    func invoke(endpoint: NSXPCListenerEndpoint, request: String, reply handler: @escaping (CompletionHandler))
    
    func invoke(endpoint: NSXPCListenerEndpoint, request: String, globalOptions: [String], inputs: [String], outputs: [String], reply handler: @escaping (CompletionHandler))

    func invoke(endpoint: NSXPCListenerEndpoint, request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], reply handler: @escaping (CompletionHandler))

}


@objc public protocol XPCFFmpegServiceProtocol {
    

}



