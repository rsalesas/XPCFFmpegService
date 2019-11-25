//
//  main.swift
//  FFmpegTask-Swift
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
    static let FFmpegFlags = ["-hide_banner", "-stats", "-loglevel", "repeat+level+warning", "-nostdin"]
    static let FFmpegExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags"]

    static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal"]
    static let FFprobeExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags", "-byte_binary_prefix"]
        

    // Singleton - do not access this class in any other way.
    static let Application = FFmpegTask()
    
    let progressPipe = Pipe()
    
    let standardGroup = DispatchGroup()
    let defaultStandardOutputPipe = Pipe()
    let proxyStandardOutputPipe = Pipe()
    let defaultStandardErrorPipe = Pipe()
    let proxyStandardErrorPipe = Pipe()

    
    // Prepare the environment for calling the ffmpeg libraries
    private init() {
        // Disable colour output for the ffmpeg libraries
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1)

        // Prepare the progress code - used only for -ffmpeg mode, not -ffprobe mode
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
        
        // Prepare the exit handler to ensure that the above handles are all flushed and finished
        // In order for the C function closure to work, variables must be static, therefore this
        // is a 1:1 with the static "Application" singleton. This is needed as ffmpeg exits from
        // a billion places, seemingly randomly.
        atexit {
            do {
                FFmpegTask.Application.standardGroup.wait()
                
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
        standardGroup.enter()
        defer { standardGroup.leave() }
        
        let data = fileHandle.availableData
        defaultStandardOutputPipe.fileHandleForWriting.write(data)
    }
    
    func processProxyStandardErrorPipe(fileHandle: FileHandle) {
        standardGroup.enter()
        defer { standardGroup.leave() }

        let data = fileHandle.availableData
        defaultStandardErrorPipe.fileHandleForWriting.write(data)
    }
    
    func processProgress(fileHandle: FileHandle) {
        standardGroup.enter()
        defer { standardGroup.leave() }

        let data = fileHandle.availableData
        guard let message = String(data: data, encoding: .utf8),
            let progressRegEx = try? NSRegularExpression(pattern: #"(?<Name>^.*)=(?<Value>.*[^=]*)$"#, options:NSRegularExpression.Options.anchorsMatchLines) else {
            os_log("Unable to process progress information.")
            return
        }
        
        defaultStandardErrorPipe.fileHandleForWriting.write(data)

        let matches = progressRegEx.matches(in: message, options: [], range: NSMakeRange(0, message.count))
        
        matches.forEach { match in
            // ! is bad, except here it cannot fail if the RegEx is correct as the group names will match.
            let name = message[Range(match.range(withName: "Name"), in: message)!]
            let value = message[Range(match.range(withName: "Value"), in: message)!]
            print("Name: \(name)\nValue: \(value)")
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


exit(FFmpegTask.Application.processRequest(CommandLine.arguments))
