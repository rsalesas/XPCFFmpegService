//
//  FFmpegTaskProcess.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 7/4/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import SiliconInk_Helper
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


class FFmpegTaskProcess {
    
    typealias CompletionHandler = (_ response: Data?, _ log: Data?, _ error: Error?) -> Void
    
    public enum ExitCode : Int32 {
        case Success = 0
        case Failure = 1
        case InsufficientArguments = 2
        case InvalidArguments = 3
        case UnknownCommand = 4
        
        init (_ i: Int32) {
           self.init(rawValue: min(0, max(4, i)))!
        }
        
        var code: Int32 {
            return self.rawValue
        }
    }

    private let mutex = MutexSynchronized()
    private let process = Process()
    private let handler: CompletionHandler

    private let stdOutPipe: Pipe
    private let stdOutValidator: JSONStreamValidator
    
    private let stdErrPipe: Pipe
    private let stdErrValidator: JSONStreamValidator
    
    private var terminateFlag: Int32 = 0
    
    
    private func stdOutReadabilityHandler(fileHandle: FileHandle) {
        mutex.synchronize {
            os_log("FFmpegTaskProcess.stdOutReadabilityHandler")

            let availableData = fileHandle.availableData
            if availableData.isEmpty {
                os_log("  FFmpegTaskProcess.stdOutReadabilityHandler::nil")
                stdOutPipe.fileHandleForReading.readabilityHandler = nil
                return
            }

            os_log("  FFmpegTaskProcess.stdOutReadabilityHandler (%d)", availableData.count)
            stdOutValidator.append(data: availableData)
            if let error = stdOutRetrieveAndCallHandler() {
                terminate(error: error)
            }
        }
    }
    
    private func stdErrReadabilityHandler(fileHandle: FileHandle) {
        self.mutex.synchronize {
            os_log("FFmpegTaskProcess.stdErrReadabilityHandler")
            
            let availableData = fileHandle.availableData
            if availableData.isEmpty {
                os_log("  FFmpegTaskProcess.stdErrReadabilityHandler::nil")
                stdErrPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
    
            os_log("  FFmpegTaskProcess.stdErrReadabilityHandler (%d)", availableData.count)
            stdErrValidator.append(data: availableData)
            if let error = stdErrRetrieveAndCallHandler() {
                terminate(error: error)
            }
        }
    }
    
    private func stdOutRetrieveAndCallHandler() -> Error? {
        os_log("  FFmpegTaskProcess.stdOutRetrieveAndCallHandler")

        os_log("  %@", [String(data: stdOutValidator.data, encoding: .utf8)])
        
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
        os_log("  FFmpegTaskProcess.stdErrRetrieveAndCallHandler")

        os_log("  %@", [String(data: stdErrValidator.data, encoding: .utf8)])

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
        os_log("FFmpegTaskProcess.terminate")

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
        os_log("FFmpegTaskProcess.init")
        
        let xpcServicesPath = URL(fileURLWithPath: Bundle.main.executablePath ?! "Invalid state; unable to retrieve bundle executable path").deletingLastPathComponent()
        
        self.process.executableURL = xpcServicesPath.appendingPathComponent("FFmpegTask")
        self.handler = handler

        stdOutPipe = Pipe()
        stdOutValidator = JSONStreamValidator()
            
        stdErrPipe = Pipe()
        stdErrValidator = JSONStreamValidator()

        stdOutPipe.fileHandleForReading.readabilityHandler = stdOutReadabilityHandler
        self.process.standardOutput = stdOutPipe
        
        stdErrPipe.fileHandleForReading.readabilityHandler = stdErrReadabilityHandler
        self.process.standardError = stdErrPipe

        self.process.standardInput = nil
        
        
        // Use the terminate flag to allow the terminate function to make a hard exit request
        // Must not use [weak self] as it is released by caller immediately after "invoke".
        process.terminationHandler = { process in
            self.mutex.synchronize {
                os_log("FFmpegTaskProcess.init.terminationHandler")
                
                if process.terminationReason == .uncaughtSignal {
                    os_log("  FFmpegTaskProcess.init.terminationHandler->.uncaughtSignal")
                } else if process.terminationStatus != 0 {
                    os_log("  FFmpegTaskProcess.init.terminationHandler->.terminationStatus(%d)", process.terminationStatus)
                }
                
                // When the process terminates, set the flag
                OSAtomicIncrement32(&self.terminateFlag)
            }
        }
    }
    
    func invoke(arguments: [String]) {
        os_log("FFmpegTaskProcess.invoke")

        // TODO: May need to use NSException if arguments are wrong
        do {
            process.arguments = arguments
            try process.run()
        } catch {
            os_log("FFmpegTaskProcess.invoke, %@", error.localizedDescription)
            handler(nil, nil, error)
        }
    }
    
}
