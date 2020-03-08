//
//  ProgressHandler.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 4/1/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


class FFmpegProgress: Encodable {
    
    private static let RegExPattern = #"(?:frame=(?<Frame>\d+)\n)?(?:(?:.*\n)*fps=(?<Fps>[\d\.]+)\n)?(?:(?:.*\n)*(?:stream_(?<Input>\d)_(?<Stream>\d)_q)=(?<Quality>[-\d\.]+)\n)?(?:(?:.*\n)*bitrate=\s*(?<Bitrate>[\d\.]+)kbits\/s\n)?(?:(?:.*\n)*total_size=(?<TotalSize>(?:\d+)|(?:.*))\n)?(?:(?:.*\n)*out_time_ms=(?<OutTime>(?:\d+)|(?:.*))\n)?(?:(?:.*\n)*dup_frames=(?<DuplicateFrames>\d+)\n)?(?:(?:.*\n)*drop_frames=(?<DroppedFrames>\d+)\n)?(?:(?:.*\n)*speed=\s*(?<Speed>(?:[\d\.]+)|(?:.*))x?\n)?(?:(?:.*\n)*progress\s*=\s*(?<Progress>(?:continue)|(?:end)))\s*"#

    var frame: Int
    var fps: Double
    var input: Int
    var stream: Int
    var quality: Double
    var bitrate: Double?
    var totalSize: Int?
    var outTime: TimeInterval?
    var duplicateFrames: Int
    var droppedFrames: Int
    var speed: Int?
    var finished: Bool
   
    
    required init?(from: Data, trailingData: inout Data?) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegProgress.RegExPattern, options: []), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg progress output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        // The following must be included and convert properly
        guard let frame = Int(matchRegEx.matches[0, "Frame"]), let fps = Double(matchRegEx.matches[0, "Fps"]),
            let input = Int(matchRegEx.matches[0, "Input"]), let stream = Int(matchRegEx.matches[0, "Stream"]),
            let quality = Double(matchRegEx.matches[0, "Quality"]), let duplicateFrames = Int(matchRegEx.matches[0, "DuplicateFrames"]),
            let droppedFrames = Int(matchRegEx.matches[0, "DroppedFrames"])
             else {
            fatalError("Invalid ffmpeg progress output; unexpected format")
        }
        
        // The following must be included but could convert to "N/A" in which case we leave them nil
        let bitrate = Double(matchRegEx.matches[0, "Bitrate"])
        let totalSize = Int(matchRegEx.matches[0, "TotalSize"])
        let ms = TimeInterval(matchRegEx.matches[0, "OutTime"])
        let speed = Int(matchRegEx.matches[0, "Speed"])
        
        self.frame = frame
        self.fps = fps
        self.input = input
        self.stream = stream
        self.quality = quality
        self.bitrate = bitrate
        self.totalSize = totalSize
        self.outTime = ms == nil ? nil : ms! / 1000000.0
        self.duplicateFrames = duplicateFrames
        self.droppedFrames = droppedFrames
        self.speed = speed
        self.finished = matchRegEx.matches[0, "Progress"] == "end"
        
        var availableData = from
        if let fullMatch = matchRegEx.fullMatch, let range = Range(fullMatch) {
            availableData.removeSubrange(range)
            trailingData = availableData.isEmpty ? nil : availableData
        }
    }

}

class ProgressHandler {
    
    // RegEx pattern to use to parse properties

    private let NewlineMarker = Data(bytes: [0x0A], count: 1)
    
    private let progressPipe = Pipe()
    private let defaultStdErr: FileHandle
    private var standardOutputBuffer = Data(capacity: 1024)

    var fileDescriptor: Int32 {
        get {
            progressPipe.fileHandleForWriting.fileDescriptor
        }
    }

    init(defaultStdErr: FileHandle) {
        self.defaultStdErr = defaultStdErr
        progressPipe.fileHandleForReading.readabilityHandler = processProgress
    }
    
    // This function relies on the fact that ffmpeg.c::print_report flushes after writing its buffers
    // TODO: Don't love that the synchronize is stuck here. Perhaps this method should live in FFmpegTask
    func processProgress(fileHandle: FileHandle) {
        synchronized(FFmpegTask.Application) {
            let data = fileHandle.availableData
            if data.isEmpty {
                return
            }
            
            var trailingData: Data?
            if let progress = FFmpegProgress(from: data, trailingData: &trailingData) {
                guard let jsonData = try? JSONEncoder().encode(progress) else {
                    fatalError("Unable to process progress information.")
                }

                defaultStdErr.write(jsonData)
                defaultStdErr.write(NewlineMarker)
                defaultStdErr.synchronizeFile()

                if let trailingData = trailingData {
                    os_log("Trailing data in progress format received.")
                    standardOutputBuffer.append(trailingData)
                }
            } else {
                os_log("Partial progress buffer received.")
                standardOutputBuffer.append(data)
            }
        }
    }
    
    func processLastProgress() {
        progressPipe.fileHandleForWriting.closeFile()
        processProgress(fileHandle: progressPipe.fileHandleForReading)
    }

}
