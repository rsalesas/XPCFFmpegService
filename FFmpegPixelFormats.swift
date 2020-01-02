//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegPixelFormats: Encodable {
    private static let PixelFormatsPattern = #"^(?<Support>[IOHPB\.]{5})\s+(?<Filter>\S+)\s+(?<Components>\d+)\s+(?<BitsPerPixel>\d+)$"#  // -pix_fmts

    /*
     Values for "Support"
     
     I.... = Supported Input  format for conversion
     .O... = Supported Output format for conversion
     ..H.. = Hardware accelerated format
     ...P. = Paletted format
     ....B = Bitstream format
     */
    
    enum Support : String, Encodable {
        case input = "Input"
        case output = "Output"
        case hardwareAccelerated = "HardwareAccelerated"
        case paletted = "Paletted"
        case bitstream = "Bitstream"
    }
    
    struct PixelFormat: Encodable {
        let filter: String
        let components: Int
        let bitsPerPixel: Int
        let support: [Support]
    }
    
    public let pixelFormats: [PixelFormat]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegPixelFormats.PixelFormatsPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg pixel format output; unexpected format")
        
        var pixelFormats: [PixelFormat] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let filter = matchRegEx.matches[index, "Filter"]
            let components = Int(matchRegEx.matches[index, "Components"])!
            let bitsPerPixel = Int(matchRegEx.matches[index, "BitsPerPixel"])!
            let support = Array(matchRegEx.matches[index, "Support"])

            var supportFlags: [Support] = (support[0] == "I" ? [.input] : []) + ((support[1] == "O") ? [.output] : [])
            supportFlags += ((support[2] == "H") ? [.hardwareAccelerated] : [])
            supportFlags += ((support[3] == "P") ? [.paletted] : []) + ((support[4] == "B") ? [.bitstream] : [])
            
            pixelFormats.append(PixelFormat(filter: filter, components: components, bitsPerPixel: bitsPerPixel, support: supportFlags))
        }
        
        self.pixelFormats = pixelFormats
    }
}
