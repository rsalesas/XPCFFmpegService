//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegSampleFormat: Encodable {
    private static let SampleFormatPattern = #"^(?<Name>(?!name)\S+)\s*(?<Depth>(?!depth)\d+)\s*$"#  // -sample_fmts

    struct SampleFormat: Encodable {
        let name: String
        let depth: Int
    }
    
    public let sampleFormats: [SampleFormat]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegSampleFormat.SampleFormatPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg sample format output; unexpected format")
        
        var sampleFormats: [SampleFormat] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let name = matchRegEx.matches[index, "Name"]
            let depth = Int(matchRegEx.matches[index, "Depth"])!
            
            sampleFormats.append(SampleFormat(name: name, depth: depth))
        }
        
        self.sampleFormats = sampleFormats
    }
}
