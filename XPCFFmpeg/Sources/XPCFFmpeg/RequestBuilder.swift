//
//  RequestBuilder.swift
//  XPCFFmpeg
//
//  Turns a Conversion into the argument vector ffmpeg expects, minting a bookmark for every file
//  it touches. This runs in the client process on purpose: the client is the one holding the
//  user's sandbox rights, so it is the only place a bookmark can legitimately be made.
//

import Foundation
import XPCFFmpegServiceFramework


struct RequestBuilder {

    /// The command line, plus the descriptors it refers to.
    struct Built {
        let request: FFmpegRequest
        let tokens: [String]
        let handles: [FileHandle]
        /// Destinations created here, so they can be tidied away if the job never writes them.
        let placeholders: [URL]
    }

    private var arguments: [String] = []
    private var tokens: [String] = []
    private var handles: [FileHandle] = []
    private var placeholders: [URL] = []
    /// The destinations, kept apart from the rest so they can be emptied together and last.
    private var writeHandles: [FileHandle] = []

    /// Opens `url` and returns the token standing for its descriptor.
    ///
    /// The opening happens here, in the client, because this is the process holding the user's
    /// sandbox grant - and once a file is open, the descriptor carries that access wherever it is
    /// passed. Neither the service nor FFmpegTask ever needs to reach the file by name.
    private mutating func token(forReading url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw FFmpegError.inaccessibleFile(url, underlying: CocoaError(.fileReadNoPermission))
        }

        return register(handle)
    }

    /// Opens `url` for writing and returns the token standing for its descriptor.
    ///
    /// Deliberately without O_TRUNC. Emptying the file is the one irreversible thing this builder
    /// does, so it waits until the whole request is known to be buildable - see
    /// `truncateOutputs()`. Opening as we go and truncating as we went is how a conversion that
    /// was refused a moment later used to leave an earlier destination destroyed behind it.
    private mutating func token(forWriting url: URL) throws -> String {
        let existed = FileManager.default.fileExists(atPath: url.path)

        let descriptor = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw FFmpegError.inaccessibleFile(url, underlying: CocoaError(.fileWriteNoPermission))
        }

        if !existed { placeholders.append(url) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        writeHandles.append(handle)
        return register(handle)
    }

    /// A descriptor on /dev/null, for a pass whose output is not wanted.
    ///
    /// `-f null` already discards everything, but ffmpeg still opens the output, and here that
    /// means a descriptor has to exist for it to open.
    private mutating func nullToken() throws -> String {
        let descriptor = open("/dev/null", O_WRONLY)
        guard descriptor >= 0 else {
            throw FFmpegError.inaccessibleFile(URL(fileURLWithPath: "/dev/null"),
                                               underlying: CocoaError(.fileWriteNoPermission))
        }

        return register(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    /// Empties every destination, once the request around them is known to be buildable.
    ///
    /// ffmpeg reaches an output through a descriptor, so it cannot truncate the file itself: what
    /// lies beyond what it writes stays there, and a short encode over a longer file would leave
    /// the tail of the old one attached to the new. So the truncation is ours to do - just not
    /// until nothing can still go wrong.
    private func truncateOutputs() {
        for handle in writeHandles { _ = ftruncate(handle.fileDescriptor, 0) }
    }

    /// Removes the destinations this builder created, for a request that then failed to build.
    ///
    /// Only ever files that did not exist beforehand: one the caller already had is emptied or
    /// left alone, never deleted.
    private func discardPlaceholders() {
        for url in placeholders { try? FileManager.default.removeItem(at: url) }
    }

    private mutating func register(_ handle: FileHandle) -> String {
        let token = FFmpegRequest.token()
        tokens.append(token)
        handles.append(handle)
        return token
    }

    private mutating func append(_ values: String...) {
        arguments.append(contentsOf: values)
    }

    private mutating func append(timeRange: TimeRange?) {
        guard let range = timeRange else { return }
        if let start = range.start { append("-ss", String(start)) }
        if let duration = range.duration { append("-t", String(duration)) }
    }

    private mutating func append(video: VideoSettings?, streamIndex: String, pass: Int? = nil) {
        guard let video = video else { return }

        if video.isDisabled {
            append("-vn")
            return
        }

        if let codec = video.codec {
            append("-c:\(streamIndex)", codec.argument)
        }

        // A rate cap and a quality target are mutually exclusive; the rate wins because it is the
        // more specific request.
        if let bitrate = video.bitrate {
            append("-b:\(streamIndex)", bitrate.argument)
        } else if let quality = video.quality {
            append("-crf:\(streamIndex)", String(quality))
        }

        // A ceiling without a window is ignored by x264, so neither is emitted alone: sending one
        // would read as a constraint that silently is not there.
        if let maxBitrate = video.maxBitrate, let bufferSize = video.bufferSize {
            append("-maxrate:\(streamIndex)", maxBitrate.argument)
            append("-bufsize:\(streamIndex)", bufferSize.argument)
        }

        // Every one of these carries the specifier too, including where it is only "v". An option
        // spelled bare applies to every stream of its kind, so an override that emitted one would
        // reach back over the streams it was meant to leave alone - and, coming last, win there.
        if let keyframeInterval = video.keyframeInterval { append("-g:\(streamIndex)", String(keyframeInterval)) }
        if let profile = video.profile { append("-profile:\(streamIndex)", profile) }
        if let level = video.level { append("-level:\(streamIndex)", level) }
        if let tune = video.tune { append("-tune:\(streamIndex)", tune) }
        if let size = video.size { append("-s:\(streamIndex)", size.argument) }
        if let frameRate = video.frameRate { append("-r:\(streamIndex)", String(frameRate)) }
        if let preset = video.preset { append("-preset:\(streamIndex)", preset.rawValue) }
        if let pixelFormat = video.pixelFormat { append("-pix_fmt:\(streamIndex)", pixelFormat) }

        if let color = video.colorProperties, !color.isEmpty {
            if let space = color.space { append("-colorspace:\(streamIndex)", space) }
            if let primaries = color.primaries { append("-color_primaries:\(streamIndex)", primaries) }
            if let transfer = color.transfer { append("-color_trc:\(streamIndex)", transfer) }
            if let range = color.range { append("-color_range:\(streamIndex)", range) }
        }

        // Only the settings that actually asked for two passes are told which pass this is. A
        // blanket "-pass" would put the whole output through a two-pass encode on the strength of
        // one stream having asked for it.
        if let pass = pass, video.isTwoPass { append("-pass:\(streamIndex)", String(pass)) }

        append(encoderOptions: RequestBuilder.mergingColorVUIParams(video.encoderOptions,
                                                                    codec: video.codec,
                                                                    color: video.colorProperties),
               streamIndex: streamIndex)
        arguments.append(contentsOf: video.additionalOptions)
    }

    /// Mirrors `colorProperties` into libx264/libx265's own parameter string, for the two codecs
    /// that need it.
    ///
    /// `-color_primaries`/`-color_trc` as generic output options never reach the encoded bitstream
    /// for these two encoders: reproduced with an unrelated, unmodified FFmpeg build, and confirmed
    /// by decoding the raw stream, so it is not a muxer or ffprobe reporting quirk - the SPS/VPS
    /// itself never carries them. `-colorspace`/`-color_range` are unaffected and already reach the
    /// bitstream through the generic path above; this only needs to cover the two that do not.
    /// libx264 and libx265's own parameter strings do not have the bug, so this recreates
    /// `colorProperties` there too, in whichever spelling each encoder's parser expects.
    ///
    /// Whatever the caller already put in `encoderOptions` under that key wins, key by key: this
    /// only fills in what they have not already said themselves.
    private static func mergingColorVUIParams(_ encoderOptions: [String : String],
                                              codec: VideoCodec?, color: ColorProperties?)
        -> [String : String] {
        guard let color = color, !color.isEmpty else { return encoderOptions }

        let key: String
        var derived: [String : String] = [:]

        switch codec {
        case .h264:
            key = "x264-params"
            // x264's params parser: "fullrange", on/off.
            if let range = color.range { derived["fullrange"] = range == "pc" ? "on" : "off" }
        case .hevc:
            key = "x265-params"
            // x265's params parser: "range", full/limited - not the same spelling as x264's.
            if let range = color.range { derived["range"] = range == "pc" ? "full" : "limited" }
        default:
            return encoderOptions
        }

        // These three are spelled identically by both encoders' parameter parsers.
        if let space = color.space { derived["colormatrix"] = space }
        if let primaries = color.primaries { derived["colorprim"] = primaries }
        if let transfer = color.transfer { derived["transfer"] = transfer }

        guard !derived.isEmpty else { return encoderOptions }

        var existing = parseParamString(encoderOptions[key])
        for (name, value) in derived where existing[name] == nil { existing[name] = value }

        var merged = encoderOptions
        merged[key] = existing.sorted { $0.key < $1.key }
                              .map { "\($0.key)=\($0.value)" }
                              .joined(separator: ":")
        return merged
    }

    /// Splits an x264-params/x265-params style string ("key=value:key=value") back into a dictionary,
    /// so a value this package derives can be merged with one the caller already supplied.
    private static func parseParamString(_ string: String?) -> [String : String] {
        guard let string = string else { return [:] }

        var result: [String : String] = [:]
        for pair in string.split(separator: ":") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// Sorted, so the same settings always produce the same command line - which is what makes
    /// these testable at all.
    private mutating func append(encoderOptions: [String : String], streamIndex: String) {
        for (key, value) in encoderOptions.sorted(by: { $0.key < $1.key }) {
            append("-\(key):\(streamIndex)", value)
        }
    }

    private mutating func append(audio: AudioSettings?, streamIndex: String) {
        guard let audio = audio else { return }

        if audio.isDisabled {
            append("-an")
            return
        }

        if let codec = audio.codec {
            append("-c:\(streamIndex)", codec.argument)
        }

        if let bitrate = audio.bitrate { append("-b:\(streamIndex)", bitrate.argument) }
        if let sampleRate = audio.sampleRate { append("-ar:\(streamIndex)", String(sampleRate)) }
        if let channels = audio.channels { append("-ac:\(streamIndex)", String(channels)) }
        if let layout = audio.channelLayout { append("-channel_layout:\(streamIndex)", layout.argument) }

        // Loudness is deliberately absent here: it is a filter, and filters live in the graph.

        append(encoderOptions: audio.encoderOptions, streamIndex: streamIndex)
        arguments.append(contentsOf: audio.additionalOptions)
    }

    private mutating func append(subtitles: SubtitleSettings?, streamIndex: String) {
        guard let subtitles = subtitles else { return }

        if subtitles.isDisabled {
            append("-sn")
            return
        }

        if let codec = subtitles.codec { append("-c:\(streamIndex)", codec.argument) }
        if let language = subtitles.language {
            append("-metadata:s:\(streamIndex)", "language=\(language)")
        }

        append(encoderOptions: subtitles.encoderOptions, streamIndex: streamIndex)
        arguments.append(contentsOf: subtitles.additionalOptions)
    }

    /// The per-stream settings, emitted after the blanket ones so the more specific wins.
    private mutating func append(overrides: [StreamOverride], pass: Int? = nil) {
        for override in overrides {
            switch override.settings {
            case .video(let settings):
                append(video: settings, streamIndex: override.selector.specifier, pass: pass)
            case .audio(let settings):
                append(audio: settings, streamIndex: override.selector.specifier)
            case .subtitles(let settings):
                append(subtitles: settings, streamIndex: override.selector.specifier)
            }
        }
    }

    /// The muxer to write with.
    ///
    /// Required, not optional: an output reached through a descriptor has no filename, so ffmpeg
    /// cannot infer the container the way it does from an extension. Falls back to the extension
    /// the caller used, which is what they meant anyway.
    static func container(for output: Output) throws -> String {
        if let container = output.container { return container.argument }

        switch output.url.pathExtension.lowercased() {
        case "mp4", "m4v":  return "mp4"
        case "mov":         return "mov"
        case "mkv":         return "matroska"
        // Not matroska: the webm muxer writes a WebM DocType and holds the file to WebM's codec
        // subset. Matroska under a .webm name is what a browser refuses to play.
        case "webm":        return "webm"
        case "m4a":         return "ipod"
        case "wav":         return "wav"
        case "mp3":         return "mp3"
        case "flac":        return "flac"
        case "aac":         return "adts"
        default:
            throw FFmpegError.indeterminateContainer(output.url)
        }
    }

    /// What a single ffmpeg invocation needs to know beyond the conversion itself.
    ///
    /// A two-pass encode is two invocations of the same `Conversion` differing only in this.
    struct Pass {
        /// 1 or 2 for a video two-pass encode, nil when there is only one.
        var number: Int?
        /// The `-passlogfile` placeholder, which the service turns into a path it owns.
        var logToken: String?
        /// Throw the output away and write nothing: what a measuring pass is for.
        var discardsOutput: Bool = false
        /// Have `loudnorm` print what it measured, instead of normalising against a guess.
        var measuresLoudness: Bool = false
        /// What a previous measuring pass found, to normalise against properly.
        var loudness: LoudnessMeasurement?

        static let single = Pass(number: nil, logToken: nil)
    }

    static func request(for conversion: Conversion, pass: Pass = .single) throws -> Built {
        // Refused before anything is opened, because opening a destination is what empties it. A
        // request that cannot be built has to leave every file it was going to write as it found
        // it, and a muxer that cannot be named is the likeliest reason it cannot be built.
        let containers = try conversion.outputs.map { try container(for: $0) }

        if !conversion.overwriteExisting {
            // Here, or nowhere. ffmpeg's own -n refuses an output it can see by name, and there is
            // no name here - it is handed a descriptor this process already opened, and by then
            // the file it refers to would already have been emptied.
            for output in conversion.outputs
            where FileManager.default.fileExists(atPath: output.url.path) {
                throw FFmpegError.destinationExists(output.url)
            }
        }

        var builder = RequestBuilder()

        // Whatever a failed build created, it created only in order to write to it, and by
        // definition nothing has been written. Leaving it behind is litter nobody asked for.
        var succeeded = false
        defer { if !succeeded { builder.discardPlaceholders() } }

        if conversion.overwriteExisting { builder.append("-y") }

        // loudnorm prints its measurements at info level, and FFmpegTask runs ffmpeg at warning,
        // so without this the measuring pass runs and reports nothing. Raised only for that pass:
        // info on a real conversion is thousands of lines the caller never asked for.
        if pass.measuresLoudness { builder.append("-loglevel", "repeat+level+info") }

        builder.arguments.append(contentsOf: conversion.additionalGlobalOptions)

        // Input options precede the -i they belong to, and -fd precedes both: it is a protocol
        // option applying to the URL that follows.
        for input in conversion.inputs {
            if let acceleration = input.hardwareAcceleration {
                builder.append("-hwaccel", acceleration.argument)
            }
            if input.readAtNativeRate { builder.append("-re") }
            if let format = input.format { builder.append("-f", format) }
            builder.append(timeRange: input.timeRange)
            builder.arguments.append(contentsOf: input.additionalOptions)

            switch input.source {
            case .file(let url):
                let token = try builder.token(forReading: url)
                builder.append("-fd", token, "-i", "fd:")

            case .remote(let url):
                // No descriptor: there is nothing here to open. ffmpeg opens it itself, inside the
                // sandboxed helper.
                builder.append("-i", url.absoluteString)
            }
        }

        let graph = try RequestBuilder.filterGraph(for: conversion, pass: pass)
        if let graph = graph.description {
            builder.append("-filter_complex", graph)
        }

        for (index, output) in conversion.outputs.enumerated() {
            let maps = graph.maps.isEmpty || index > 0 ? output.streamMaps : graph.maps
            for map in maps { builder.append("-map", map.argument) }

            builder.append(video: output.video, streamIndex: "v", pass: pass.number)
            builder.append(audio: output.audio, streamIndex: "a")
            builder.append(subtitles: output.subtitles, streamIndex: "s")
            builder.append(overrides: output.streamOverrides, pass: pass.number)
            builder.append(timeRange: output.timeRange)

            if let logToken = pass.logToken { builder.append("-passlogfile", logToken) }
            if let frames = output.frameLimit { builder.append("-frames:v", String(frames)) }

            for (key, value) in output.metadata.sorted(by: { $0.key < $1.key }) {
                builder.append("-metadata", "\(key)=\(value)")
            }

            let container = containers[index]

            // A measuring pass exists for its side effects - the pass log and what loudnorm
            // printed - so it muxes nothing and writes to a descriptor on /dev/null.
            if pass.discardsOutput {
                builder.append("-f", "null")
                builder.arguments.append(contentsOf: output.additionalOptions)
                let token = try builder.nullToken()
                builder.append("-fd", token, "fd:")
                continue
            }

            if output.optimizeForStreaming {
                // Emitted only where it means something. ffmpeg ignores it elsewhere, but a
                // command line carrying an option that cannot apply is a command line that reads
                // as though it does.
                if (output.container ?? Container.other(container)).supportsFaststart {
                    builder.append("-movflags", "+faststart")
                }
            }

            builder.append("-f", container)
            builder.arguments.append(contentsOf: output.additionalOptions)

            let token = try builder.token(forWriting: output.url)
            builder.append("-fd", token, "fd:")
        }

        succeeded = true

        // The whole vector is built and every file is open: only now is anything destroyed.
        builder.truncateOutputs()

        return Built(request: FFmpegRequest(request: "-ffmpeg", arguments: builder.arguments),
                     tokens: builder.tokens, handles: builder.handles,
                     placeholders: builder.placeholders)
    }

    /// The graph, and the maps that go with it when this builder wrote it rather than the caller.
    struct Graph {
        var description: String?
        var maps: [StreamMap] = []
    }

    /// Composes `-filter_complex`.
    ///
    /// Loudness normalisation is a filter, and FFmpegTask accepts only complex graphs - `-af` is
    /// refused - so asking for it means writing a graph. Doing that silently on top of a graph the
    /// caller wrote would mean guessing where their chain ends and this one begins, and guessing
    /// wrong quietly. So the two are refused together, with an error that says how to combine them
    /// by hand.
    static func filterGraph(for conversion: Conversion, pass: Pass) throws -> Graph {
        // A graph names the streams it does not touch as well as the ones it does, so normalising
        // one stream out of several means knowing how many there are - which is a probe this
        // builder does not have. Rather than accept the setting and drop it, say so.
        for override in conversion.outputs.flatMap({ $0.streamOverrides }) {
            guard case .audio(let settings) = override.settings,
                  let loudness = settings.loudness else { continue }

            throw FFmpegError.unsupportedSetting(
                "Loudness normalisation cannot be set on a StreamOverride, because the filter "
              + "graph it needs would have to name every other stream of the output. Set it on "
              + "Output.audio, which covers every audio stream, or put "
              + "\"\(loudness.filterArgument())\" into a filterGraph of your own.")
        }

        // Any output can carry it, but only one of them, and the graph is written for the first -
        // so anything else is refused below rather than quietly left out of the command line.
        guard let output = conversion.outputs.first(where: { $0.audio?.loudness != nil }),
              let loudness = output.audio?.loudness else {
            return Graph(description: conversion.filterGraph?.description)
        }

        guard conversion.filterGraph == nil, output.streamMaps.isEmpty else {
            throw FFmpegError.conflictingFilterGraph(
                "Loudness normalisation is built from a filter, so it cannot be combined with a "
              + "filter graph or stream maps you wrote yourself. Put \"\(loudness.filterArgument())\" "
              + "into your own graph instead.")
        }

        guard conversion.outputs.count == 1 else {
            throw FFmpegError.conflictingFilterGraph(
                "Loudness normalisation applies to one output; this conversion has "
              + "\(conversion.outputs.count).")
        }

        var filter = loudness.filterArgument(measured: pass.loudness)
        if pass.measuresLoudness { filter += ":print_format=json" }

        var maps: [StreamMap] = []
        // "0:v?" rather than "0:v": the ? makes it optional, so normalising an audio-only file is
        // not a mapping failure.
        if output.video?.isDisabled != true { maps.append(.specifier("0:v?")) }
        maps.append(.specifier("[aout]"))

        return Graph(description: "[0:a]\(filter)[aout]", maps: maps)
    }

    /// The escape hatch: the caller's own arguments, with each named file opened and its path
    /// replaced by ffmpeg's descriptor form.
    ///
    /// Which side of the command line a file is on has to be stated, because it decides how the
    /// file is opened, and a destination opened for reading is a job that fails on its first
    /// write. A file named in both is opened for reading, on the grounds that ffmpeg reading and
    /// writing one file at once is not something to make easy.
    static func raw(verb: String, arguments: [String],
                    reading: [URL] = [], writing: [URL] = []) throws -> Built {
        var builder = RequestBuilder()
        var substituted: [String] = []

        var succeeded = false
        defer { if !succeeded { builder.discardPlaceholders() } }

        var tokensByPath: [String : String] = [:]
        for url in reading {
            tokensByPath[url.path] = try builder.token(forReading: url)
        }
        for url in writing where tokensByPath[url.path] == nil {
            tokensByPath[url.path] = try builder.token(forWriting: url)
        }

        for argument in arguments {
            if let token = tokensByPath[argument] {
                // ffmpeg's "-fd N" is a protocol option: it has to precede whatever consumes it,
                // exactly like the typed builder's own "-fd token -i fd:". A bare trailing path -
                // an output, which has no flag of its own - keeps the token and "fd:" together
                // where the path was; a path following "-i" needs the token hoisted ahead of it,
                // or ffmpeg reads "-fd" itself as the filename and fails.
                if substituted.last == "-i" {
                    substituted.removeLast()
                    substituted.append(contentsOf: ["-fd", token, "-i", "fd:"])
                } else {
                    substituted.append(contentsOf: ["-fd", token, "fd:"])
                }
            } else {
                substituted.append(argument)
            }
        }

        builder.arguments = substituted
        succeeded = true
        builder.truncateOutputs()

        return Built(request: FFmpegRequest(request: verb, arguments: builder.arguments),
                     tokens: builder.tokens, handles: builder.handles,
                     placeholders: builder.placeholders)
    }

    static func probeRequest(for url: URL, options: ProbeOptions) throws -> Built {
        var builder = RequestBuilder()

        builder.arguments.append(contentsOf: options.arguments)
        let token = try builder.token(forReading: url)
        builder.append("-fd", token, "-i", "fd:")

        return Built(request: FFmpegRequest(request: "-ffprobe", arguments: builder.arguments),
                     tokens: builder.tokens, handles: builder.handles, placeholders: [])
    }
}


/// What to ask ffprobe for. Streams and format are on by default because that is what MediaInfo
/// is built from.
public struct ProbeOptions {
    public var showFormat: Bool
    public var showStreams: Bool
    public var showChapters: Bool
    public var additionalOptions: [String]

    public init(showFormat: Bool = true, showStreams: Bool = true, showChapters: Bool = false,
                additionalOptions: [String] = []) {
        self.showFormat = showFormat
        self.showStreams = showStreams
        self.showChapters = showChapters
        self.additionalOptions = additionalOptions
    }

    public static let `default` = ProbeOptions()

    var arguments: [String] {
        var result: [String] = []
        if showFormat { result.append("-show_format") }
        if showStreams { result.append("-show_streams") }
        if showChapters { result.append("-show_chapters") }
        result.append(contentsOf: additionalOptions)
        return result
    }
}
