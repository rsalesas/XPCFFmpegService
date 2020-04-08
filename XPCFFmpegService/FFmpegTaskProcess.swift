//
//  FFmpegTaskProcess.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 7/4/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import SiliconInk_Helper


class FFmpegTaskProcess {
    
    typealias CompletionHandler = (_ response: Data?, _ log: Data?, _ error: Error?) -> Void
    
    private let process = Process()
    private let handler: CompletionHandler

    private let stdOutPipe = Pipe()
    private let stdOutValidator = JSONStreamValidator()
    private let stdErrPipe = Pipe()
    private let stdErrValidator = JSONStreamValidator()
    
    private var terminateFlag: Int32 = 0
    
    
    private func stdOutReadabilityHandler(fileHandle: FileHandle) {
        let availableData = fileHandle.availableData
        if availableData.isEmpty {
            stdOutPipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        
        stdOutValidator.append(data: availableData)
        if let error = stdOutRetrieveAndCallHandler() {
            terminate(error: error)
        }
    }
    
    private func stdErrReadabilityHandler(fileHandle: FileHandle) {
        let availableData = fileHandle.availableData
        if availableData.isEmpty {
            stdErrPipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        stdErrValidator.append(data: availableData)
        if let error = stdErrRetrieveAndCallHandler() {
            terminate(error: error)
        }
    }
    
    private func stdOutRetrieveAndCallHandler() -> Error? {
        stdOutValidator.forEach { data in
            if data.isValidJSON {
                handler(data, nil, nil)
            }
        }
        
        if let error = stdOutValidator.error, error == .invalid {
            return error
        }
        
        return nil
    }
    
    private func stdErrRetrieveAndCallHandler() -> Error?  {
        stdOutValidator.forEach { data in
            if data.isValidJSON {
                handler(nil, data, nil)
            }
        }
        
        if let error = stdErrValidator.error, error == .invalid {
            return error
        }
        
        return nil
    }

    // The ffmpeg code appears to require FOUR (4) signals to be sent for a hard exit
    func terminate(error: Error? = nil, allowHardExit: Bool = false) {
        process.terminate()
        handler(nil, nil, error)

        if allowHardExit, usleep(250_000) == 0 {  // sleep for 0.25 seconds
            if OSAtomicIncrement32(&self.terminateFlag) == 1 {
                for _ in 0...2 {
                    process.terminate()
                }
            }
        }
    }
    
    init(completionHandler handler: @escaping CompletionHandler) {
        let xpcServicesPath = URL(fileURLWithPath: Bundle.main.executablePath ?! "Invalid state; unable to retrieve bundle executable path").deletingLastPathComponent()

        self.process.executableURL = xpcServicesPath.appendingPathComponent("FFmpegTask")
        self.handler = handler

        stdOutPipe.fileHandleForReading.readabilityHandler = stdOutReadabilityHandler
        self.process.standardOutput = stdOutPipe
        
        stdErrPipe.fileHandleForReading.readabilityHandler = stdErrReadabilityHandler
        self.process.standardError = stdErrPipe
        
        // Use the terminate flag to allow the terminate function to make a hard exit request
        // Must not use [weak self] as it is released by caller immediately after "invoke".
        process.terminationHandler = { process in
            // When the process terminates, set the flag            
            OSAtomicIncrement32(&self.terminateFlag)
        }
    }
    
    func invoke(arguments: [String]) {
        do {
            process.arguments = arguments
            try process.run()
        } catch {
            handler(nil, nil, error)
        }
    }
    
}
