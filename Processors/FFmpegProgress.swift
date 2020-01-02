//
//  ProgressProcessor.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 26/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//

import Foundation


class FFmpegProgress: Encodable {
    
    private static let ProgressPattern = #"(?:frame=(?<Frame>\d*)\n)?(?:(?:.*\n)*fps=(?<Fps>[\d\.]*)\n)?(?:(?:.*\n)*(?:stream_(?<Input>\d)_(?<Stream>\d)_q)=(?<Quality>[-\d\.]*)\n)?(?:(?:.*\n)*bitrate=(?<Bitrate>[\d\.]*)kbits\/s\n)?(?:(?:.*\n)*total_size=(?<TotalSize>\d*)\n)?(?:(?:.*\n)*out_time_ms=(?<OutTime>\d*)\n)?(?:(?:.*\n)*dup_frames=(?<DuplicateFrames>\d*)\n)?(?:(?:.*\n)*drop_frames=(?<DroppedFrames>\d*)\n)?(?:(?:.*\n)*speed=\s*(?<Speed>\d*)x\n)?(?:(?:.*\n)*progress\s*=\s*(?<Progress>(?:continue)|(?:end)))"#

    var frame: Int
    var fps: Double
    var input: Int
    var stream: Int
    var quality: Double
    var bitrate: Double
    var totalSize: Int
    var outTime: TimeInterval
    var duplicateFrames: Int
    var droppedFrames: Int
    var speed: Int
    var finished: Bool = false
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg progress output")
        }
        
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegProgress.ProgressPattern)
        precondition(matchRegEx.matches.count == 1, "Invalid ffmpeg progress output; unexpected format")

        guard let frame = Int(matchRegEx.matches[0, "Frame"]), let fps = Double(matchRegEx.matches[0, "Fps"]),
            let input = Int(matchRegEx.matches[0, "Input"]), let stream = Int(matchRegEx.matches[0, "Stream"]),
            let quality = Double(matchRegEx.matches[0, "Quality"]), let bitrate = Double(matchRegEx.matches[0, "Bitrate"]),
            let totalSize = Int(matchRegEx.matches[0, "TotalSize"]), let ms = TimeInterval(matchRegEx.matches[0, "OutTime"]),
            let duplicateFrames = Int(matchRegEx.matches[0, "DuplicateFrames"]), let droppedFrames = Int(matchRegEx.matches[0, "droppedFrames"]),
            let speed = Int(matchRegEx.matches[0, "Speed"]) else {
            fatalError("Invalid ffmpeg progress output; unexpected format")
        }
                
        self.frame = frame
        self.fps = fps
        self.input = input
        self.stream = stream
        self.quality = quality
        self.bitrate = bitrate
        self.totalSize = totalSize
        self.outTime = ms / 1000000.0
        self.duplicateFrames = duplicateFrames
        self.droppedFrames = droppedFrames
        self.speed = speed
        self.finished = matchRegEx.matches[0, "Progress"] == "end"
    }

}

class ProgressProcessor {
    
    // RegEx pattern to use to parse properties

    private let NewlineMarker = Data(bytes: [0x0A], count: 1)
    
    private let progressPipe = Pipe()
    private let defaultStdErr: FileHandle
    
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
    func processProgress(fileHandle: FileHandle) {
        guard let jsonData = try? JSONEncoder().encode(FFmpegProgress(from: fileHandle.availableData)) else {
            fatalError("Unable to process progress information.")
        }

        defaultStdErr.write(jsonData)
        defaultStdErr.write(NewlineMarker)
        defaultStdErr.synchronizeFile()
    }

}
