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
    
    public enum ExitCode : Int32 {
        case success = 0
        case failure = 1
        case insufficientArguments = 2
        case invalidArgument = 3
        case unknownRequest = 4
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
        
    
    // Copy the current stdxxx to filehandle for holding
    private let defaultStandardOutput = FileHandle(fileHandle: FileHandle.standardOutput)
    private let defaultStandardError = FileHandle(fileHandle: FileHandle.standardError)

    private let proxyStandardOutputPipe = Pipe()
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
        
        // Reset stdxxx to the proxy stdxxx pipe to allow intercepting and redirect to processor
        FileHandle.standardOutput.duplicateFrom(fileHandle: proxyStandardOutputPipe.fileHandleForWriting)
        FileHandle.standardError.duplicateFrom(fileHandle: proxyStandardErrorPipe.fileHandleForWriting)

        // Set stdin to stdnull - just in case - the trick above could be used with stdin for IPC if needed
        FileHandle.standardInput.duplicateFrom(fileHandle: FileHandle.nullDevice)
        
        // Prepare the exit handler to ensure that the above handles are all flushed and finished
        // In order for the C function closure to work, variables must be static, therefore this is
        // a 1:1 with the static "Application" singleton. This is needed as ffmpeg exits everywhere.
        //
        // WARNING: This must be the first registered closure, otherwise flushing will not succeed.

        atexit {
            if let stdOutConnector = FFmpegTask.Application.stdOutConnector {
                stdOutConnector.flush()
            }
            
            if let progressConnector = FFmpegTask.Application.progressConnector {
                progressConnector.flush()
            }
            
            if let stdErrConnector = FFmpegTask.Application.stdErrConnector {
                stdErrConnector.flush()
            }
            
            // Reset the handles to stdout and stderr
            FileHandle.standardOutput.duplicateFrom(fileHandle: FFmpegTask.Application.defaultStandardOutput)
            FileHandle.standardError.duplicateFrom(fileHandle: FFmpegTask.Application.defaultStandardError)
        }
    }

    private func invokeFFmpeg(argument: String, handler: FFmpegOutputHandler.Type? = nil) -> ExitCode {
        return invokeFFmpeg(arguments: [argument], handler: handler)
    }
    
    private func invokeFFmpeg(arguments: [String], handler: FFmpegOutputHandler.Type? = nil) -> ExitCode {
        stdOutConnector = PipeConnector(read: proxyStandardOutputPipe.fileHandleForReading, write: defaultStandardOutput, relayMode: .end, outputHandlerType: handler)
        stdErrConnector = PipeConnector(read: proxyStandardErrorPipe.fileHandleForReading, write: defaultStandardError, relayMode: .line, outputHandlerType: FFmpegStatus.self)

        progressConnector = PipeConnector(read: progressPipe.fileHandleForReading, write: defaultStandardError, relayMode: .terminators, outputHandlerType: FFmpegProgress.self)

        let cargs = CStringArray([CommandLine.arguments[0]] + FFmpegTask.FFmpegFlags +
            ["-progress", "pipe:\(progressPipe.fileHandleForWriting.fileDescriptor)"] + arguments)
        return ffmpeg(Int32(cargs.count), cargs.pointer) == 0 ? ExitCode.success : ExitCode.failure
    }
        
    private func invokeFFprobe(arguments: [String]) -> ExitCode {
        // Passthrough all output from ffprobe untouched
        stdOutConnector = PipeConnector(read: proxyStandardOutputPipe.fileHandleForReading, write: defaultStandardOutput, relayMode: .end)
        stdErrConnector = PipeConnector(read: proxyStandardErrorPipe.fileHandleForReading, write: defaultStandardError, relayMode: .line, outputHandlerType: FFmpegStatus.self)

        let cargs = CStringArray([CommandLine.arguments[0]] + FFmpegTask.FFprobeFlags + arguments)
        return ffprobe(Int32(cargs.count), cargs.pointer) == 0 ? ExitCode.success : ExitCode.failure
    }
        
    public func processRequest(_ arguments: [String]) -> ExitCode {
        // Ensure there is at least the minimum number of arguments - this ensures the checks below don't fail
        if arguments.count <= 1 {
            return ExitCode.insufficientArguments
        }
        
        // Retrieve the request type and validate against request list
        let request = arguments[1]
        if !FFmpegTask.ValidRequests.contains(request) {
            return ExitCode.unknownRequest
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
                return ExitCode.insufficientArguments
            }
            
            // Create an array of strings with arguments minus the application and request
            let newArguments: [String] = Array(arguments[2...])
            
            // Check arguments and fail if an invalid flag is passed - rudimentary but it works
            let invalidFlags = newArguments.filter({ FFmpegTask.InvalidFlags.contains($0) })
            if !invalidFlags.isEmpty {
                return ExitCode.invalidArgument
            }
            
            // Check the request to determine what service to call
            if request == "-ffmpeg" {
                return invokeFFmpeg(arguments: newArguments)
                
            } else if request == "-ffprobe" {
                return invokeFFprobe(arguments: newArguments)
            }
        }

        return ExitCode.unknownRequest
    }
}
