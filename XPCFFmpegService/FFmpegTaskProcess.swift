//
//  FFmpegTaskProcess.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 7/4/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import SiliconInk_Helper
import XPCFFmpegServiceFramework

import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j




class FFmpegTaskProcess {
    
    public typealias CompletionHandler = (_ result: ServiceResult) -> Void

    private struct StandardErrorResponse: Codable {
        let status: FFmpegStatus?
        let progress: FFmpegProgress?
    }
    
    public struct StandardOutputResponse: Codable {
        let version: FFmpegVersion?
    }

        
    private let mutex = MutexSynchronized()
    private let process = Process()
    private let handler: CompletionHandler
    private let statusService: XPCFFmpegStatusProtocol

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
            
            stdOutValidator.forEach { data in
                if let response = try? JSONDecoder().decode(StandardOutputResponse.self, from: data) {
                    if let ffmpegVersion = response.version {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->FFmpegProgress")
//                        handler(.success(ffmpegVersion))
                        handler(.success("Success!"))
                    
                    } else if data.isEmptyJSON {
                        
                    } else if let json = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) {
                        handler(.success(json))
                        
                    } else {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->InvalidJSON")
                        terminateWithError(error: ServiceError.invalidResponse)
                    }

                }
            }
            
            if let error = stdOutValidator.error, error == .invalid {
                terminateWithError(error: ServiceError.invalidResponse)
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
            
            stdErrValidator.forEach { data in
                assert(data.isValidJSON, "Invalid JSON received from FFmpegTask on StandardError.")
                if let response = try? JSONDecoder().decode(StandardErrorResponse.self, from: data) {
                    if let ffmpegProgress = response.progress {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->FFmpegProgress")
                        statusService.progress(progress: ffmpegProgress.debugDescription)

                    } else if let ffmpegStatus = response.status {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->FFmpegStatus")
                        statusService.progress(progress: ffmpegStatus.debugDescription)

                    } else if !data.isEmptyJSON {
                        os_log("    FFmpegTaskProcess.stdErrRetrieveAndCallHandler->InvalidResponse")
                        terminateWithError(error: ServiceError.invalidResponse)
                    }

                }
            }
            
            if let error = stdErrValidator.error, error == .invalid {
                terminateWithError(error: ServiceError.invalidResponse)
            }
        }
    }

    // The ffmpeg code MAY require FOUR (4) signals to be sent for a hard exit
    func terminateWithError(error: ServiceError, allowHardExit: Bool = false) {
        os_log("FFmpegTaskProcess.terminate")

        process.terminate()
        handler(.failure(error))

        if allowHardExit, usleep(250_000) == 0 {  // sleep for 0.25 seconds
            if OSAtomicIncrement32(&self.terminateFlag) == 1 {
                for _ in 0...2 {
                    process.terminate()
                }
            }
        }
    }
    
    init(statusService: XPCFFmpegStatusProtocol, completionHandler handler: @escaping CompletionHandler) {
        os_log("FFmpegTaskProcess.init")
                
        self.handler = handler
        self.statusService = statusService
        
        let xpcServicesPath = URL(fileURLWithPath: Bundle.main.executablePath ?! "Invalid state; unable to retrieve bundle executable path").deletingLastPathComponent()
        self.process.executableURL = xpcServicesPath.appendingPathComponent("FFmpegTask")

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
                    self.handler(.failure(ServiceError.uncaughtSignal))
                } else if process.terminationStatus != 0 {
                    os_log("  FFmpegTaskProcess.init.terminationHandler->.terminationStatus(%d)", process.terminationStatus)
                    if process.terminationStatus >= 1 {
                        self.handler(.failure(ServiceError(exitCode: process.terminationStatus)))
                    }
                }
                
                // When the process terminates, set the flag
                OSAtomicIncrement32(&self.terminateFlag)
            }
        }
    }
    
    func invoke(arguments: [String]) {
        os_log("FFmpegTaskProcess.invoke")

        do {
            // TODO: Remove this - looks like it doesn't like starting to send on a callback...
            statusService.progress(progress: "REMOVE THIS: FFmpegTaskProcess.init")

            process.arguments = arguments
            try process.run()

        } catch {
            os_log("FFmpegTaskProcess.invoke, error: %@", error.localizedDescription)
            handler(.failure(ServiceError.unableToInvoke))
        }
    }
    
}
