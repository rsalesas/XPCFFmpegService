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


// TODO: Move this to a separate file
class ProgressProperties: Codable {
    
    // RegEx pattern to use to parse properties
    static let Pattern = #"(?:(?:frame\s*=\s*(?<Frame>\d*))\n(?:fps\s*=\s*(?<Fps>[\d\.]*))\n(?:(?:stream_(?<Input>\d)_(?<Stream>\d)_q)\s*=\s*(?<Quality>[-\d\.]*))\n"# + #"(?:bitrate\s*=\s*(?<Bitrate>[\d\.]*)kbits\/s)\n(?:total_size\s*=\s*(?<TotalSize>\d*))\n(?:.*\n)*"# +
        #"(?:out_time_ms\s*=\s*(?<OutTime>\d*))\n(?:.*\n)*(?:dup_frames\s*=\s*(?<DuplicateFrames>\d*))\n"# +
        #"(?:drop_frames\s*=\s*(?<DroppedFrames>\d*))\n(?:speed\s*=\s*(?<Speed>\d*)x)\n(?:progress\s*=\s*(?<Progress>.*)))\n*"#

    var frame: Int?
    var fps: Double?
    var input: Int?
    var stream: Int?
    var quality: Double?
    var bitrate: Double?
    var totalSize: Int?
    var outTime: TimeInterval?
    var duplicateFrames: Int?
    var droppedFrames: Int?
    var speed: Int?
    var finished: Bool = false
    
    init(message: String, values: NSTextCheckingResult) {
        if let range = Range(values.range(withName: "Frame"), in: message) {
            frame = Int(message[range])
        }
        
        if let range = Range(values.range(withName: "Fps"), in: message) {
            fps = Double(message[range])
        }

        if let range = Range(values.range(withName: "Input"), in: message) {
            input = Int(message[range])
        }
        
        if let range = Range(values.range(withName: "Stream"), in: message) {
            stream = Int(message[range])
        }
        
        if let range = Range(values.range(withName: "Quality"), in: message) {
            quality = Double(message[range])
        }
        
        if let range = Range(values.range(withName: "Bitrate"), in: message) {
            bitrate = Double(message[range])
        }

        if let range = Range(values.range(withName: "TotalSize"), in: message) {
            totalSize = Int(message[range])
        }

        if let range = Range(values.range(withName: "OutTime"), in: message) {
            if let ms = TimeInterval(message[range]) {
                outTime = ms / 1000000.0
            }
        }

        if let range = Range(values.range(withName: "DuplicateFrames"), in: message) {
            duplicateFrames = Int(message[range])
        }

        if let range = Range(values.range(withName: "DroppedFrames"), in: message) {
            droppedFrames = Int(message[range])
        }

        if let range = Range(values.range(withName: "Speed"), in: message) {
            speed = Int(message[range])
        }
        
        if let range = Range(values.range(withName: "Progress"), in: message) {
            finished = message[range] != "continue"
        }
    }
    
    func toJSON() -> String {
        let jsonEncoder = JSONEncoder()
        if let jsonData = try? jsonEncoder.encode(self) {
            let json = String(data: jsonData, encoding: String.Encoding.utf8)
            return json ?? ""
        }

        return ""
    }
}



// This class is a non-thread safe singleton - be careful!
class FFmpegTask {
    
    // Flags for running processes  // TODO: make it "nostats"
    static let FFmpegFlags = ["-hide_banner", "-nostats", "-loglevel", "repeat+level+warning", "-nostdin"]
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
            let progressRegEx = try? NSRegularExpression(pattern: ProgressProperties.Pattern) else {
            os_log("Unable to process progress information.")
            return
        }
    
        // TODO: Move the search to the progress class
        if let values = progressRegEx.matches(in: message, options: [], range: NSMakeRange(0, message.count)).first {
            let progressProperties = ProgressProperties(message: message, values: values)
            let json = progressProperties.toJSON()
            print("\(json)")
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
