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


// TODO: Block -bsfs, -protocols, -formats, -demuxers, etc. and make them top level requests - this would allow us to set a program mode and catch the output

@_cdecl("ffmpegTaskAtExit")
func AtExit() {
    fputs("hello from ffmpegTaskAtExit\n", stderr)
    fflush(stderr)
}


// This class is a non-thread safe singleton - be careful!
class FFmpegTask {
    
    // Flags for running processes
    private static let ValidRequests = ["-ffmpeg", "-ffprobe", "-license", "-version", "-protocols", "-formats", "-muxers", "-demuxers", "-devices", "-bsfs",
                                        "-codecs", "-decoders", "-sample_fmts", "-colors", "-pix_fmts", "-layouts", "-filters"]
    private static let FFmpegFlags = ["-hide_banner", "-nostats", "-loglevel", "repeat+level+info", "-nostdin"]
    private static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal", "-noshow_private_data", ]
    private static let InvalidFlags = ["-version", "-L", "-h", "-?", "-help", "--help", "-cpuflags", "-sources", "-sinks", "-byte_binary_prefix", "-show_private_data",
                                       "-license", "-version", "-protocols", "-formats", "-muxers", "-demuxers", "-devices", "-bsfs",
                                       "-codecs", "-decoders", "-sample_fmts", "-colors", "-pix_fmts", "-layouts", "-filters"]
    
    // Null terminator for calling main(argc, argv)
    //private static let NullTerminator = [UnsafeMutablePointer<Int8>(0)]
    private static let NewlineMarker = Data(bytes: [0x0A], count: 1)
    private static var NullTerminator = [UnsafeMutablePointer<Int8>.allocate(capacity: 1)]

    // RegEx pattern to use to parse output
    private static let ErrorPattern = #"^\[(?<Type>.*)\]\s(?<Description>.*?)\s*$"#

    // Singleton - do not access this class in any other way.
    static let Application = FFmpegTask()
        
    private let exitGroup = DispatchGroup()
    private let defaultStandardOutputPipe = Pipe()
    private let proxyStandardOutputPipe = Pipe()
    private let defaultStandardErrorPipe = Pipe()
    private let proxyStandardErrorPipe = Pipe()
    
    private let progressProcessor: ProgressProcessor
    
    private var finished = false

    
    // Prepare the environment for calling the ffmpeg libraries
    private init() {
        // Disable colour output for the ffmpeg libraries
        unsetenv("AV_LOG_FORCE_COLOR")
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1)
        
        // Prepare the progress processor - this should be moved only to the one call to ffmpeg
        progressProcessor = ProgressProcessor(defaultStdErr: defaultStandardErrorPipe.fileHandleForWriting, exitGroup: exitGroup)
        
        // Copy the current std to the default std pipe for holding
        dup2(FileHandle.standardOutput.fileDescriptor, defaultStandardOutputPipe.fileHandleForWriting.fileDescriptor)
        dup2(FileHandle.standardError.fileDescriptor, defaultStandardErrorPipe.fileHandleForWriting.fileDescriptor)

        // Reset std to the proxy std pipe to allow intercepting and redirect to processor and enable line buffering
        dup2(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
        //setlinebuf(fdopen(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, "w"))

        dup2(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardError.fileDescriptor)
        proxyStandardErrorPipe.fileHandleForReading.readabilityHandler = processProxyStandardError
        //setlinebuf(fdopen(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, "w"))

        // Set stdin to stdnull - just in case - the trick above could be used with stdin for IPC if needed
        dup2(FileHandle.nullDevice.fileDescriptor, FileHandle.standardInput.fileDescriptor)
        
        // Prepare the exit handler to ensure that the above handles are all flushed and finished
        // In order for the C function closure to work, variables must be static, therefore this
        // is a 1:1 with the static "Application" singleton. This is needed as ffmpeg exits from
        // a billion places, seemingly randomly.
        //
        // WARNING: This must be the first registered closure, otherwise flushing will not succeed.
        atexit {
            // Signal to the proxy pipes that we are done with all the output.
            //fputs("[exit]\n", stdout)
            //fflush(stdout)
            //fputs("[exit]\n", stderr)
            //fflush(stderr)
            
            sleep(10)

            // Wait for any activities to complete
            FFmpegTask.Application.exitGroup.wait()
        }
    }
    
    // Output an error message in json format "{type:error,description:message}"
    private func printError(_ message: String) {
        struct ErrorJSON: Codable {
            let type: String = "error"
            let description: String
        }
        
        writeAsJSON(ErrorJSON(description: message), fileHandle: defaultStandardErrorPipe.fileHandleForWriting)
    }
    
    // Note: As Encodable is a protocol, we need to use templates
    private func writeAsJSON<C: Encodable>(_ encodable: C, fileHandle: FileHandle) {
        guard let jsonData = try? JSONEncoder().encode(encodable) else {
            fatalError("Unable to output json object.")
        }

        fileHandle.write(jsonData)
        fileHandle.write(FFmpegTask.NewlineMarker)
        fileHandle.synchronizeFile()
    }
    
    // By default allows the data through. Special cases are dealt with in separate functions, this assumes the results are in json
    func processFFmpegStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
            
        let data = fileHandle.availableData
        defaultStandardOutputPipe.fileHandleForWriting.write(data)
        defaultStandardOutputPipe.fileHandleForWriting.synchronizeFile()
    }
    
    // Allows ffprobe data through. Special cases are dealt with in separate functions, this assumes the results are in json
    func processFFprobeStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
            
        let data = fileHandle.availableData
        defaultStandardOutputPipe.fileHandleForWriting.write(data)
        defaultStandardOutputPipe.fileHandleForWriting.synchronizeFile()
    }
    
    func processLicenseStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        writeAsJSON(FFmpegLicense(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }
    
    func processVersionStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
               
        writeAsJSON(FFmpegVersion(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }
    func processProtocolsStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        writeAsJSON(FFmpegProtocols(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }
    
    func processFormatsStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        writeAsJSON(FFmpegFormats(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }
    
    func processBitstreamFiltersStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        writeAsJSON(FFmpegBitstreamFilters(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    func processCodecsStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        writeAsJSON(FFmpegCodecs(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    func processDecodersStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        writeAsJSON(FFmpegDecoders(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    func processSampleFormatsStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
        writeAsJSON(FFmpegSampleFormat(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    func processColorsStandardOutput(fileHandle: FileHandle) {
       exitGroup.enter()
       defer { exitGroup.leave() }
       
       writeAsJSON(FFmpegColors(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    func processPixelFormatsStandardOutput(fileHandle: FileHandle) {
      exitGroup.enter()
      defer { exitGroup.leave() }
      
      writeAsJSON(FFmpegPixelFormats(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    func processLayoutsStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }

        writeAsJSON(FFmpegLayouts(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    func processFiltersStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }

        writeAsJSON(FFmpegFilters(from: fileHandle.availableData), fileHandle: defaultStandardOutputPipe.fileHandleForWriting)
    }

    // Output an error message in json format "{type:error,description:message}"
    func processProxyStandardError(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
        
//        let data = fileHandle.availableData
//         defaultStandardOutputPipe.fileHandleForWriting.write(data)
//         defaultStandardOutputPipe.fileHandleForWriting.synchronizeFile()
        let data = fileHandle.availableData
        let errors = FFmpegError(from: data).errors
        errors.forEach { error in
            writeAsJSON(error, fileHandle: defaultStandardErrorPipe.fileHandleForWriting)
        }

        let exitCode = data.suffix(7)
        if exitCode == "[exit]\n".data(using: .ascii) {
            exitGroup.leave()
        }
       
        
        // This method is a bit different in that it prints each processed error separately
//        var data = fileHandle.availableData
//        while !data.isEmpty {
//            let errors = FFmpegError(from: data).errors
//            errors.forEach { error in
//                writeAsJSON(error, fileHandle: defaultStandardErrorPipe.fileHandleForWriting)
//            }
//
//            if finished {
//                break
//            }
//
//            data = fileHandle.availableData
//        }

//        let errors = FFmpegError(from: fileHandle.availableData).errors
//        errors.forEach { error in
//            writeAsJSON(error, fileHandle: defaultStandardErrorPipe.fileHandleForWriting)
//        }
    }
        
    func processRequest(_ arguments: [String]) -> Int32 {
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
        if request == "-license" {
            proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processLicenseStandardOutput

            let args = [arguments[0], "-L"] + FFmpegTask.FFmpegFlags
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator
            
        } else if request == "-version" {
            proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processVersionStandardOutput
            
            let args = [arguments[0], "-version"] + FFmpegTask.FFmpegFlags
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-protocols" {
            proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processProtocolsStandardOutput
            
            let args = [arguments[0], "-protocols"] + FFmpegTask.FFmpegFlags
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator
    
        } else if ["-formats", "-muxers", "-demuxers", "-devices"].contains(request) {
            proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processFormatsStandardOutput
            
            let args = [arguments[0], request] + FFmpegTask.FFmpegFlags
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator
            
        } else if request == "-bsfs" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processBitstreamFiltersStandardOutput
             
             let args = [arguments[0], "-bsfs"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-codecs" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processCodecsStandardOutput
             
             let args = [arguments[0], "-codecs"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-decoders" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processDecodersStandardOutput
             
             let args = [arguments[0], "-decoders"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-sample_fmts" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processSampleFormatsStandardOutput
             
             let args = [arguments[0], "-sample_fmts"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-colors" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processColorsStandardOutput
             
             let args = [arguments[0], "-colors"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-pix_fmts" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processPixelFormatsStandardOutput
             
             let args = [arguments[0], "-pix_fmts"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-layouts" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processLayoutsStandardOutput
             
             let args = [arguments[0], "-layouts"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else if request == "-filters" {
             proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processFiltersStandardOutput
             
             let args = [arguments[0], "-filters"] + FFmpegTask.FFmpegFlags
             var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
             return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else {
            // Ensure we have sufficient arguments for ffmpeg and ffprobe
            if arguments.count <= 2 {
                printError("Insufficent arguments for request \"\(request)\"")
                return EXIT_FAILURE
            }
            
            // Create an array of strings with arguments minus the request
            let newArguments = [arguments[0]] + arguments[2...]
            
            // Check arguments and fail if an invalid flag is passed
            let invalidFlags = newArguments[2...].filter({ FFmpegTask.InvalidFlags.contains($0) })
            if !invalidFlags.isEmpty {
                printError("Invalid arguments \(invalidFlags)")
                return EXIT_FAILURE
            }
            
            // Check the request to determine what service to call
            if request == "-ffmpeg" {
                FFmpegTask.Application.exitGroup.enter()

                proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processFFmpegStandardOutput
                
                // prepare the arguments for ffmpeg
                let args = newArguments + FFmpegTask.FFmpegFlags + ["-progress", "pipe:\(progressProcessor.fileDescriptor)"]

                // Call the C function with the arguments - it will end with exit() instead of return
                var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
                return ffmpeg(Int32(cargs.count), &cargs)
                
            } else if request == "-ffprobe" {
                proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processFFprobeStandardOutput

                // Prepare the arguments for ffprobe
                let args = newArguments + FFmpegTask.FFprobeFlags
                
                // Call the C function with the arguments - it will end with exit() instead of return
                var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
                return ffprobe(Int32(cargs.count - 1), &cargs)  // Minus null terminator
                
            }
        }
        
        return EXIT_FAILURE
    }
}
