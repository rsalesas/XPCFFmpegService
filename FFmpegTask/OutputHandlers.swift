//
//  FFmpegOutputProtocol.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe/ffmpeg into classes compatible with Encodable and returns JSON data


import Foundation
import SiliconInk_Helper
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


protocol FFmpegOutputHandler: Encodable {
    var JSON: Data { get }
    init?(from: Data)
}

protocol FFmpegOutputHandlerWithTerminators: FFmpegOutputHandler {
    static var terminators: [Data] { get }
}

extension FFmpegOutputHandler {
    
    var JSON: Data {
        let encoder = JSONEncoder()
        
        #if DEBUG
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted]
        #else
            encoder.outputFormatting = [.withoutEscapingSlashes]
        #endif
        
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(self)) ?? Data(capacity: 0)
    }
}

struct FFmpegError: FFmpegOutputHandler {
    
    struct Error: Encodable {
        
        enum ErrorType: String, Encodable {
            case unkown
            case os_log
            case quiet
            case panic
            case fatal
            case error
            case warning
            case info
            case verbose
            case debug
            case trace
        }
        
        public let type: ErrorType
        public let description: String
        public let indent: Int
    }

    private static let RegExPattern = #"(?:^.*\[(?<Type>(?:info)|(?:error)|(?:warning))\]\s(?<Indent>\s*)(?:\:\s)*(?<Description>.*?)\s*$)|(?:^(?<oslog>(?<oslogtimestamp>\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{6}\+\d{4})(?:\s)(?<oslogprocess>\S*)\s(?<oslogmessage>.*))$)|(?:^(?<Unknown>.*)$)"#

    /*
     
     Example:
     
        For ffmpeg errors with a prefix:
     
            [error] /Users/robert/Git/XPCFFmpegService/../Test/Test1.mp4: No such file or directory
     
        or for os_log (caught as "oslog"):
     
            2020-04-03 13:59:08.858260+0800 FFmpegTask[16639:6410797] Test
     
        or for unknown (caught as "Unknown"):
     
            Anything that we don't understand
     
     
     Possible ffmpeg prefix values:
     
         ‘quiet, -8’        Show nothing at all; be silent.

         ‘panic, 0’         Only show fatal errors which could lead the process to crash, such as an assertion failure. This is not currently used for anything.

         ‘fatal, 8’         Only show fatal errors. These are errors after which the process absolutely cannot continue.

         ‘error, 16’        Show all errors, including ones which can be recovered from.

         ‘warning, 24’      Show all warnings and errors. Any message related to possibly incorrect or unexpected events will be shown.

         ‘info, 32’         Show informative messages during processing. This is in addition to warnings and errors. This is the default value.

         ‘verbose, 40’      Same as info, except more verbose.

         ‘debug, 48’        Show everything, including debugging information.

         ‘trace, 56’        ?
     
     */
    
    public let error: FFmpegError.Error
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegError.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg error output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        // First check for an "unknown" error, such as os_log, then for a known one
        if matchRegEx.matches.contains(index: 0, group: "Unknown") {
            let unknown = matchRegEx.matches[0, "Unknown"]
            error = FFmpegError.Error(type: .unkown, description: unknown, indent: 0)
            
        } else if matchRegEx.matches.contains(index: 0, group: "oslog") {
            // TODO: Currently not using oslogtimestamp, oslogprocess, and oslogmessage
            // These could be extracted to return a different type of structure for debugging
            let os_log = matchRegEx.matches[0, "oslog"]
            error = FFmpegError.Error(type: .os_log, description: os_log, indent: 0)
            
        } else {
            guard let type = Error.ErrorType(rawValue: matchRegEx.matches[0, "Type"]) else {
                os_log("Unknown error type in ffmpeg error output; unexpected label \"%@\"", type: OSLogType.error, matchRegEx.matches[0, "Type"])
                return nil
            }

            let description = matchRegEx.matches[0, "Description"]
            let indent = matchRegEx.matches[0, "Indent"].count

            error = FFmpegError.Error(type: type, description: description, indent: indent)
        }
    }
    
}


struct FFmpegProgress: FFmpegOutputHandlerWithTerminators {
    
    private static let RegExPattern = #"(?:frame=(?<Frame>\d+)\n)?(?:(?:.*\n)*fps=(?<Fps>[\d\.]+)\n)?(?:(?:.*\n)*(?:stream_(?<Input>\d)_(?<Stream>\d)_q)=(?<Quality>[-\d\.]+)\n)?(?:(?:.*\n)*bitrate=\s*(?<Bitrate>[\d\.]+)kbits\/s\n)?(?:(?:.*\n)*total_size=(?<TotalSize>(?:\d+)|(?:.*))\n)?(?:(?:.*\n)*out_time_ms=(?<OutTime>(?:\d+)|(?:.*))\n)?(?:(?:.*\n)*dup_frames=(?<DuplicateFrames>\d+)\n)?(?:(?:.*\n)*drop_frames=(?<DroppedFrames>\d+)\n)?(?:(?:.*\n)*speed=\s*(?<Speed>(?:[\d\.]+)|(?:.*))x?\n)?(?:(?:.*\n)*progress\s*=\s*(?<Progress>(?:continue)|(?:end)))\s*"#

    var frame: Int
    var fps: Double
    var input: Int
    var stream: Int
    var quality: Double
    var bitrate: Double?
    var totalSize: Int?
    var outTime: TimeInterval?
    var duplicateFrames: Int
    var droppedFrames: Int
    var speed: Int?
    var finished: Bool

    static var terminators: [Data]  {
        get {
            return ["continue\n".data(using: .utf8)!, "end\n".data(using: .utf8)!]
        }
    }
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegProgress.RegExPattern, options: []), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg progress output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        // The following must be included and convert properly
        guard let frame = Int(matchRegEx.matches[0, "Frame"]), let fps = Double(matchRegEx.matches[0, "Fps"]),
            let input = Int(matchRegEx.matches[0, "Input"]), let stream = Int(matchRegEx.matches[0, "Stream"]),
            let quality = Double(matchRegEx.matches[0, "Quality"]), let duplicateFrames = Int(matchRegEx.matches[0, "DuplicateFrames"]),
            let droppedFrames = Int(matchRegEx.matches[0, "DroppedFrames"])
             else {
            fatalError("Invalid ffmpeg progress output; unexpected format")
        }
        
        // The following must be included but could convert to "N/A" in which case we leave them nil
        let bitrate = Double(matchRegEx.matches[0, "Bitrate"])
        let totalSize = Int(matchRegEx.matches[0, "TotalSize"])
        let ms = TimeInterval(matchRegEx.matches[0, "OutTime"])
        let speed = Int(matchRegEx.matches[0, "Speed"])
        
        self.frame = frame
        self.fps = fps
        self.input = input
        self.stream = stream
        self.quality = quality
        self.bitrate = bitrate
        self.totalSize = totalSize
        self.outTime = ms == nil ? nil : ms! / 1000000.0
        self.duplicateFrames = duplicateFrames
        self.droppedFrames = droppedFrames
        self.speed = speed
        self.finished = matchRegEx.matches[0, "Progress"] == "end"
    }
    
}


struct FFmpegCodecs: FFmpegOutputHandler {
    private static let RegExPattern = #"^\s(?<Support>[DEVASILS\.]{6})\s+(?<Format>[^=]\S+)\s+(?<Description>.+)$"#  // -codecs

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
        case decoding
        case encoding
        case videoCodec
        case audioCodec
        case subtitleCodec
        case intraFrameOnlyCodec
        case lossyCompression
        case losslessCompression
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
    private static let RegExPattern = #"^(?<Filter>(?!Bitstream filters:)\S+)$"#  // -bsfs
    
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
    private static let RegExPattern = #"^\s(?<Support>[VASFXBD\.]{6})\s+(?<Format>[^=]\S+)\s+(?<Description>.+)$"#  // -decoders

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
        case video
        case audio
        case subtitle
        case frameLevelMultithreading
        case sliceLevelMultithreading
        case experimentalCodec
        case drawHorizontalBandSupported
        case directRenderingMethod1Supported
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
        case timeline
        case slice
        case command
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
        case muxing
        case demuxing
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
        case input
        case output
        case hardwareAccelerated
        case paletted
        case bitstream
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
        
        // Retrieve the configuration but remove reference to folders
        self.configuration = matchRegEx.matches[0, "Configuration"].replacingOccurrences(of: #"--\S+=\/\S+\s+"#, with: "", options: .regularExpression)
                
        for index in 2...matchRegEx.matches.count - 1 {
            let library = matchRegEx.matches[index, "Library"]
            let major = matchRegEx.matches[index, "Major"]
            let minor = matchRegEx.matches[index, "Minor"]
            let build = matchRegEx.matches[index, "Build"]

            libraries[library] = "\(major).\(minor).\(build)"
        }
    }
}

