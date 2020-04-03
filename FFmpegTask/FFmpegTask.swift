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
import SiliconInk_Helper
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


// This class is a non-thread safe singleton - be careful!
public class FFmpegTask {
    
    public enum ExitCodes : Int32 {
        case Success = 0
        case Failure = 1
        case InsufficientArguments = 2
        case InvalidArguments = 3
        case UnknownCommand = 4
        
        init (_ i: Int32) {
            self.init(rawValue: min(0, max(3, i)))!
        }
        
        var code: Int32 {
            return self.rawValue
        }
    }
    
    // Singleton - do not access this class in any other way.
    public static let Application = FFmpegTask()

    // Flags for running processes
    private static let ValidRequests = ["-ffmpeg", "-ffprobe", "-license", "-version", "-protocols", "-formats", "-muxers", "-demuxers", "-devices", "-bsfs",
                                        "-codecs", "-decoders", "-sample_fmts", "-colors", "-pix_fmts", "-layouts", "-filters"]
    private static let FFmpegFlags = ["-hide_banner", "-nostats", "-loglevel", "repeat+level+warning", "-nostdin"]
    private static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal", "-noshow_private_data", ]
    private static let InvalidFlags = ["-version", "-L", "-h", "-?", "-help", "--help", "-cpuflags", "-sources", "-sinks", "-byte_binary_prefix",
                                       "-license", "-version", "-protocols", "-formats", "-muxers", "-demuxers", "-devices", "-bsfs",
                                       "-codecs", "-decoders", "-sample_fmts", "-colors", "-pix_fmts", "-layouts", "-filters",
                                       /* Disable non complex filters */ "-filter", "-vf", "-af"]
    
    // Null terminator for calling main(argc, argv)
    private static var NullTerminator = [UnsafeMutablePointer<Int8>.allocate(capacity: 1)]
    
    private let defaultStandardOutputPipe = Pipe()
    private let proxyStandardOutputPipe = Pipe()
    private let defaultStandardErrorPipe = Pipe()
    private let proxyStandardErrorPipe = Pipe()
        
    private var stdOutConnector: PipeConnector?
    private var stdErrConnector: PipeConnector?
    
    private let progressPipe = Pipe()
    private var progressConnector: PipeConnector?
        
    
    // Prepare the environment for calling the ffmpeg libraries
    private init() {
        // Disable colour output for the ffmpeg libraries
        unsetenv("AV_LOG_FORCE_COLOR")
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1)
        
        // Copy the current std to the default std pipe for holding
        dup2(FileHandle.standardOutput.fileDescriptor, defaultStandardOutputPipe.fileHandleForWriting.fileDescriptor)
        dup2(FileHandle.standardError.fileDescriptor, defaultStandardErrorPipe.fileHandleForWriting.fileDescriptor)
        
        // Reset std to the proxy std pipe to allow intercepting and redirect to processor
        dup2(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
        setlinebuf(fdopen(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, "w"))
        
        dup2(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardError.fileDescriptor)
        setlinebuf(fdopen(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, "w"))
        
        // Set stdin to stdnull - just in case - the trick above could be used with stdin for IPC if needed
        dup2(FileHandle.nullDevice.fileDescriptor, FileHandle.standardInput.fileDescriptor)
        
        // Prepare the exit handler to ensure that the above handles are all flushed and finished
        // In order for the C function closure to work, variables must be static, therefore this is
        // a 1:1 with the static "Application" singleton. This is needed as ffmpeg exits everywhere.
        //
        // WARNING: This must be the first registered closure, otherwise flushing will not succeed.

        atexit {
            if let stdOutConnector = FFmpegTask.Application.stdOutConnector {
                stdOutConnector.close()
            }
            
            if let progressConnector = FFmpegTask.Application.progressConnector {
                progressConnector.close()
            }
            
            if let stdErrConnector = FFmpegTask.Application.stdErrConnector {
                stdErrConnector.close()
            }
        }
    }

    private func invokeFFmpeg(argument: String, handler: FFmpegOutputHandler.Type? = nil) -> ExitCodes {
        return invokeFFmpeg(arguments: [argument], handler: handler)
    }
    
    private func invokeFFmpeg(arguments: [String], handler: FFmpegOutputHandler.Type? = nil) -> ExitCodes {
        stdOutConnector = PipeConnector(read: proxyStandardOutputPipe, write: defaultStandardOutputPipe, flush: FileHandle.standardOutput, relayMode: .end, outputHandlerType: handler)
        stdErrConnector = PipeConnector(read: proxyStandardErrorPipe, write: defaultStandardErrorPipe, flush: FileHandle.standardError, relayMode: .line, outputHandlerType: FFmpegError.self)

        progressConnector = PipeConnector(read: progressPipe, write: defaultStandardErrorPipe, relayMode: .terminators, outputHandlerType: FFmpegProgress.self)

        let args = [CommandLine.arguments[0]] + FFmpegTask.FFmpegFlags +
            ["-progress", "pipe:\(progressPipe.fileHandleForWriting.fileDescriptor)"] + arguments
        var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator  // TODO: Look at String.utf8CString
        return ExitCodes(ffmpeg(Int32(cargs.count - 1), &cargs))  // Minus null terminator
    }
        
    private func invokeFFprobe(arguments: [String]) -> ExitCodes {
        stdOutConnector = PipeConnector(read: proxyStandardOutputPipe, write: defaultStandardOutputPipe, flush: FileHandle.standardOutput, relayMode: .end)  // Passthrough all output from ffprobe untouched
        stdErrConnector = PipeConnector(read: proxyStandardErrorPipe, write: defaultStandardErrorPipe, flush: FileHandle.standardError, relayMode: .line, outputHandlerType: FFmpegError.self)

        let args = [CommandLine.arguments[0]] + FFmpegTask.FFprobeFlags + arguments
        var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator  // TODO: Look at String.utf8CString
        return ExitCodes(ffprobe(Int32(cargs.count - 1), &cargs))  // Minus null terminator
    }
        
    public func processRequest(_ arguments: [String]) -> ExitCodes {
        // Ensure there is at least the minimum number of arguments - this ensures the checks below don't fail
        if arguments.count <= 1 {
            return ExitCodes.InsufficientArguments
        }
        
        // Retrieve the request type and validate against request list
        let request = arguments[1]
        if !FFmpegTask.ValidRequests.contains(request) {
            return ExitCodes.UnknownCommand
        }
        
        
        // Check the request to determine what service to call
        switch request {
        case "-license":
            return invokeFFmpeg(argument: "-L", handler: FFmpegLicense.self)
            
        case "-version":
            return invokeFFmpeg(argument: request, handler: FFmpegVersion.self)
            
        case "-protocols":
            return invokeFFmpeg(argument: request, handler: FFmpegProtocols.self)
            
        case "-formats", "-muxers", "-demuxers", "-devices":
            return invokeFFmpeg(argument: request, handler: FFmpegFormats.self)
        
        case "-bsfs":
            return invokeFFmpeg(argument: request, handler: FFmpegBitstreamFilters.self)
            
        case "-codecs":
            return invokeFFmpeg(argument: request, handler: FFmpegCodecs.self)
            
        case "-decoders":
            return invokeFFmpeg(argument: request, handler: FFmpegDecoders.self)
            
        case "-sample_fmts":
            return invokeFFmpeg(argument: request, handler: FFmpegSampleFormats.self)
            
        case "-colors":
            return invokeFFmpeg(argument: request, handler: FFmpegColors.self)
            
        case "-pix_fmts":
            return invokeFFmpeg(argument: request, handler: FFmpegPixelFormats.self)
            
        case "-layouts":
            return invokeFFmpeg(argument: request, handler: FFmpegLayouts.self)
            
        case "-filters":
            return invokeFFmpeg(argument: request, handler: FFmpegFilters.self)
            
        default:
            // Ensure we have sufficient arguments for ffmpeg and ffprobe
            if arguments.count <= 2 {
                return ExitCodes.InsufficientArguments
            }
            
            // Create an array of strings with arguments minus the application and request
            let newArguments: [String] = Array(arguments[2...])
            
            // Check arguments and fail if an invalid flag is passed - rudimentary but it works
            let invalidFlags = newArguments.filter({ FFmpegTask.InvalidFlags.contains($0) })
            if !invalidFlags.isEmpty {
                return ExitCodes.InvalidArguments
            }
            
            // Check the request to determine what service to call
            if request == "-ffmpeg" {
                return invokeFFmpeg(arguments: newArguments)
                
            } else if request == "-ffprobe" {
                return invokeFFprobe(arguments: newArguments)
            }
        }

        return ExitCodes.UnknownCommand
    }
}
