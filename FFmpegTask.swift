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

// TODO: Catch the output of -license and -version and wrap it in json

// This class is a non-thread safe singleton - be careful!
class FFmpegTask {
    
    // Flags for running processes
    private static let FFmpegFlags = ["-hide_banner", "-nostats", "-loglevel", "repeat+level+info", "-nostdin"]
    private static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal"]
    private static let InvalidFlags = ["-version", "-L", "-h", "-?", "-help", "--help", "-cpuflags", "-sources", "-sinks", "-byte_binary_prefix"]
    
    // Null terminator for calling main(argc, argv)
    //private static let NullTerminator = [UnsafeMutablePointer<Int8>(0)]
    private static let NewlineMarker = Data(bytes: [0x0A], count: 1)
    private static var NullTerminator = [UnsafeMutablePointer<Int8>.allocate(capacity: 1)]


    // RegEx pattern to use to parse output
    private static let ErrorPattern = #"^\[(?<Type>.*)\]\s(?<Description>.*?)\s*$"#
    private static let FormatPattern = #"^\s{1,2}(?<Support>D?E?)\s+(?<Format>\S+)\s+(?<Description>.*)$"#  // -formats, -demuxers, -muxers, -devices
    private static let CodecPattern = #"^\s(?<Support>[DEVASILS\.]{6})\s+(?<Format>\S+)\s+(?<Description>.*)$"#  // -codecs
    private static let DecoderPattern = #"^\s(?<Support>[VASFXBD\.]{6})\s+(?<Format>\S+)\s+(?<Description>.*)$"#  // -decoders
    private static let ProtocolPattern = #"(?:(?:(?<Input>Input):\n)+|(?:(?<Output>Output):\n)+)|^(?<Protocol>\s\s\S+)*$"#  // -protocols, a bit different in that Input/Output are states
    private static let FilterPattern = #"^\s(?<Support>[TSCAVNI\.]{3})\s+(?<Filter>\S+)\s+(?<Workflow>\S+)\s+(?<Description>.*)$"#  // -filters
    private static let PixelFormatsPattern = #"^(?<Support>[IOHPB\.]{5})\s+(?<Filter>\S+)\s+(?<Components>\d+)\s+(?<BitsPerPixel>\d*)$"#  // -pix_fmts
    private static let SampleFormatPattern = #"^(?<Name>(?!name)\S+)\s*(?<Depth>(?!depth)\d+)\s*$"#  // -sample_fmts
    private static let LayoutPattern = #"^(?:(?<Individual>Individual)|(?<Standard>Standard))+|^(?:(?<Name>(?!NAME|Individual|Standard)\S+)\s+(?<Description>(?!DESCRIPTION).+))$"#  // -layouts, a bit different in that Individual/Standard are states
    private static let ColorPattern = #"^(?:(?<Name>(?!name)\S+)\s+(?<Description>(?!#RRGGBB).+))$"#  // -colors
    private static let VersionPattern = #"^(?:FFmpegTask version (?<Version>\S+)\s(?<FFmpegCopyright>.*)\nbuilt with (?<Compiler>.*)\nconfiguration: (?<Configuration>.*)\n)|(?:(?<Library>lib\S+)\s*(?<Major>\d+)\.\s*(?<Minor>\d+)\.\s*(?<Build>\d+))"#  // -version
    
    
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

        // Reset std to the proxy std pipe to allow intercepting and redirect to processor and enable line buffering
        dup2(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
        proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processProxyStandardOutput
        setlinebuf(fdopen(proxyStandardOutputPipe.fileHandleForWriting.fileDescriptor, "w"))

        dup2(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, FileHandle.standardError.fileDescriptor)
        proxyStandardErrorPipe.fileHandleForReading.readabilityHandler = processProxyStandardError
        setlinebuf(fdopen(proxyStandardErrorPipe.fileHandleForWriting.fileDescriptor, "w"))

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
                
                sleep(3)
            }
            catch {
                //os_log("Unable to flush stdout and stderr filehandles")
            }
        }
    }
    
    // Output an error message in json format "{type:error,description:message}"
    private func printError(_ message: String) {
        struct json: Codable {
            let error: String
        }
        
        printJSON(json(error: message), fileHandle: defaultStandardErrorPipe.fileHandleForWriting)
    }
    
    // Note: As Encodable is a protocol, we need to use templates... This would be so much easier:
    //      private func printJSON(_ codable: Encodable, fileHandle: FileHandle) {
    private func printJSON<C: Encodable>(_ codable: C, fileHandle: FileHandle) {
        guard let jsonData = try? JSONEncoder().encode(codable) else {
            os_log("Unable to process progress information.")
            return
        }

        fileHandle.write(jsonData)
        fileHandle.write(FFmpegTask.NewlineMarker)
        fileHandle.synchronizeFile()
    }
    
    // By default allows the data through. Special cases are dealt with in separate functions, this assumes the results are in json
    func processProxyStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
            
        let data = fileHandle.availableData
        defaultStandardOutputPipe.fileHandleForWriting.write(data)
    }
    
    func processVersionStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
            
        let data = fileHandle.availableData
        defaultStandardOutputPipe.fileHandleForWriting.write(data)
    }
    
    func processLicenseStandardOutput(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }
            
        let data = fileHandle.availableData
        guard let message = String(data: data, encoding: .utf8) else {
            printError("Unable to retrieve license")
            return
        }
        
        struct json: Codable {
            let license: String
        }
        
        printJSON(json(license: message), fileHandle: defaultStandardErrorPipe.fileHandleForWriting)
    }
    
    // Output an error message in json format "{type:error,description:message}"
    func processProxyStandardError(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }

        let data = fileHandle.availableData
        guard let message = String(data: data, encoding: .utf8), let regEx = try? NSRegularExpression(pattern: FFmpegTask.ErrorPattern, options: .anchorsMatchLines) else {
            let dataString = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            //os_log("Unable to process stderr output (%@)", dataString)
            return
        }
        
        // TODO: Consider making "info" output into a collection of collections when indents occur.
        let values = regEx.matches(in: message, options: [], range: NSMakeRange(0, message.count))
        values.forEach { value in
            if let range = Range(value.range(withName: "Type"), in: message) {
                let type = String(message[range])
                
                if let range = Range(value.range(withName: "Description"), in: message) {
                    let description = String(message[range])
                    
                    let json = "{\"\(type)\":\"\(description)\"}\n"
                    if let data = json.data(using: .utf8)  {
                        defaultStandardErrorPipe.fileHandleForWriting.write(data)
                        return
                    }
                }
            }
        }
        
        // If we fall through, it means we failed to output
        let dataString = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        //os_log("Unable to process stderr output (%@)", dataString)
    }
        
    func processRequest(_ arguments: [String]) -> Int32 {
        // Ensure there is at least the minimum number of arguments - this ensures the checks below don't failw
        if arguments.count <= 1 {
            printError("Insufficent arguments \(arguments)")
            return EXIT_FAILURE
        }
                               
        // Create an array of strings with arguments minus the request
        let request = arguments[1]
        let args = [arguments[0]] + arguments[2...]

        // Check arguments and fail if an invalid flag is passed
        let invalidFlags = args[1...].filter({ FFmpegTask.InvalidFlags.contains($0) })
        if !invalidFlags.isEmpty {
            printError("Invalid arguments \(invalidFlags)")
            return EXIT_FAILURE
        }
        
        // Check the request to determine what service to call
        if request == "-ffmpeg" {
            // prepare the arguments for ffmpeg
            let args = args + FFmpegTask.FFmpegFlags + ["-progress", "pipe:\(progressProcessor.fileDescriptor)"]

            // Call the C function with the arguments
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffmpeg(Int32(cargs.count), &cargs)
            
        } else if request == "-ffprobe" {
            // Prepare the arguments for ffprobe
            let args = args + FFmpegTask.FFprobeFlags
            
            // Call the C function with the arguments
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffprobe(Int32(cargs.count - 1), &cargs)  // Minus null terminator
            
        } else if request == "-license" {
            proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processLicenseStandardOutput

            let args = [args[0], "-L"] + FFmpegTask.FFmpegFlags
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator
            
        } else if request == "-version" {
            proxyStandardOutputPipe.fileHandleForReading.readabilityHandler = processVersionStandardOutput
            
            let args = [args[0], "-version"] + FFmpegTask.FFmpegFlags
            var cargs = args.map { strdup($0) } + FFmpegTask.NullTerminator
            return ffmpeg(Int32(cargs.count - 1), &cargs)  // Minus null terminator

        } else {
            printError("No request provided. Please specify -ffmpeg or -ffprobe.")
            return EXIT_FAILURE
        }
    }
}
