//
//  ProgressProcessor.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 26/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//

import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


class ProgressProperties: Codable {
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
    
    internal init(message: String, values: NSTextCheckingResult) {
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
            finished = message[range] == "end"
        }
    }
}

class ProgressProcessor {
    
    // RegEx pattern to use to parse properties
    private static let Pattern = #"(?:(?:frame\s*=\s*(?<Frame>\d*))\n(?:.*\n)*(?:fps\s*=\s*(?<Fps>[\d\.]*))\n(?:.*\n)*(?:(?:stream_(?<Input>\d)_(?<Stream>\d)_q)\s*=\s*(?<Quality>[-\d\.]*))\n(?:.*\n)*(?:bitrate\s*=\s*(?<Bitrate>[\d\.]*)kbits\/s)\n(?:.*\n)*(?:total_size\s*=\s*(?<TotalSize>\d*))\n(?:.*\n)*(?:.*\n)*(?:out_time_ms\s*=\s*(?<OutTime>\d*))\n(?:.*\n)*(?:dup_frames\s*=\s*(?<DuplicateFrames>\d*))\n(?:.*\n)*(?:drop_frames\s*=\s*(?<DroppedFrames>\d*))\n(?:.*\n)*(?:speed\s*=\s*(?<Speed>\d*)x)\n(?:.*\n)*(?:progress\s*=\s*(?<Progress>.*)))\n*"#

    var newlineMarker = Data(bytes: [0x0A], count: 1)
    
    private let progressPipe = Pipe()
    private let exitGroup: DispatchGroup
    private let defaultStdErr: FileHandle
    
    var fileDescriptor: Int32 {
        get {
            progressPipe.fileHandleForWriting.fileDescriptor
        }
    }

    init(defaultStdErr: FileHandle, exitGroup: DispatchGroup) {
        self.exitGroup = exitGroup
        self.defaultStdErr = defaultStdErr
        progressPipe.fileHandleForReading.readabilityHandler = processProgress
    }
    
    // This function relies on the fact that ffmpeg.c::print_report flushes after writing its buffers
    func processProgress(fileHandle: FileHandle) {
        exitGroup.enter()
        defer { exitGroup.leave() }

        let data = fileHandle.availableData
        guard let message = String(data: data, encoding: .utf8),
            let progressRegEx = try? NSRegularExpression(pattern: ProgressProcessor.Pattern) else {
            os_log("Unable to process progress information.")
            return
        }
    
        if let values = progressRegEx.matches(in: message, options: [], range: NSMakeRange(0, message.count)).first {
            let progressProperties = ProgressProperties(message: message, values: values)
            
            guard let jsonData = try? JSONEncoder().encode(progressProperties) else {
                os_log("Unable to process progress information.")
                return
            }

            defaultStdErr.write(jsonData)
            defaultStdErr.write(newlineMarker)
            defaultStdErr.synchronizeFile()
        }
    }

}
