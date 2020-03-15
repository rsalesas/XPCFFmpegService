//
//  XPCFFmegService.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation

@objc public protocol XPCFFmegServiceProtocol {
    
    func invoke(request: String, completionHandler handler: @escaping (_ response: String?, _ error: String?) -> Void)
    
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ error: String?) -> Void)

    func invoke(request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ error: String?) -> Void)

}


/// Used to synchronize access to closures.
@inlinable
public func synchronized(_ lock: AnyObject, _ body: () throws -> Void) rethrows {
    objc_sync_enter(lock)
    defer { objc_sync_exit(lock) }
    try body()
}



class XPCFFmegService: NSObject, XPCFFmegServiceProtocol {
    
    private var standardOutputBuffer = Data(capacity: 4096)
    private var standardErrorBuffer = Data(capacity: 4096)

    private func appendStandardOutputToBuffer(fileHandle: FileHandle) {
        synchronized(fileHandle) {
            standardOutputBuffer.append(fileHandle.availableData)
        }
    }

    private func appendStandardErrorToBuffer(fileHandle: FileHandle) {
        synchronized(fileHandle) {
            standardErrorBuffer.append(fileHandle.availableData)
        }
    }

    
    func invoke(request: String, completionHandler handler: @escaping (_ response: String?, _ error: String?) -> Void) {
        invoke(request: request, globalOptions: [], inputs: [], filters: [], outputs: [], completionHandler: handler)
    }
        
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ error: String?) -> Void) {
        invoke(request: request, globalOptions: globalOptions, inputs: inputs, filters: [], outputs: outputs, completionHandler: handler)
    }
    
    func invoke(request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ error: String?) -> Void) {
        let standardOutputPipe = Pipe()
        standardOutputPipe.fileHandleForReading.readabilityHandler = appendStandardOutputToBuffer
        
        let standardErrorPipe = Pipe()
        standardErrorPipe.fileHandleForReading.readabilityHandler = appendStandardErrorToBuffer
        
        let ffmpegTask = Process()
        let xpcServicesPath = URL(fileURLWithPath: Bundle.main.executablePath!).deletingLastPathComponent()  // TODO: Fix the !
        ffmpegTask.executableURL = xpcServicesPath.appendingPathComponent("FFmpegTask")
        ffmpegTask.arguments = [request] + globalOptions + inputs + filters + outputs
        ffmpegTask.standardOutput = standardOutputPipe
        ffmpegTask.standardError = standardErrorPipe
        
        ffmpegTask.terminationHandler = { process in
            // Handle error return code? Maybe not relevant if no error message is returned in StdErr
            let response = self.standardOutputBuffer.count == 0 ? nil : String.init(data: self.standardOutputBuffer, encoding: .utf8)
            let error = self.standardErrorBuffer.count == 0 ? nil : String.init(data: self.standardErrorBuffer, encoding: .utf8)
            handler(response, error)
        }
        
        do {
            try ffmpegTask.run()
        } catch {
            handler(nil, error.localizedDescription)
        }
    }
    
}
