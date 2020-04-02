//
//  XPCFFmegService.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//




// TODO: Look at @functionbuilder as a way of creating the arguments for filters, inputs, etc.
// Class subscripts?



import Foundation
//import SiliconInk_Helper


@objc public protocol XPCFFmegServiceProtocol {
    
    func invoke(request: String, completionHandler handler: @escaping (_ response: String?, _ log: String?, _ error: Error?) -> Void)
    
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ log: String?, _ error: Error?) -> Void)

    func invoke(request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ log: String?, _ error: Error?) -> Void)

}


class XPCFFmegService: NSObject, XPCFFmegServiceProtocol {
        
    
    func invoke(request: String, completionHandler handler: @escaping (_ response: String?, _ log: String?, _ error: Error?) -> Void) {
        invoke(request: request, globalOptions: [], inputs: [], filters: [], outputs: [], completionHandler: handler)
    }
        
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ log: String?, _ error: Error?) -> Void) {
        invoke(request: request, globalOptions: globalOptions, inputs: inputs, filters: [], outputs: outputs, completionHandler: handler)
    }
    
    func invoke(request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], completionHandler handler: @escaping (_ response: String?, _ log: String?, _ error: Error?) -> Void) {
        let stdOutPipe = Pipe()
        let stdOutPipeReader = PipeReader(stdOutPipe)
        
        let stdErrPipe = Pipe()
        let stdErrPipeReader = PipeReader(stdErrPipe)
        
        let ffmpegTask = Process()
        let xpcServicesPath = URL(fileURLWithPath: Bundle.main.executablePath!).deletingLastPathComponent()  // TODO: Fix the !
        ffmpegTask.executableURL = xpcServicesPath.appendingPathComponent("FFmpegTask3")
        ffmpegTask.arguments = [request] + globalOptions + inputs + filters + outputs
        ffmpegTask.standardOutput = stdOutPipe
        ffmpegTask.standardError = stdErrPipe
        
        ffmpegTask.terminationHandler = { process in
            // Handle error return code? Maybe not relevant if no error message is returned in StdErr
            let response: String? = stdOutPipeReader.data.isEmpty ? nil : String.init(data: stdOutPipeReader.data, encoding: .utf8)
            let log: String? = stdErrPipeReader.data.isEmpty ? nil : String.init(data: stdErrPipeReader.data, encoding: .utf8)
            handler(response, log, nil)
        }
        
        do {
            try ffmpegTask.run()
        } catch {
            handler(nil, nil, error)
        }
    }
    
}
