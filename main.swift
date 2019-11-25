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


// TODO: Consider using freopen to override stderr / stdout and do the processing here, returning only JSON through the original values (which will need to be saved here)
// Might be possible to open a new pipe for progress and send it there "pipe:5" for example, then listen to it and convert the progress to a JSON output on STDOUT

class FFmpegTask {
    
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
        
        // Copy the current stderr to the default stderr pipe for holding
        dup2(FileHandle.standardError.fileDescriptor, defaultStandardErrorPipe.fileHandleForWriting.fileDescriptor)
        
        // Reset stderr to the proxy stderr pipe to allow intercepting and redirect to processor
        dup2(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardError.fileDescriptor)
        proxyStandardErrorPipe.fileHandleForReading.readabilityHandler = processProgress
    }
        
    // Flags for running processes
    static let FFmpegFlags = ["-hide_banner", "-nostats", "-loglevel", "repeat+level+warning", "-nostdin"]
    static let FFmpegExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags"]

    static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal"]
    static let FFprobeExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags", "-byte_binary_prefix"]
        
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
    
    func processProgress(fileHandle: FileHandle) {
        let data = fileHandle.availableData
        print("Print Progress:\n\n" + (String(data: data, encoding: .utf8) ?? ""))
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
                //["-progress", "pipe:\(progressPipe.fileHandleForWriting.fileDescriptor)"]
                ["-progress", "pipe:2"]

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

exit(FFmpegTask.Application.processRequest(CommandLine.arguments))
