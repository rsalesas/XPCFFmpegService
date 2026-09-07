//
//  Conversion.swift
//  XPCFFmpeg
//
//  A conversion described as values rather than as a string array. Anything this model cannot
//  express can be appended raw at the level it belongs to, so the typed surface never becomes a
//  ceiling.
//

import Foundation


public struct VideoSettings: Equatable {
    public var codec: VideoCodec?
    public var bitrate: Bitrate?
    /// Constant quality (x264/x265 -crf). Lower is better; ignored when `bitrate` is set, and
    /// meaningless to a hardware encoder, which only understands a rate.
    public var quality: Int?
    /// A ceiling on the rate, with `bufferSize` the window it is measured over. Both are needed
    /// for either to mean anything - a maxrate without a bufsize is ignored by x264 - and together
    /// with `bitrate` they are what constrained ("VBV") delivery is made of.
    public var maxBitrate: Bitrate?
    public var bufferSize: Bitrate?
    /// Frames between keyframes (-g). Streaming formats want this pinned to a multiple of the
    /// segment length; leaving it nil lets the encoder decide.
    public var keyframeInterval: Int?
    /// Encoder profile and level - "high", "main10", "4.1". A player that refuses a file it should
    /// play is usually a profile it does not implement.
    public var profile: String?
    public var level: String?
    /// x264/x265 tuning - "film", "animation", "grain", "zerolatency".
    public var tune: String?
    public var size: FrameSize?
    public var frameRate: Double?
    public var preset: EncoderPreset?
    public var pixelFormat: String?
    /// What colour the output is in. See `ColorProperties`.
    public var colorProperties: ColorProperties?
    /// Encode in two passes: a first that measures and a second that spends the bitrate where the
    /// first found it was needed. Only means anything with `bitrate` set - there is nothing for a
    /// second pass to do when the target is a quality rather than a size.
    public var isTwoPass: Bool
    /// Options handed straight to the encoder as `-<name> <value>`. Put a whole private parameter
    /// blob in as one value: `["x264-params": "keyint=50:min-keyint=50"]`.
    public var encoderOptions: [String : String]
    /// Drop video from the output entirely (-vn). Everything else here is ignored when set.
    public var isDisabled: Bool
    public var additionalOptions: [String]

    public init(codec: VideoCodec? = nil, bitrate: Bitrate? = nil, quality: Int? = nil,
                maxBitrate: Bitrate? = nil, bufferSize: Bitrate? = nil,
                keyframeInterval: Int? = nil, profile: String? = nil, level: String? = nil,
                tune: String? = nil, size: FrameSize? = nil, frameRate: Double? = nil,
                preset: EncoderPreset? = nil, pixelFormat: String? = nil,
                colorProperties: ColorProperties? = nil, isTwoPass: Bool = false,
                encoderOptions: [String : String] = [:], isDisabled: Bool = false,
                additionalOptions: [String] = []) {
        self.codec = codec
        self.bitrate = bitrate
        self.quality = quality
        self.maxBitrate = maxBitrate
        self.bufferSize = bufferSize
        self.keyframeInterval = keyframeInterval
        self.profile = profile
        self.level = level
        self.tune = tune
        self.size = size
        self.frameRate = frameRate
        self.preset = preset
        self.pixelFormat = pixelFormat
        self.colorProperties = colorProperties
        self.isTwoPass = isTwoPass
        self.encoderOptions = encoderOptions
        self.isDisabled = isDisabled
        self.additionalOptions = additionalOptions
    }

    public static func h264(quality: Int = 23, preset: EncoderPreset = .medium) -> VideoSettings {
        return VideoSettings(codec: .h264, quality: quality, preset: preset)
    }

    public static func hevc(quality: Int = 28, preset: EncoderPreset = .medium) -> VideoSettings {
        return VideoSettings(codec: .hevc, quality: quality, preset: preset)
    }

    /// H.264 on the media engine. Takes a bitrate because that is all a hardware encoder accepts -
    /// no CRF, no preset. Check `FFmpeg.hardwareEncoder(for: .h264)` first if you need to fall
    /// back; nothing here does that for you.
    public static func h264VideoToolbox(bitrate: Bitrate = .mbps(6)) -> VideoSettings {
        return VideoSettings(codec: .h264VideoToolbox, bitrate: bitrate)
    }

    public static func hevcVideoToolbox(bitrate: Bitrate = .mbps(4)) -> VideoSettings {
        return VideoSettings(codec: .hevcVideoToolbox, bitrate: bitrate)
    }

    /// Constrained delivery: an average rate, a ceiling, and a window - what an adaptive streaming
    /// ladder rung is, and what a player's buffer model expects.
    public static func streaming(codec: VideoCodec = .h264, bitrate: Bitrate,
                                 maxBitrate: Bitrate? = nil, bufferSize: Bitrate? = nil,
                                 size: FrameSize? = nil,
                                 keyframeInterval: Int? = nil) -> VideoSettings {
        // A ceiling defaults to a little above the target and a window to twice the ceiling, which
        // is what every streaming guide recommends and nobody remembers.
        let ceiling = maxBitrate ?? Bitrate(bitsPerSecond: bitrate.bitsPerSecond * 5 / 4)
        return VideoSettings(codec: codec, bitrate: bitrate, maxBitrate: ceiling,
                             bufferSize: bufferSize ?? Bitrate(bitsPerSecond: ceiling.bitsPerSecond * 2),
                             keyframeInterval: keyframeInterval, size: size)
    }

    public static let copy = VideoSettings(codec: .copy)

    /// No video in the output.
    public static let disabled = VideoSettings(isDisabled: true)
}


public struct AudioSettings: Equatable {
    public var codec: AudioCodec?
    public var bitrate: Bitrate?
    public var sampleRate: Int?
    /// How many channels. `channelLayout` says which they are; setting the layout is usually the
    /// more useful of the two, since "2" and "stereo" are the same count but not the same request.
    public var channels: Int?
    public var channelLayout: AudioChannelLayout?
    /// Normalise loudness to a target. See `LoudnessNormalization` - the two-pass form is the one
    /// that actually hits the target.
    public var loudness: LoudnessNormalization?
    public var encoderOptions: [String : String]
    /// Drop audio from the output entirely (-an). Everything else here is ignored when set.
    public var isDisabled: Bool
    public var additionalOptions: [String]

    public init(codec: AudioCodec? = nil, bitrate: Bitrate? = nil, sampleRate: Int? = nil,
                channels: Int? = nil, channelLayout: AudioChannelLayout? = nil,
                loudness: LoudnessNormalization? = nil, encoderOptions: [String : String] = [:],
                isDisabled: Bool = false, additionalOptions: [String] = []) {
        self.codec = codec
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.channelLayout = channelLayout
        self.loudness = loudness
        self.encoderOptions = encoderOptions
        self.isDisabled = isDisabled
        self.additionalOptions = additionalOptions
    }

    public static func aac(_ bitrate: Bitrate = .kbps(160)) -> AudioSettings {
        return AudioSettings(codec: .aac, bitrate: bitrate)
    }

    public static let copy = AudioSettings(codec: .copy)

    /// No audio in the output.
    public static let disabled = AudioSettings(isDisabled: true)
}


/// Normalising loudness to a broadcast-style target, with `loudnorm`.
///
/// The defaults are the streaming convention (-16 LUFS, -1.5 dBTP). Broadcast is -23 LUFS (EBU
/// R128) or -24 (ATSC A/85).
public struct LoudnessNormalization: Equatable {
    /// Integrated loudness target, LUFS.
    public var integratedTarget: Double
    /// True-peak ceiling, dBTP.
    public var truePeak: Double
    /// Loudness range target, LU.
    public var loudnessRange: Double
    /// Measure the whole stream first, then normalise against what was measured.
    ///
    /// This is the difference between hitting the target and approximately hitting it. In one pass
    /// `loudnorm` works from what it has heard so far, so the beginning of a file is normalised
    /// against nothing and the result drifts from the target - which for a short clip with a quiet
    /// opening can be several LU out. Costs a full extra decode of the audio.
    public var isTwoPass: Bool

    public init(integratedTarget: Double = -16, truePeak: Double = -1.5,
                loudnessRange: Double = 11, isTwoPass: Bool = true) {
        self.integratedTarget = integratedTarget
        self.truePeak = truePeak
        self.loudnessRange = loudnessRange
        self.isTwoPass = isTwoPass
    }

    /// -16 LUFS: Apple Podcasts, Spotify, YouTube.
    public static let streaming = LoudnessNormalization()

    /// -23 LUFS: EBU R128, European broadcast.
    public static let broadcastEBU = LoudnessNormalization(integratedTarget: -23, truePeak: -1)

    /// -24 LUFS: ATSC A/85, US broadcast.
    public static let broadcastATSC = LoudnessNormalization(integratedTarget: -24, truePeak: -2)

    /// The filter as ffmpeg spells it, optionally carrying a first pass's measurements.
    func filterArgument(measured: LoudnessMeasurement? = nil) -> String {
        var parts = ["loudnorm=I=\(integratedTarget)", "TP=\(truePeak)", "LRA=\(loudnessRange)"]

        if let measured = measured {
            parts += ["measured_I=\(measured.integrated)", "measured_TP=\(measured.truePeak)",
                      "measured_LRA=\(measured.loudnessRange)",
                      "measured_thresh=\(measured.threshold)", "offset=\(measured.offset)",
                      "linear=true"]
        }

        return parts.joined(separator: ":")
    }
}


/// What a `loudnorm` measuring pass found. Printed by ffmpeg as JSON on stderr.
///
/// Internal: it travels from the measuring pass to the one that follows and no further. Nothing
/// public hands one out or takes one, so making it public would only put a type in the interface
/// that a caller has no way to obtain.
struct LoudnessMeasurement: Equatable {
    let integrated: Double
    let truePeak: Double
    let loudnessRange: Double
    let threshold: Double
    let offset: Double
}


public struct SubtitleSettings: Equatable {
    public var codec: SubtitleCodec?
    /// Language tag for the output stream, as ISO 639-2 - "eng", "fra".
    public var language: String?
    public var encoderOptions: [String : String]
    /// Drop subtitles from the output entirely (-sn).
    public var isDisabled: Bool
    public var additionalOptions: [String]

    public init(codec: SubtitleCodec? = nil, language: String? = nil,
                encoderOptions: [String : String] = [:], isDisabled: Bool = false,
                additionalOptions: [String] = []) {
        self.codec = codec
        self.language = language
        self.encoderOptions = encoderOptions
        self.isDisabled = isDisabled
        self.additionalOptions = additionalOptions
    }

    /// Carry the subtitle stream across untouched.
    public static let copy = SubtitleSettings(codec: .copy)

    /// What an .mp4 needs: nothing else survives that container.
    public static let movText = SubtitleSettings(codec: .movText)

    public static let disabled = SubtitleSettings(isDisabled: true)
}


/// Which streams a setting applies to, as ffmpeg's stream specifiers.
public enum StreamSelector: Equatable {
    case allVideo
    case allAudio
    case allSubtitles
    /// The nth video stream of the output, counting from zero.
    case video(Int)
    case audio(Int)
    case subtitle(Int)
    /// The nth output stream, whatever kind it is.
    case index(Int)

    var specifier: String {
        switch self {
        case .allVideo:        return "v"
        case .allAudio:        return "a"
        case .allSubtitles:    return "s"
        case .video(let n):    return "v:\(n)"
        case .audio(let n):    return "a:\(n)"
        case .subtitle(let n): return "s:\(n)"
        case .index(let n):    return "\(n)"
        }
    }
}


public enum StreamSettings: Equatable {
    case video(VideoSettings)
    case audio(AudioSettings)
    case subtitles(SubtitleSettings)
}


/// Settings for one stream of an output, rather than for all of its video or all of its audio.
///
/// `Output.video` and `Output.audio` cover the ordinary case, where every video stream is treated
/// alike. This is for when they are not: two audio tracks at different bitrates, a second video
/// stream carried through untouched. Overrides are emitted after the blanket settings, so the more
/// specific one wins - which is ffmpeg's own rule for stream specifiers.
public struct StreamOverride: Equatable {
    public var selector: StreamSelector
    public var settings: StreamSettings

    public init(_ selector: StreamSelector, _ settings: StreamSettings) {
        self.selector = selector
        self.settings = settings
    }
}


/// Where an input's data comes from.
///
/// A local file is opened here, in the client, and reaches ffmpeg as a descriptor - that is what
/// makes conversions work under the App Sandbox. A remote URL cannot be: there is nothing to open,
/// so the URL is handed to ffmpeg to open for itself. That means it is fetched by the sandboxed
/// helper rather than by your process, and no security-scoped grant is involved either way.
public enum InputSource: Equatable {
    case file(URL)
    case remote(URL)

    public var url: URL {
        switch self {
        case .file(let url), .remote(let url): return url
        }
    }
}


public struct Input: Equatable {
    public var source: InputSource
    /// Seek and/or limit before decoding.
    public var timeRange: TimeRange?
    /// Read at wall-clock speed (-re). Mostly useful for simulating a live source.
    public var readAtNativeRate: Bool
    /// Force a demuxer instead of letting ffmpeg probe (-f).
    public var format: String?
    /// Decode on the media engine. Opt-in; see `HardwareAcceleration`.
    public var hardwareAcceleration: HardwareAcceleration?
    public var additionalOptions: [String]

    public var url: URL { source.url }

    public init(source: InputSource, timeRange: TimeRange? = nil, readAtNativeRate: Bool = false,
                format: String? = nil, hardwareAcceleration: HardwareAcceleration? = nil,
                additionalOptions: [String] = []) {
        self.source = source
        self.timeRange = timeRange
        self.readAtNativeRate = readAtNativeRate
        self.format = format
        self.hardwareAcceleration = hardwareAcceleration
        self.additionalOptions = additionalOptions
    }

    /// A local file, opened here and passed down as a descriptor.
    public init(url: URL, timeRange: TimeRange? = nil, readAtNativeRate: Bool = false,
                format: String? = nil, hardwareAcceleration: HardwareAcceleration? = nil,
                additionalOptions: [String] = []) {
        self.init(source: .file(url), timeRange: timeRange, readAtNativeRate: readAtNativeRate,
                  format: format, hardwareAcceleration: hardwareAcceleration,
                  additionalOptions: additionalOptions)
    }

    /// A URL ffmpeg opens for itself - http, https, rtmp and whatever else the build carries. Ask
    /// `FFmpeg.protocols()` for the list.
    ///
    /// Read `InputSource.remote` before reaching for this: the fetch happens inside the sandboxed
    /// helper, not in your process.
    public static func remote(_ url: URL, timeRange: TimeRange? = nil,
                              format: String? = nil,
                              additionalOptions: [String] = []) -> Input {
        return Input(source: .remote(url), timeRange: timeRange, format: format,
                     additionalOptions: additionalOptions)
    }
}


public struct Output: Equatable {
    public var url: URL
    public var container: Container?
    public var video: VideoSettings?
    public var audio: AudioSettings?
    public var subtitles: SubtitleSettings?
    /// Settings for particular streams, overriding the three above. See `StreamOverride`.
    public var streamOverrides: [StreamOverride]
    /// Trim what is written, as opposed to seeking the input.
    public var timeRange: TimeRange?
    public var streamMaps: [StreamMap]
    public var metadata: [String : String]
    /// Move the index to the front of the file, so a player can start before it has the whole
    /// thing (`-movflags +faststart`).
    ///
    /// Costs a second pass over the finished file, and does nothing for containers that are not
    /// MP4 or MOV - it is silently ignored elsewhere, which is ffmpeg's behaviour, not a choice
    /// made here. Set it for anything served over HTTP; leave it off for an intermediate.
    public var optimizeForStreaming: Bool
    /// Stop after this many video frames (-frames:v). One frame plus an image container is how a
    /// thumbnail is taken; see `Conversion.thumbnail(of:to:at:)`.
    public var frameLimit: Int?
    public var additionalOptions: [String]

    public init(url: URL, container: Container? = nil, video: VideoSettings? = nil,
                audio: AudioSettings? = nil, subtitles: SubtitleSettings? = nil,
                streamOverrides: [StreamOverride] = [], timeRange: TimeRange? = nil,
                streamMaps: [StreamMap] = [], metadata: [String : String] = [:],
                optimizeForStreaming: Bool = false, frameLimit: Int? = nil,
                additionalOptions: [String] = []) {
        self.url = url
        self.container = container
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
        self.streamOverrides = streamOverrides
        self.timeRange = timeRange
        self.streamMaps = streamMaps
        self.metadata = metadata
        self.optimizeForStreaming = optimizeForStreaming
        self.frameLimit = frameLimit
        self.additionalOptions = additionalOptions
    }

    /// Whether anything here needs a measuring pass before the real one.
    var requiresTwoPasses: Bool {
        if video?.isTwoPass == true { return true }
        if audio?.loudness?.isTwoPass == true { return true }

        return streamOverrides.contains {
            switch $0.settings {
            case .video(let v):    return v.isTwoPass
            case .audio(let a):    return a.loudness?.isTwoPass == true
            case .subtitles:       return false
            }
        }
    }
}


/// A -filter_complex graph.
///
/// Simple per-stream filters (-vf/-af) are deliberately not reachable: FFmpegTask rejects them,
/// because a complex graph can express everything they can and having one path is less to get
/// wrong.
public struct FilterGraph: Equatable, ExpressibleByStringLiteral {
    public var description: String

    public init(_ description: String) { self.description = description }
    public init(stringLiteral value: String) { self.description = value }

    /// Joins stages with "," - a single chain.
    public static func chain(_ stages: [String]) -> FilterGraph {
        return FilterGraph(stages.joined(separator: ","))
    }

    /// Joins chains with ";" - a graph of them.
    public static func graph(_ chains: [String]) -> FilterGraph {
        return FilterGraph(chains.joined(separator: ";"))
    }

    public static func scale(width: Int, height: Int) -> FilterGraph {
        return FilterGraph("scale=\(width):\(height)")
    }
}


public struct Conversion {
    public var inputs: [Input]
    public var outputs: [Output]
    public var filterGraph: FilterGraph?
    /// Overwrite an existing output (-y). On by default: without it ffmpeg blocks on a prompt that
    /// nothing can answer, since FFmpegTask runs with stdin closed.
    public var overwriteExisting: Bool
    public var additionalGlobalOptions: [String]

    public init(inputs: [Input], outputs: [Output], filterGraph: FilterGraph? = nil,
                overwriteExisting: Bool = true, additionalGlobalOptions: [String] = []) {
        self.inputs = inputs
        self.outputs = outputs
        self.filterGraph = filterGraph
        self.overwriteExisting = overwriteExisting
        self.additionalGlobalOptions = additionalGlobalOptions
    }

    /// The common case: one file in, one file out.
    public init(from source: URL, to destination: URL, video: VideoSettings? = nil,
                audio: AudioSettings? = nil, container: Container? = nil) {
        self.init(inputs: [Input(url: source)],
                  outputs: [Output(url: destination, container: container, video: video, audio: audio)])
    }

    /// Whether any output needs a measuring pass run before it.
    var requiresTwoPasses: Bool {
        return outputs.contains { $0.requiresTwoPasses }
    }

    // MARK: - Joining

    /// Joins several sources end to end into one file.
    ///
    /// Uses the `concat` **filter**, which decodes everything and re-encodes it, rather than the
    /// concat demuxer, which can copy streams through untouched but takes a list *file* naming its
    /// inputs by path - and a path is exactly what cannot reach ffmpeg here, since every file
    /// arrives as a descriptor. Re-encoding is the cost of joining without naming a path.
    ///
    /// The sources must agree on what they contain: same number of streams, all with audio or all
    /// without. `concat` will not join a clip that has a soundtrack to one that does not.
    public static func joining(_ sources: [URL], to destination: URL,
                               video: VideoSettings? = nil, audio: AudioSettings? = nil,
                               container: Container? = nil,
                               includesAudio: Bool = true) -> Conversion {
        // [0:v][0:a][1:v][1:a]...concat=n=2:v=1:a=1[v][a]
        var labels = ""
        for index in sources.indices {
            labels += "[\(index):v]"
            if includesAudio { labels += "[\(index):a]" }
        }

        let outputs = includesAudio ? "[v][a]" : "[v]"
        let graph = FilterGraph("\(labels)concat=n=\(sources.count):v=1:a=\(includesAudio ? 1 : 0)\(outputs)")

        var maps: [StreamMap] = [.specifier("[v]")]
        if includesAudio { maps.append(.specifier("[a]")) }

        return Conversion(inputs: sources.map { Input(url: $0) },
                          outputs: [Output(url: destination, container: container, video: video,
                                           audio: includesAudio ? audio : .disabled,
                                           streamMaps: maps)],
                          filterGraph: graph)
    }

    // MARK: - Stills

    /// A single frame, as a still image.
    ///
    /// Seeks on the input rather than the output, which is what makes this fast: ffmpeg jumps to
    /// the nearest keyframe instead of decoding from the beginning.
    public static func thumbnail(of source: URL, to destination: URL, at time: TimeInterval = 0,
                                 size: FrameSize? = nil,
                                 codec: VideoCodec = .png) -> Conversion {
        return Conversion(inputs: [Input(url: source, timeRange: .from(time))],
                          outputs: [Output(url: destination, container: .image,
                                           video: VideoSettings(codec: codec, size: size),
                                           audio: .disabled, frameLimit: 1)])
    }

    /// A grid of frames sampled across the source, written as one image.
    ///
    /// A contact sheet rather than a sequence of files on purpose: numbered output ("frame%03d.png")
    /// needs a filename pattern, and an output reached through a descriptor has no name for ffmpeg
    /// to fill a pattern into. One image out of `tile` says the same thing in a form that fits.
    public static func contactSheet(of source: URL, to destination: URL,
                                    columns: Int = 4, rows: Int = 4,
                                    interval: TimeInterval = 10,
                                    frameSize: FrameSize = FrameSize(width: 320, height: 180),
                                    codec: VideoCodec = .png) -> Conversion {
        let graph = FilterGraph.chain(["fps=1/\(interval)",
                                       "scale=\(frameSize.width):\(frameSize.height)",
                                       "tile=\(columns)x\(rows)"])

        return Conversion(inputs: [Input(url: source)],
                          outputs: [Output(url: destination, container: .image,
                                           video: VideoSettings(codec: codec),
                                           audio: .disabled, frameLimit: 1)],
                          filterGraph: graph)
    }
}
