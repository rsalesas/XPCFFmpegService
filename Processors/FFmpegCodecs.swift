//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegCodecs: Encodable {
    private static let CodecPattern = #"^\s(?<Support>[DEVASILS\.]{6})\s+(?<Format>\S+)\s+(?<Description>.+)$"#  // -codecs

    /*
     Values for "Support"
     
     D..... = Decoding supported
     .E.... = Encoding supported
     ..V... = Video codec
     ..A... = Audio codec
     ..S... = Subtitle codec
     ...I.. = Intra frame-only codec
     ....L. = Lossy compression
     .....S = Lossless compression
     */
    
    enum Support : String, Encodable {
        case decoding = "Decoding"
        case encoding = "Encoding"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case subtitleCodec = "SubtitleCodec"
        case intraFrameOnlyCodec = "IntraFrameOnlyCodec"
        case lossyCompression = "LossyCompression"
        case losslessCompression = "LosslessCompression"
    }

    struct Codec: Encodable {
        let format: String
        let description: String
        let support: [Support]
    }
    
    public let codecs: [Codec]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegCodecs.CodecPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg codec output; unexpected format")
        
        var codecs: [Codec] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let format = matchRegEx.matches[index, "Format"]
            let description = matchRegEx.matches[index, "Description"]
            let support = Array(matchRegEx.matches[index, "Support"])
            
            var supportFlags: [Support] = (support[0] == "D" ? [.decoding] : []) + ((support[1] == "E") ? [.encoding] : [])
            supportFlags += ((support[2] == "V") ? [.videoCodec] : ((support[2] == "A") ? [.audioCodec] : ((support[2] == "S") ? [.subtitleCodec] : [])))
            supportFlags += ((support[3] == "I") ? [.intraFrameOnlyCodec] : []) + ((support[4] == "L") ? [.lossyCompression] : []) + ((support[5] == "S") ? [.losslessCompression] : [])
            
            codecs.append(Codec(format: format, description: description, support: supportFlags))
        }
        
        self.codecs = codecs
    }
}
