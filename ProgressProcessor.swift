//
//  ProgressProcessor.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 26/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//

import Foundation


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

