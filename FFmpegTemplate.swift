//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


struct FFmpegFormats: Encodable {
    private static let FormatPattern = #"^\s{1,2}(?<Support>D?E?)\s+(?<Format>\S+)\s+(?<Description>.*)$"#  // -formats, -demuxers, -muxers, -devices
    
    struct Format: Encodable {
        let format: String
        let description: String
        let support: String
    }
    
    public let formats: [Format]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg version output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegFormats.FormatPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg format output; unexpected format")
        
        var formats: [Format] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let format = matchRegEx.matches[index, "Format"]
            let description = matchRegEx.matches[index, "Description"]
            let support = matchRegEx.matches[index, "Support"]
            
            formats.append(Format(format: format, description: description, support: support))
        }
        
        self.formats = formats
    }
}
