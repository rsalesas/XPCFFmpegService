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


// Originally tested instead of using "atexit" - would have required a longjmp out however
//@_cdecl("ffmpegTaskAtExit")
//func AtExit() {
//    fputs("hello from ffmpegTaskAtExit\n", stderr)
//    fflush(stderr)
//}

/// Used to synchronize access to closures.
@inlinable
public func synchronized(_ lock: AnyObject, _ body: () throws -> Void) rethrows {
    objc_sync_enter(lock)
    defer { objc_sync_exit(lock) }
    try body()
}


// This class is a non-thread safe singleton - be careful!
public class FFmpegTask {
    
    // Singleton - do not access this class in any other way.
    public static let Application = FFmpegTask()
    
    // Flags for running processes
    private static let ValidRequests = ["-ffmpeg", "-ffprobe", "-license", "-version", "-protocols", "-formats", "-muxers", "-demuxers", "-devices", "-bsfs",
                                        "-codecs", "-decoders", "-sample_fmts", "-colors", "-pix_fmts", "-layouts", "-filters"]
    private static let FFmpegFlags = ["-hide_banner", "-nostats", "-loglevel", "repeat+level+warning", "-nostdin"]
    private static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal", "-noshow_private_data", ]
    private static let InvalidFlags = ["-version", "-L", "-h", "-?", "-help", "--help", "-cpuflags", "-sources", "-sinks", "-byte_binary_prefix", "-show_private_data",
                                       "-license", "-version", "-protocols", "-formats", "-muxers", "-demuxers", "-devices", "-bsfs",
                                       "-codecs", "-decoders", "-sample_fmts", "-colors", "-pix_fmts", "-layouts", "-filters"]
    
    // Null terminator for calling main(argc, argv)
    //private static let NullTerminator = [UnsafeMutablePointer<Int8>(0)]
    private static let NewlineMarker = Data(bytes: [0x0A], count: 1)
    private static var NullTerminator = [UnsafeMutablePointer<Int8>.allocate(capacity: 1)]
    
    private let defaultStandardOutputPipe = Pipe()
    private let proxyStandardOutputPipe = Pipe()
    private let defaultStandardErrorPipe = Pipe()
    private let proxyStandardErrorPipe = Pipe()
    
    private var standardOutputBuffer = Data(capacity: 4096)
    private var outputHandlerType: FFmpegOutputHandler.Type?
    private let progressHandler: ProgressHandler
    
    
    private func registerOutputHandler(handler: FFmpegOutputHandler.Type) {
        precondition(outputHandlerType == nil, "There is already an output handler registered.")
        
        outputHandlerType = handler
        proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = appendProxyStandardOutputToBuffer
    }
    
    
    // Prepare the environment for calling the ffmpeg libraries
    private init() {
        // Disable colour output for the ffmpeg libraries
        unsetenv("AV_LOG_FORCE_COLOR")
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1)
        
        // Prepare the progress processor - this should be moved only to the one call to ffmpeg
        progressHandler = ProgressHandler(defaultStdErr: defaultStandardErrorPipe.fileHandleForWriting)
        
        // Copy the current std to the default std pipe for holding
        dup2(FileHandle.standardOutput.fileDescriptor, defaultStandardOutputPipe.fileHandleForWriting.fileDescriptor)
        dup2(FileHandle.standardError.fileDescriptor, defaultStandardErrorPipe.fileHandleForWriting.fileDescriptor)
        
        // Reset std to the proxy std pipe to allow intercepting and redirect to processor and enable line buffering
        dup2(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
        setlinebuf(fdopen(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, "w"))
        
        dup2(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardError.fileDescriptor)
        proxyStandardErrorPipe.fileHandleForReading.readabilityHandler = processProxyStandardError
        setlinebuf(fdopen(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, "w"))
        
        // Set stdin to stdnull - just in case - the trick above could be used with stdin for IPC if needed
        dup2(FileHandle.nullDevice.fileDescriptor, FileHandle.standardInput.fileDescriptor)
        
        // Prepare the exit handler to ensure that the above handles are all flushed and finished
        // In order for the C function closure to work, variables must be static, therefore this
        // is a 1:1 with the static "Application" singleton. This is needed as ffmpeg exits from
        // a billion places.
        //
        // WARNING: This must be the first registered closure, otherwise flushing will not succeed.
        atexit {
            // Close stdout and stderr and process any pending data  // TODO: Should we do the progress processor too?
            synchronized(FFmpegTask.Application) {
                FFmpegTask.Application.proxyStandardOutputPipe.fileHandleForWriting.closeFile()
                FileHandle.standardOutput.closeFile()
                FFmpegTask.Application.proxyStandardErrorPipe.fileHandleForWriting.closeFile()
                FileHandle.standardError.closeFile()
                
                FFmpegTask.Application.processProxyStandardOutput(fileHandle: FFmpegTask.Application.proxyStandardOutputPipe.fileHandleForReading)
                FFmpegTask.Application.processProxyStandardError(fileHandle: FFmpegTask.Application.proxyStandardErrorPipe.fileHandleForReading)

                FFmpegTask.Application.progressHandler.processLastProgress()
            }
        }
    }
    
    // Output an error message in json format "{type:error,description:message}" escaping slashes and quotes
    private func printError(_ message: String) {
        let escapedMessage = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")  // TODO: Enumerate and append to a buffer
        let jsonError = "{\"type\":\"error\",\"description\":\"\(escapedMessage)\"}"
        
        guard let jsonData = jsonError.data(using: .utf8) else {
            fatalError("Unable to output json object.")
        }
        
        defaultStandardErrorPipe.fileHandleForWriting.write(jsonData)
        defaultStandardErrorPipe.fileHandleForWriting.write(FFmpegTask.NewlineMarker)
        defaultStandardErrorPipe.fileHandleForWriting.synchronizeFile()
    }
    
    // Output an error message in json format "{type:error,description:message}"
    // This method is a bit different in that it prints each processed error separately
    private func processProxyStandardError(fileHandle: FileHandle) {
        synchronized(FFmpegTask.Application) {
            let data = fileHandle.availableData
            if !data.isEmpty, let error = FFmpegError(from: data) {
                error.errors.forEach { error in
                    if let jsonData = error.toJSONData() {
                        defaultStandardErrorPipe.fileHandleForWriting.write(jsonData)
                        defaultStandardErrorPipe.fileHandleForWriting.write(FFmpegTask.NewlineMarker)
                        defaultStandardErrorPipe.fileHandleForWriting.synchronizeFile()
                    }
                }
            }
        }
    }
    
    private func appendProxyStandardOutputToBuffer(fileHandle: FileHandle) {
        synchronized(FFmpegTask.Application) {
            standardOutputBuffer.append(fileHandle.availableData)
        }
    }

    private func processProxyStandardOutput(fileHandle: FileHandle) {
        synchronized(FFmpegTask.Application) {
            standardOutputBuffer.append(fileHandle.availableData)
            
            if !standardOutputBuffer.isEmpty, let outputHandlerType = outputHandlerType {
                guard let outputHandler = outputHandlerType.init(from: standardOutputBuffer), let jsonData = outputHandler.toJSONData() else {
                    os_log("Invalid ffmpeg output; unexpected format", type: OSLogType.error)
                    return
                }

                defaultStandardOutputPipe.fileHandleForWriting.write(jsonData)
                defaultStandardOutputPipe.fileHandleForWriting.write(FFmpegTask.NewlineMarker)
                defaultStandardOutputPipe.fileHandleForWriting.synchronizeFile()
            }
        }
    }

    // Passes the data through. Special cases are dealt with in separate functions, this assumes the results are in json (or readable in some manner)
    private func passthroughProxyStandardOutput(fileHandle: FileHandle) {
        synchronized(FFmpegTask.Application) {
            let data = fileHandle.availableData
            if !data.isEmpty {
                defaultStandardOutputPipe.fileHandleForWriting.write(data)
                defaultStandardOutputPipe.fileHandleForWriting.synchronizeFile()
            }
        }
    }
    
    private func invokeFFmpeg(argument: String) -> Int32 {
        return invokeFFmpeg(arguments: [argument])
    }
    
    private func invokeFFmpeg(arguments: [String]) -> Int32 {
        let args = [CommandLine.arguments[0]] + FFmpegTask.FFmpegFlags + arguments
        var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
        return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator
    }
        
    private func invokeFFprobe(argument: String) -> Int32 {
        return invokeFFprobe(arguments: [argument])
    }
    
    private func invokeFFprobe(arguments: [String]) -> Int32 {
        let args = [CommandLine.arguments[0]] + FFmpegTask.FFprobeFlags + arguments
        var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
        return ffprobe(Int32(cargs.count - 1), &cargs)  // Minus null terminator
    }
        
    public func processRequest(_ arguments: [String]) -> Int32 {
        // Ensure there is at least the minimum number of arguments - this ensures the checks below don't fail
        if arguments.count <= 1 {
            printError("Insufficent arguments")
            return EXIT_FAILURE
        }
        
        // Retrieve the request type and validate against request list
        let request = arguments[1]
        if !FFmpegTask.ValidRequests.contains(request) {
            printError("No valid request provided. Must be one of \(FFmpegTask.ValidRequests)")
            return EXIT_FAILURE
        }
        
        // Check the request to determine what service to call
        switch request {
        case "-license":
            registerOutputHandler(handler: FFmpegLicense.self)
            return invokeFFmpeg(argument: "-L")
            
        case "-version":
            registerOutputHandler(handler: FFmpegVersion.self)
            return invokeFFmpeg(argument: request)
            
        case "-protocols":
            registerOutputHandler(handler: FFmpegProtocols.self)
            return invokeFFmpeg(argument: request)
            
        case "-formats", "-muxers", "-demuxers", "-devices":
            registerOutputHandler(handler: FFmpegFormats.self)
            return invokeFFmpeg(argument: request)
        
        case "-bsfs":
            registerOutputHandler(handler: FFmpegBitstreamFilters.self)
            return invokeFFmpeg(argument: request)
            
        case "-codecs":
            registerOutputHandler(handler: FFmpegCodecs.self)
            return invokeFFmpeg(argument: request)
            
        case "-decoders":
            registerOutputHandler(handler: FFmpegDecoders.self)
            return invokeFFmpeg(argument: request)
            
        case "-sample_fmts":
            registerOutputHandler(handler: FFmpegSampleFormats.self)
            return invokeFFmpeg(argument: request)
            
        case "-colors":
            registerOutputHandler(handler: FFmpegColors.self)
            return invokeFFmpeg(argument: request)
            
        case "-pix_fmts":
            registerOutputHandler(handler: FFmpegPixelFormats.self)
            return invokeFFmpeg(argument: request)
            
        case "-layouts":
            registerOutputHandler(handler: FFmpegLayouts.self)
            return invokeFFmpeg(argument: request)
            
        case "-filters":
            registerOutputHandler(handler: FFmpegFilters.self)
            return invokeFFmpeg(argument: request)
            
        default:
            // Ensure we have sufficient arguments for ffmpeg and ffprobe
            if arguments.count <= 2 {
                printError("Insufficent arguments for request \"\(request)\"")
                return EXIT_FAILURE
            }
            
            // Create an array of strings with arguments minus the application and request
            let newArguments: [String] = Array(arguments[2...])
            
            // Check arguments and fail if an invalid flag is passed - rudimentary but it works
            let invalidFlags = newArguments.filter({ FFmpegTask.InvalidFlags.contains($0) })
            if !invalidFlags.isEmpty {
                printError("Invalid arguments for request \"\(request)\": \(invalidFlags)")
                return EXIT_FAILURE
            }
            
            // Check the request to determine what service to call
            if request == "-ffmpeg" {
                proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = passthroughProxyStandardOutput
                return invokeFFmpeg(arguments: ["-progress", "pipe:\(progressHandler.fileDescriptor)"] + newArguments)
                
            } else if request == "-ffprobe" {
                proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = passthroughProxyStandardOutput
                return invokeFFprobe(arguments: newArguments)
                
            }
        }
           
        return EXIT_FAILURE
    }
}
