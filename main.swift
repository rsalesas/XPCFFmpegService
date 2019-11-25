//
//  main.swift
//  FFmpegTask-Swift
//
//  Created by Robert Salesas on 24/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//

import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j
//            os_log("Insufficent arguments – %@", CommandLine.arguments)


class FFmpegTask {
    
    // Flags for running processes  // TODO: make it "nostats"
    static let FFmpegFlags = ["-hide_banner", "-stats", "-loglevel", "repeat+level+warning", "-nostdin"]
    static let FFmpegExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags"]

    static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal"]
    static let FFprobeExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags", "-byte_binary_prefix"]
        

    static let Application = FFmpegTask()
    
    let progressPipe = Pipe()
    let defaultStandardOutputPipe = Pipe()
    let proxyStandardOutputPipe = Pipe()
    let defaultStandardErrorPipe = Pipe()
    let proxyStandardErrorPipe = Pipe()

    // Prepare the environment for calling the ffmpeg libraries
    private init() {
        // Disable colour output for the ffmpeg libraries
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1)

        // Prepare the progress code
         progressPipe.fileHandleForReading.readabilityHandler = processProgress
        
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
        
        // To reset it back to the default stderr handle use the following:
        // dup2(defaultStandardErrorPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardError.fileDescriptor)
    }
        
    // Error output
    private enum ErrorType: String {
        case error = "[Error]"
        case warning = "[Warning]"
    }
    
    // TODO: Convert this to output JSON to original StdErr
    private func printError(_ message: String, error: FFmpegTask.ErrorType = FFmpegTask.ErrorType.error) {
        let messageLn = error.rawValue + " " + message + "\n"
        if let data = messageLn.data(using: .utf8)  {
            FileHandle.standardError.write(data)
        }
    }
    
    func processProxyStandardOutputPipe(fileHandle: FileHandle) {
        let data = fileHandle.availableData
        defaultStandardOutputPipe.fileHandleForWriting.write(data)
        sleep(5)
    }
    
    func processProxyStandardErrorPipe(fileHandle: FileHandle) {
        let data = fileHandle.availableData
        defaultStandardErrorPipe.fileHandleForWriting.write(data)
    }
    
    func processProgress(fileHandle: FileHandle) {
        let data = fileHandle.availableData
        guard let message = String(data: data, encoding: .utf8),
            let progressRegEx = try? NSRegularExpression(pattern: #"^.*=.*[^=]*$"#, options:NSRegularExpression.Options.anchorsMatchLines) else {
            os_log("Unable to process progress information.")
            return
        }
        
        defaultStandardErrorPipe.fileHandleForWriting.write(data)

        let matches = progressRegEx.matches(in: message, options: [], range: NSMakeRange(0, message.count))
        matches.forEach { match in
            print("Match: \(match)")
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
                ["-progress", "pipe:\(progressPipe.fileHandleForWriting.fileDescriptor)"]

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

var exitCode = FFmpegTask.Application.processRequest(CommandLine.arguments)
sleep(5)
exit(exitCode)
