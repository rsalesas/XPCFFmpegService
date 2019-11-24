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


class FFmpegTask {
    
    static let FFmpegFlags = ["-hide_banner", "-nostats", "-progress", "pipe:2", "-loglevel", "repeat+level+warning", "-nostdin"]
    static let FFmpegExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags"]

    static let FFprobeFlags = ["-hide_banner", "-loglevel", "repeat+level+warning", "-print_format", "json", "-sexagesimal"]
    static let FFprobeExcludeFlags = ["-h", "-?", "-help", "--help", "-cpuflags", "-byte_binary_prefix"]
        
    private enum FFmpegTaskErrorType: String {
        case error = "[Error]"
        case warning = "[Warning]"
    }
    
    private static func printError(_ message: String, error: FFmpegTaskErrorType = FFmpegTaskErrorType.error) {
        let messageLn = error.rawValue + " " + message + "\n"
        if let data = messageLn.data(using: .utf8)  {
            FileHandle.standardError.write(data)
        }
    }
    
    static func processRequest() -> Int32 {

        // Ensure there is at least the minimum number of arguments - this ensures the checks below don't failw
        if CommandLine.arguments.count < 5 {
            printError("Insufficent arguments \(CommandLine.arguments)")
            return EXIT_FAILURE
        }
        
        // Disable colour output for the ffmpeg libraries
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1)

        var args = CommandLine.arguments
        if args[1] == "-ffmpeg" {
            // prepare the arguments for ffmpeg
            args = [args[0]] + (args[2...args.count-1]).filter { !FFmpegExcludeFlags.contains($0) } + FFmpegFlags
            
            // Call the C function with the arguments
            var cargs = args.map { strdup($0) }
            return ffmpeg(Int32(cargs.count), &cargs)
            
        } else if args[1] == "-ffprobe" {
            // Prepare the arguments for ffprobe
            args = [args[0]] + (args[2...args.count-1]).filter { !FFprobeExcludeFlags.contains($0) } + FFprobeFlags
            
            // Call the C function with the arguments
            var cargs = args.map { strdup($0) }
            return ffprobe(Int32(cargs.count), &cargs)
            
        } else {
            printError("No request provided. Please specify -ffmpeg or -ffprobe.")
            return EXIT_FAILURE
        }
    }

}

exit(FFmpegTask.processRequest())
