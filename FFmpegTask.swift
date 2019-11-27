//
//  FFmpegTask.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 24/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  This is a wrapper around the ffmpeg and ffprobe (and possibly one day ffplay) programs.
//  It sets certain options to control output, and intercept it before passing it to the calling
//  program (meant to be an XPC service) in JSON format.
//

import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


// This class is a non-thread safe singleton - be careful!
class FFmpegTask {
    
    // Flags for running processes  // TODO: make it "nostats"
    private static let FFmpegFlags = ["-hide_banner", "-nostats", "-loglevel", "repeat+level+info", "-nostdin"]
    private static let FFmpegExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags"]

    private static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal"]
    private static let FFprobeExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags", "-byte_binary_prefix"]
    
    // RegEx pattern to use to parse errors
    private static let Pattern = #""#
            
    // Singleton - do not access this class in any other way.
    static let Application = FFmpegTask()
        
    private let exitGroup = DispatchGroup()
    private let defaultStandardOutputPipe = Pipe()
    private let proxyStandardOutputPipe = Pipe()
    private let defaultStandardErrorPipe = Pipe()
    private let proxyStandardErrorPipe = Pipe()
    
    private let progressProcessor: ProgressProcessor

    
    // Prepare the environment for calling the ffmpeg libraries
    private init() {
        // Disable colour output for the ffmpeg libraries
        unsetenv("AV_LOG_FORCE_COLOR")
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1)
        
        // Prepare the progress processor
        progressProcessor = ProgressProcessor(defaultStdErr: defaultStandardErrorPipe.fileHandleForWriting, exitGroup: exitGroup)
        
        // Copy the current std to the default std pipe for holding
        dup2(FileHandle.standardOutput.fileDescriptor, defaultStandardOutputPipe.fileHandleForWriting.fileDescriptor)
        dup2(FileHandle.standardError.fileDescriptor, defaultStandardErrorPipe.fileHandleForWriting.fileDescriptor)

        // Reset std to the proxy std pipe to allow intercepting and redirect to processor
        dup2(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
        proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processProxyStandardOutputPipe
        dup2(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardError.fileDescriptor)
        proxyStandardErrorPipe.fileHandleForReading.readabilityHandler = processProxyStandardErrorPipe
        
        // Set stdin to stdnull - just in case - the trick above could be used with stdin for IPC if needed
        dup2(FileHandle.nullDevice.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
        
        // Prepare the exit handler to ensure that the above handles are all flushed and finished
        // In order for the C function closure to work, variables must be static, therefore this
        // is a 1:1 with the static "Application" singleton. This is needed as ffmpeg exits from
        // a billion places, seemingly randomly.
        //
        // WARNING: This must be the first registered closure, otherwise flushing will not succeed.
        atexit {
            do {
                // Wait for any activities to complete
                FFmpegTask.Application.exitGroup.wait()
                
                // Flush out any pending output
                try FFmpegTask.Application.defaultStandardOutputPipe.fileHandleForWriting.synchronize()
                try FFmpegTask.Application.defaultStandardErrorPipe.fileHandleForWriting.synchronize()
            }
            catch {
                os_log("Unable to flush stdout and stderr filehandles")
            }
        }
    }
        
    // Error output
    private enum ErrorType: String {
        case error = "error"
        case warning = "warning"
    }
    
    // TODO: Convert this to output JSON to original StdErr
    private func printError(_ message: String, error: FFmpegTask.ErrorType = FFmpegTask.ErrorType.error) {
        let messageLn = "{\"\(error.rawValue)\":\"\(message)\"}\n"
        if let data = messageLn.data(using: .utf8)  {
            defaultStandardErrorPipe.fileHandleForWriting.write(data)
        }
    }
    
    func processProxyStandardOutputPipe(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        let data = fileHandle.availableData
        defaultStandardOutputPipe.fileHandleForWriting.write(data)
    }
    
    func processProxyStandardErrorPipe(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }

        // let data = fileHandle.availableData
        // defaultStandardErrorPipe.fileHandleForWriting.write(data)
        
        let data = fileHandle.availableData
        guard let message = String(data: data, encoding: .utf8) else {
            os_log("Unable to process stderr output.")
            return
        }
    }
        
    func processRequest(_ arguments: [String]) -> Int32 {
        // Ensure there is at least the minimum number of arguments - this ensures the checks below don't failw
        if arguments.count < 5 {
            printError("Insufficent arguments \(arguments)")
            return EXIT_FAILURE
        }
                               
        // Check the request to determine what service to call
        var args = arguments
        if args[1] == "-ffmpeg" {
            // prepare the arguments for ffmpeg
            args = [args[0]] + (args[2...args.count-1]).filter { !FFmpegTask.FFmpegExcludeFlags.contains($0) } + FFmpegTask.FFmpegFlags +
                ["-progress", "pipe:\(progressProcessor.fileDescriptor)"]

            // Call the C function with the arguments
            var cargs = args.map { strdup($0) }
            return ffmpeg(Int32(cargs.count), &cargs)
            
        } else if args[1] == "-ffprobe" {
            // Prepare the arguments for ffprobe
            args = [args[0]] + (args[2...args.count-1]).filter { !FFmpegTask.FFprobeExcludeFlags.contains($0) } + FFmpegTask.FFprobeFlags
            
            // Call the C function with the arguments
            var cargs = args.map { strdup($0) }
            return ffprobe(Int32(cargs.count), &cargs)
            
        } else {
            printError("No request provided. Please specify -ffmpeg or -ffprobe.")
            return EXIT_FAILURE
        }
    }
}
