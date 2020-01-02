//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegColors: Encodable {
    private static let ColorPattern = #"^(?:(?<Name>(?!name)\S+)\s+(?<RGB>(?!#RRGGBB)\S+))$"#  // -colors

    // TODO: Consider an encodable color, but really, it doesn't matter as all we're doing here is formatting for output
    //       For the other side, the caller, we should make it decode to a Color type of some sort
    struct Color: Encodable {
        let name: String
        let rgb: String
    }
    
    public let colors: [Color]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegColors.ColorPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg color output; unexpected format")
        
        var colors: [Color] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let name = matchRegEx.matches[index, "Name"]
            let rgb = matchRegEx.matches[index, "RGB"]
            
            colors.append(Color(name: name, rgb: rgb))
        }
        
        self.colors = colors
    }
}
