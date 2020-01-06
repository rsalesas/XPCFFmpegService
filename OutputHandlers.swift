//
//  FFmpegOutputProtocol.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe/ffmpeg into classes compatible with Encodable and returns JSON data


import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


protocol FFmpegOutputHandler: Encodable {
    init?(from: Data)
    
    func toJSONData() -> Data?
}

extension FFmpegOutputHandler {
    
    func toJSONData() -> Data?{
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes] //, .sortedKeys, .prettyPrinted]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        return try? encoder.encode(self)
    }
}

struct FFmpegError {
    private static let RegExPattern = #"(?:^.*\[(?<Type>(?:info)|(?:error)|(?:warning))\]\s(?:\:\s)*(?<Description>.*?)\s*$)|(?:^(?<Unknown>.*)$)"#

    struct Error: Encodable {
        public let type: String
        public let description: String
        
        func toJSONData() -> Data?{
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes] //, .sortedKeys, .prettyPrinted]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            
            return try? encoder.encode(self)
        }
    }
    
    public let errors: [Error]
        

    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegError.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg error output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var errors: [Error] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            if matchRegEx.matches.contains(index: index, group: "Unknown") {
                let description = matchRegEx.matches[index, "Unknown"]
                
                errors.append(Error(type: "info", description: description))
                
            } else {
                let type = matchRegEx.matches[index, "Type"]
                let description = matchRegEx.matches[index, "Description"]
                    
                errors.append(Error(type: type, description: description))
            }
        }
        
        self.errors = errors
    }
}


struct FFmpegCodecs: FFmpegOutputHandler {
    private static let RegExPattern = #"^\s(?<Support>[DEVASILS\.]{6})\s+(?<Format>\S+)\s+(?<Description>.+)$"#  // -codecs

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
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegCodecs.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg codec output; unexpected format", type: OSLogType.error)
            return nil
        }
        
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


struct FFmpegBitstreamFilters: FFmpegOutputHandler {
    private static let RegExPattern = #"^(?<Filter>(?!Bitstream filters:)\S+)$"#  // -filters
    
    public let filters: [String]
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegBitstreamFilters.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg bitstream output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var filters: [String] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let filter = matchRegEx.matches[index, "Filter"]
            filters.append(filter)
        }
        
        self.filters = filters
    }
}


struct FFmpegColors: FFmpegOutputHandler {
    private static let RegExPattern = #"^(?:(?<Name>(?!name)\S+)\s+(?<RGB>(?!#RRGGBB)\S+))$"#  // -colors

    // TODO: Consider an encodable color, but really, it doesn't matter as all we're doing here is formatting for output
    //       For the other side, the caller, we should make it decode to a Color type of some sort
    struct Color: Encodable {
        let name: String
        let rgb: String
    }
    
    public let colors: [Color]
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegColors.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg color output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var colors: [Color] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let name = matchRegEx.matches[index, "Name"]
            let rgb = matchRegEx.matches[index, "RGB"]
            
            colors.append(Color(name: name, rgb: rgb))
        }
        
        self.colors = colors
    }
}


struct FFmpegDecoders: FFmpegOutputHandler {
    private static let RegExPattern = #"^\s(?<Support>[VASFXBD\.]{6})\s+(?<Format>\S+)\s+(?<Description>.+)$"#  // -decoders

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
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegDecoders.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg decoder output; unexpected format", type: OSLogType.error)
            return nil
        }
        
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


struct FFmpegFilters: FFmpegOutputHandler {
    private static let RegExPattern = #"^\s(?<Support>[TSCAVNI\.]{3})\s+(?<Filter>\S+)\s+(?<Workflow>\S+)\s+(?<Description>.+)$"#  // -filters

    /*
     Values for "Support"
     
     T.. = Timeline support
     .S. = Slice threading
     ..C = Command support
     A = Audio input/output
     V = Video input/output
     N = Dynamic number and/or type of input/output
     | = Source or sink filter
     */
    
    enum Support : String, Encodable {
        case timeline = "Timeline"
        case slice = "Slice"
        case command = "Command"
    }
    
    struct Filter: Encodable {
        let filter: String
        let description: String
        let workflow: String
        let support: [Support]
    }
    
    public let filters: [Filter]
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegFilters.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg filter output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var filters: [Filter] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let filter = matchRegEx.matches[index, "Filter"]
            let description = matchRegEx.matches[index, "Description"]
            let workflow = matchRegEx.matches[index, "Workflow"]
            let support = Array(matchRegEx.matches[index, "Support"])

            let supportFlags: [Support] = (support[0] == "T" ? [.timeline] : []) + ((support[1] == "S") ? [.slice] : []) + ((support[2] == "C") ? [.command] : [])
             
            filters.append(Filter(filter: filter, description: description, workflow: workflow, support: supportFlags))
        }
        
        self.filters = filters
    }
}


struct FFmpegFormats: FFmpegOutputHandler {
    private static let RegExPattern = #"^\s{1,2}(?<Support>[DE\s]{2})\s+(?<Format>\S+)\s+(?<Description>.+)$"#  // -formats, -demuxers, -muxers, -devices
    
    enum Support : String, Encodable {
        case muxing = "Muxing"
        case demuxing = "Demuxing"
    }
    
    struct Format: Encodable {
        let format: String
        let description: String
        let support: [Support]
    }
    
    public let formats: [Format]
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegFormats.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg format output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var formats: [Format] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let format = matchRegEx.matches[index, "Format"]
            let description = matchRegEx.matches[index, "Description"]
            let support = Array(matchRegEx.matches[index, "Support"])
            
            let supportFlags: [Support] = (support[0] == "D" ? [.demuxing] : []) + ((support[1] == "E") ? [.muxing] : [])
            
            formats.append(Format(format: format, description: description, support: supportFlags))
        }
        
        self.formats = formats
    }
}


struct FFmpegLayouts: FFmpegOutputHandler {
    private static let RegExPattern = #"^(?:(?<Individual>Individual)|(?<Standard>Standard))+|^(?:(?<Name>(?!NAME|Individual|Standard)\S+)\s+(?<Description>(?!DESCRIPTION).+))$"#  // -layouts, a bit different in that Individual/Standard are states
    
    struct Layout: Encodable {
        let name: String
        let description: String
    }
    
    public let individual: [Layout]
    public let standard: [Layout]

    enum AddToLayoutList {
        case none
        case individual
        case standard
    }

    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegLayouts.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg layout output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var individual: [Layout] = []
        var standard: [Layout] = []
        var addToLayoutList: AddToLayoutList = .none

        for index in 0...matchRegEx.matches.count - 1 {
            if matchRegEx.matches.contains(index: index, group: "Individual") {
                addToLayoutList = .individual;
            } else if matchRegEx.matches.contains(index: index, group: "Standard") {
                addToLayoutList = .standard;
            } else if addToLayoutList != .none {
                let name = matchRegEx.matches[index, "Name"]
                let description = matchRegEx.matches[index, "Description"]
            
                if addToLayoutList == .individual {
                    individual.append(Layout(name: name, description: description))
                } else if addToLayoutList == .standard {
                    standard.append(Layout(name: name, description: description))
                }
            }
        }
        
        self.individual = individual
        self.standard = standard
    }
}


struct FFmpegLicense: FFmpegOutputHandler {
    let license: String
    
    init?(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            os_log("Invalid ffmpeg license output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        self.license = data;
    }
}


struct FFmpegPixelFormats: FFmpegOutputHandler {
    private static let RegExPattern = #"^(?<Support>[IOHPB\.]{5})\s+(?<Filter>\S+)\s+(?<Components>\d+)\s+(?<BitsPerPixel>\d+)$"#  // -pix_fmts

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
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegPixelFormats.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg pixel format output; unexpected format", type: OSLogType.error)
            return nil
        }
        
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


struct FFmpegProtocols: FFmpegOutputHandler {
    private static let RegExPattern = #"(?:(?:(?<Input>Input):\n)+|(?:(?<Output>Output):\n)+)|^\s\s(?<Protocol>\S+)*$"#  // -protocols, a bit different in that Input/Output are states
    
    public let input: [String]
    public let output: [String]
    
    enum AddToProtocolList {
        case none
        case input
        case output
    }
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegProtocols.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg protocol output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var inputProtocols: [String] = []
        var outputProtocols: [String] = []
        var addToProtocolList: AddToProtocolList = .none
        
        for index in 0...matchRegEx.matches.count - 1 {
            if matchRegEx.matches.contains(index: index, group: "Input") {
                addToProtocolList = .input;
            } else if matchRegEx.matches.contains(index: index, group: "Output") {
                addToProtocolList = .output;
            } else if addToProtocolList != .none {
                let protocolName = matchRegEx.matches[index, "Protocol"]
                if addToProtocolList == .input {
                    inputProtocols.append(protocolName)
                } else if addToProtocolList == .output {
                    outputProtocols.append(protocolName)
                }
            }
        }
        
        input = inputProtocols
        output = outputProtocols
    }
}


struct FFmpegSampleFormats: FFmpegOutputHandler {
    private static let RegExPattern = #"^(?<Name>(?!name)\S+)\s*(?<Depth>(?!depth)\d+)\s*$"#  // -sample_fmts

    struct SampleFormat: Encodable {
        let name: String
        let depth: Int
    }
    
    public let sampleFormats: [SampleFormat]
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegSampleFormats.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg sample format output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        var sampleFormats: [SampleFormat] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let name = matchRegEx.matches[index, "Name"]
            let depth = Int(matchRegEx.matches[index, "Depth"])!
            
            sampleFormats.append(SampleFormat(name: name, depth: depth))
        }
        
        self.sampleFormats = sampleFormats
    }
}


struct FFmpegVersion: FFmpegOutputHandler {
    private static let RegExPattern = #"^(?:FFmpegTask version (?<Version>\S+)\s(?<FFmpegCopyright>.*)\nbuilt with (?<Compiler>.*)\nconfiguration: (?<Configuration>.*)\n)|(?:(?<Library>lib\S+)\s*(?<Major>\d+)\.\s*(?<Minor>\d+)\.\s*(?<Build>\d+))"#  // -version
    
    public let version: String
    public let compiler: String
    public let ffmpegCopyright: String
    public let configuration: String
    public var libraries: [String : String] = [:]

    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegVersion.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg version output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        self.version = matchRegEx.matches[0, "Version"]
        self.compiler = matchRegEx.matches[0, "Compiler"]
        self.ffmpegCopyright = matchRegEx.matches[0, "FFmpegCopyright"]
        self.configuration = matchRegEx.matches[0, "Configuration"]
        
        for index in 2...matchRegEx.matches.count - 1 {
            let library = matchRegEx.matches[index, "Library"]
            let major = matchRegEx.matches[index, "Major"]
            let minor = matchRegEx.matches[index, "Minor"]
            let build = matchRegEx.matches[index, "Build"]

            libraries[library] = "\(major).\(minor).\(build)"
        }
    }
}
