//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegDecoders: Encodable {
    private static let DecoderPattern = #"^\s(?<Support>[VASFXBD\.]{6})\s+(?<Format>\S+)\s+(?<Description>.+)$"#  // -decoders

    /*
     Values for "Support"
     
     V..... = Video
     A..... = Audio
     S..... = Subtitle
     .F.... = Frame-level multithreading
     ..S... = Slice-level multithreading
     ...X.. = Codec is experimental
     ....B. = Supports draw_horiz_band
     .....D = Supports direct rendering method 1
     */
    
    enum Support : String, Encodable {
        case video = "Video"
        case audio = "Audio"
        case subtitle = "Subtitle"
        case frameLevelMultithreading = "FrameLevelMultithreading"
        case sliceLevelMultithreading = "SliceLevelMultithreading"
        case experimentalCodec = "ExperimentalCodec"
        case drawHorizontalBandSupported = "DrawHorizontalBandSupported"
        case directRenderingMethod1Supported = "DirectRenderingMethod1Supported"
    }

    struct Decoder: Encodable {
        let format: String
        let description: String
        let support: [Support]
    }
    
    public let decoders: [Decoder]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegDecoders.DecoderPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg decoder output; unexpected format")
        
        var decoders: [Decoder] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let format = matchRegEx.matches[index, "Format"]
            let description = matchRegEx.matches[index, "Description"]
            let support = Array(matchRegEx.matches[index, "Support"])
            
            var supportFlags: [Support] = ((support[0] == "V") ? [.video] : ((support[0] == "A") ? [.audio] : ((support[0] == "S") ? [.subtitle] : [])))
            supportFlags += ((support[1] == "F") ? [.frameLevelMultithreading] : []) + ((support[2] == "S") ? [.sliceLevelMultithreading] : []) + ((support[3] == "X") ? [.experimentalCodec] : [])
            supportFlags += ((support[4] == "B") ? [.drawHorizontalBandSupported] : []) + ((support[5] == "D") ? [.directRenderingMethod1Supported] : [])

            decoders.append(Decoder(format: format, description: description, support: supportFlags))
        }
        
        self.decoders = decoders
    }
}
