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

        //encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(self)) ?? Data(capacity: 0)
    }
}

struct FFmpegStatus: FFmpegOutputHandler {
    
    struct Error: Encodable {
        
        enum Domain: String, Encodable {
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
        
        public let domain: Domain
        public let message: String
        public let indent: Int
    }

    static let RegExPattern = #"(?:^.*\[(?<Domain>(?:info)|(?:error)|(?:warning))\]\s(?<Indent>\s*)(?:\:\s)*(?<Message>.*?)\s*$)|(?:^(?<oslog>(?<oslogtimestamp>\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{6}\+\d{4})(?:\s)(?<oslogprocess>\S*)\s(?<oslogmessage>.*))$)|(?:^(?<Unknown>.*)$)"#

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
    
    public let status: FFmpegStatus.Error
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegStatus.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg error output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        // First check for an "unknown" error, such as os_log, then for a known one
        if matchRegEx.matches.contains(index: 0, group: "Unknown") {
            let unknown = matchRegEx.matches[0, "Unknown"]
            status = FFmpegStatus.Error(domain: .unkown, message: unknown, indent: 0)
            
        } else if matchRegEx.matches.contains(index: 0, group: "oslog") {
            // TODO: Currently not using oslogtimestamp, oslogprocess, and oslogmessage
            // These could be extracted to return a different type of structure for debugging
            let os_log = matchRegEx.matches[0, "oslog"]
            status = FFmpegStatus.Error(domain: .os_log, message: os_log, indent: 0)
            
        } else {
            guard let domain = Error.Domain(rawValue: matchRegEx.matches[0, "Domain"]) else {
                os_log("Unknown error type in ffmpeg error output; unexpected label \"%@\"", type: OSLogType.error, matchRegEx.matches[0, "Domain"])
                return nil
            }

            let message = matchRegEx.matches[0, "Message"]
            let indent = matchRegEx.matches[0, "Indent"].count

            status = FFmpegStatus.Error(domain: domain, message: message, indent: indent)
        }
    }
    
}


struct FFmpegProgress: FFmpegOutputHandlerWithTerminators {
    
    static let RegExPattern = #"(?:frame=(?<Frame>\d+)\n)?(?:(?:.*\n)*fps=(?<Fps>[\d\.]+)\n)?(?:(?:.*\n)*(?:stream_(?<Input>\d)_(?<Stream>\d)_q)=(?<Quality>[-\d\.]+)\n)?(?:(?:.*\n)*bitrate=\s*(?<Bitrate>[\d\.]+)kbits\/s\n)?(?:(?:.*\n)*total_size=(?<TotalSize>(?:\d+)|(?:.*))\n)?(?:(?:.*\n)*out_time_ms=(?<OutTime>(?:\d+)|(?:.*))\n)?(?:(?:.*\n)*dup_frames=(?<DuplicateFrames>\d+)\n)?(?:(?:.*\n)*drop_frames=(?<DroppedFrames>\d+)\n)?(?:(?:.*\n)*speed=\s*(?<Speed>(?:[\d\.]+)|(?:.*))x?\n)?(?:(?:.*\n)*progress\s*=\s*(?<Progress>(?:continue)|(?:end)))\s*"#

    struct FFmpegProgressStruct: Encodable {
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
        var speed: Double?
        var finished: Bool
    }

    static var terminators: [Data]  {
        get {
            return ["continue\n".data(using: .utf8)!, "end\n".data(using: .utf8)!]
        }
    }
    
    public let progress: FFmpegProgressStruct
    
    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegProgress.RegExPattern, options: []), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg progress output; unexpected format", type: OSLogType.error)
            return nil
        }
        
        // Every one of these groups is optional in the pattern, and ffmpeg genuinely omits some of
        // them: the reports it emits before encoding has started carry no stream_N_N_q at all, so
        // Input/Stream/Quality do not participate in the match. Reading those through the trapping
        // subscript killed the whole task on the first such report - which is what happens as soon
        // as a transcode is slow to get going (-re, a large input, a heavy preset). An unparseable
        // progress report is not fatal; skip it and let the conversion carry on.
        let m = matchRegEx.matches
        guard let frame = m.value(0, "Frame").flatMap({ Int($0) }),
            let fps = m.value(0, "Fps").flatMap({ Double($0) }),
            let input = m.value(0, "Input").flatMap({ Int($0) }),
            let stream = m.value(0, "Stream").flatMap({ Int($0) }),
            let quality = m.value(0, "Quality").flatMap({ Double($0) }),
            let duplicateFrames = m.value(0, "DuplicateFrames").flatMap({ Int($0) }),
            let droppedFrames = m.value(0, "DroppedFrames").flatMap({ Int($0) })
             else {
            os_log("Incomplete ffmpeg progress report; skipping", type: OSLogType.debug)
            return nil
        }
        
        // The following may be present but read "N/A", in which case we leave them nil
        let bitrate = m.value(0, "Bitrate").flatMap { Double($0) }
        let totalSize = m.value(0, "TotalSize").flatMap { Int($0) }
        let ms = m.value(0, "OutTime").flatMap { TimeInterval($0) }
        let speed = m.value(0, "Speed").flatMap { Double($0) }
        
        self.progress = FFmpegProgressStruct(frame: frame, fps: fps, input: input, stream: stream, quality: quality, bitrate: bitrate, totalSize: totalSize, outTime: ms == nil ? nil : ms! / 1000000.0, duplicateFrames: duplicateFrames, droppedFrames: droppedFrames, speed: speed, finished: m.value(0, "Progress") == "end")
    }
    
}


struct FFmpegCodecs: FFmpegOutputHandler {
    static let RegExPattern = #"^\s(?<Support>[DEVASILS\.]{6})\s+(?<Format>[^=]\S+)\s+(?<Description>.+)$"#  // -codecs

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
    static let RegExPattern = #"^(?<Filter>(?!Bitstream filters:)\S+)$"#  // -bsfs
    
    public let bitstreamFilters: [String]
    
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
        
        self.bitstreamFilters = filters
    }
}


struct FFmpegColors: FFmpegOutputHandler {
    static let RegExPattern = #"^(?:(?<Name>(?!name)\S+)\s+(?<RGB>(?!#RRGGBB)\S+))$"#  // -colors

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
    static let RegExPattern = #"^\s(?<Support>[VASFXBD\.]{6})\s+(?<Format>[^=]\S+)\s+(?<Description>.+)$"#  // -decoders

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


struct FFmpegEncoders: FFmpegOutputHandler {
    // FFmpeg prints encoders and decoders through the same routine (fftools/opt_common.c,
    // print_codecs) with the same flag legend, so this is FFmpegDecoders with a different key.
    static let RegExPattern = #"^\s(?<Support>[VASFXBD\.]{6})\s+(?<Format>[^=]\S+)\s+(?<Description>.+)$"#  // -encoders

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

    struct Encoder: Encodable {
        let format: String
        let description: String
        let support: [Support]
    }

    public let encoders: [Encoder]

    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegEncoders.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg encoder output; unexpected format", type: OSLogType.error)
            return nil
        }

        var encoders: [Encoder] = []

        for index in 0...matchRegEx.matches.count - 1 {
            let format = matchRegEx.matches[index, "Format"]
            let description = matchRegEx.matches[index, "Description"]
            let support = Array(matchRegEx.matches[index, "Support"])

            var supportFlags: [Support] = ((support[0] == "V") ? [.video] : ((support[0] == "A") ? [.audio] : ((support[0] == "S") ? [.subtitle] : [])))
            supportFlags += ((support[1] == "F") ? [.frameLevelMultithreading] : []) + ((support[2] == "S") ? [.sliceLevelMultithreading] : []) + ((support[3] == "X") ? [.experimentalCodec] : [])
            supportFlags += ((support[4] == "B") ? [.drawHorizontalBandSupported] : []) + ((support[5] == "D") ? [.directRenderingMethod1Supported] : [])

            encoders.append(Encoder(format: format, description: description, support: supportFlags))
        }
        
        self.encoders = encoders
    }
}


struct FFmpegFilters: FFmpegOutputHandler {
    // FFmpeg prints " %c%c %-17s %-10s %s" (fftools/opt_common.c, show_filters): two flag
    // characters. The command-support column that used to make a third is gone.
    static let RegExPattern = #"^\s(?<Support>[TS\.]{2})\s+(?<Filter>\S+)\s+(?<Workflow>\S+)\s+(?<Description>.+)$"#  // -filters

    /*
     Values for "Support"
     
     T. = Timeline support
     .S = Slice threading
     A = Audio input/output
     V = Video input/output
     N = Dynamic number and/or type of input/output
     | = Source or sink filter
     */
    
    enum Support : String, Encodable {
        case timeline
        case slice
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

            let supportFlags: [Support] = (support.first == "T" ? [.timeline] : [])
                + (support.count > 1 && support[1] == "S" ? [.slice] : [])
             
            filters.append(Filter(filter: filter, description: description, workflow: workflow, support: supportFlags))
        }
        
        self.filters = filters
    }
}


struct FFmpegFormats: FFmpegOutputHandler {
    // FFmpeg prints " %c%c%s %-15s %s" (show_formats_devices), where the third field is "d" for a
    // device and "." otherwise - except under -devices, where it is omitted entirely. So the flag
    // field is three characters for -formats/-muxers/-demuxers and two for -devices, and {2,3}
    // covers both. The old {2} silently dropped every device row from the first three.
    static let RegExPattern = #"^\s(?<Support>[DEd\s]{2,3})\s(?<Format>\S+)\s+(?<Description>.+)$"#  // -formats, -demuxers, -muxers, -devices
    
    enum Support : String, Encodable {
        case muxing
        case demuxing
        case device
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
            
            let supportFlags: [Support] = (support.first == "D" ? [.demuxing] : [])
                + (support.count > 1 && support[1] == "E" ? [.muxing] : [])
                + (support.count > 2 && support[2] == "d" ? [.device] : [])
            
            formats.append(Format(format: format, description: description, support: supportFlags))
        }
        
        self.formats = formats
    }
}


struct FFmpegLayouts: FFmpegOutputHandler {
    static let RegExPattern = #"^(?:(?<Individual>Individual)|(?<Standard>Standard))+|^(?:(?<Name>(?!NAME|Individual|Standard)\S+)\s+(?<Description>(?!DESCRIPTION).+))$"#  // -layouts, a bit different in that Individual/Standard are states
    
    struct Layout: Encodable {
        let name: String
        let description: String
    }
    
    struct FFmpegLayoutsStruct: Encodable {
        let individual: [Layout]
        let standard: [Layout]
    }

    enum AddToLayoutList {
        case none
        case individual
        case standard
    }
    
    public let layouts: FFmpegLayoutsStruct
    

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
        
        self.layouts = FFmpegLayoutsStruct(individual: individual, standard: standard)
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
    // FFmpeg prints "%c%c%c%c%c %-16s       %d            %3d      %d[-%d...]" (show_pix_fmts):
    // the trailing BIT_DEPTHS column is what the old $-anchor here rejected, silently, on every
    // single line.
    static let RegExPattern = #"^(?<Support>[IOHPB\.]{5})\s+(?<Filter>\S+)\s+(?<Components>\d+)\s+(?<BitsPerPixel>\d+)\s+(?<BitDepths>\d+(?:-\d+)*)$"#  // -pix_fmts

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
        /// Per-component bit depths as ffmpeg reports them, e.g. "8-8-8".
        let bitDepths: String
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
            let components = Int(matchRegEx.matches[index, "Components"]) ?? 0
            let bitsPerPixel = Int(matchRegEx.matches[index, "BitsPerPixel"]) ?? 0
            let bitDepths = matchRegEx.matches.value(index, "BitDepths") ?? ""
            let support = Array(matchRegEx.matches[index, "Support"])

            var supportFlags: [Support] = (support[0] == "I" ? [.input] : []) + ((support[1] == "O") ? [.output] : [])
            supportFlags += ((support[2] == "H") ? [.hardwareAccelerated] : [])
            supportFlags += ((support[3] == "P") ? [.paletted] : []) + ((support[4] == "B") ? [.bitstream] : [])
            
            pixelFormats.append(PixelFormat(filter: filter, components: components, bitsPerPixel: bitsPerPixel, bitDepths: bitDepths, support: supportFlags))
        }
        
        self.pixelFormats = pixelFormats
    }
}


struct FFmpegProtocols: FFmpegOutputHandler {
    static let RegExPattern = #"(?:(?:(?<Input>Input):\n)+|(?:(?<Output>Output):\n)+)|^\s\s(?<Protocol>\S+)*$"#  // -protocols, a bit different in that Input/Output are states
    
    struct FFmpegProtocolsStruct: Encodable {
        let input: [String]
        let output: [String]
    }
    
    enum AddToProtocolList {
        case none
        case input
        case output
    }
    
    public let protocols: FFmpegProtocolsStruct
    
    
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
        
        self.protocols = FFmpegProtocolsStruct(input: inputProtocols, output: outputProtocols)
    }
}


struct FFmpegSampleFormats: FFmpegOutputHandler {
    static let RegExPattern = #"^(?<Name>(?!name)\S+)\s*(?<Depth>(?!depth)\d+)\s*$"#  // -sample_fmts

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
    static let RegExPattern = #"^(?:FFmpegTask version (?<Version>\S+)\s(?<FFmpegCopyright>.*)\nbuilt with (?<Compiler>.*)\nconfiguration: (?<Configuration>.*)\n)|(?:(?<Library>lib\S+)\s*(?<Major>\d+)\.\s*(?<Minor>\d+)\.\s*(?<Build>\d+))"#  // -version
    
    struct FFmpegVersionStruct: Encodable {
        let version: String
        let compiler: String
        let ffmpegCopyright: String
        let configuration: String
        var libraries: [String : String]
    }
    
    public let version: FFmpegVersionStruct

    
    init?(from: Data) {
        guard let matchRegEx = MatchRegularExpression(in: from, pattern: FFmpegVersion.RegExPattern, options: .anchorsMatchLines), matchRegEx.matches.count >= 1 else {
            os_log("Invalid ffmpeg version output; unexpected format", type: OSLogType.error)
            return nil
        }

        let m = matchRegEx.matches

        // The pattern alternates between the header block and a library line, so which match is
        // which is not fixed - find the header rather than assuming it is first, and read every
        // group through the non-trapping accessor.
        var header: Int?
        var libraries: [String : String] = [:]

        for index in 0..<m.count {
            if m.value(index, "Version") != nil {
                header = header ?? index

            } else if let library = m.value(index, "Library"),
                      let major = m.value(index, "Major"),
                      let minor = m.value(index, "Minor"),
                      let build = m.value(index, "Build") {
                libraries[library] = "\(major).\(minor).\(build)"
            }
        }

        guard let headerIndex = header else {
            os_log("ffmpeg version output carried no version header", type: OSLogType.error)
            return nil
        }

        // Strip absolute paths out of the configuration; they are this machine's, not information.
        let configuration = (m.value(headerIndex, "Configuration") ?? "")
            .replacingOccurrences(of: #"--\S+=\/\S+\s+"#, with: "", options: .regularExpression)

        self.version = FFmpegVersionStruct(version: m.value(headerIndex, "Version") ?? "",
                                           compiler: m.value(headerIndex, "Compiler") ?? "",
                                           ffmpegCopyright: m.value(headerIndex, "FFmpegCopyright") ?? "",
                                           configuration: configuration,
                                           libraries: libraries)
    }
}

