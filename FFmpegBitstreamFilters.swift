//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegBitstreamFilters: Encodable {
    private static let BitstreamFilterPattern = #"^(?<Filter>(?!Bitstream filters:)\S+)$"#  // -filters
    
    public let filters: [String]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegBitstreamFilters.BitstreamFilterPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg bitstream filter output; unexpected format")
        
        var filters: [String] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let filter = matchRegEx.matches[index, "Filter"]
            filters.append(filter)
        }
        
        self.filters = filters
    }
}
