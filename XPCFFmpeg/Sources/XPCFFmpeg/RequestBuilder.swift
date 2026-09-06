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

    private mutating func token(forWriting url: URL) throws -> String {
        let existed = FileManager.default.fileExists(atPath: url.path)

        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw FFmpegError.inaccessibleFile(url, underlying: CocoaError(.fileWriteNoPermission))
        }

        if !existed { placeholders.append(url) }

        return register(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
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

    private mutating func append(video: VideoSettings?, streamIndex: String) {
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
            append("-crf", String(quality))
        }

        if let size = video.size { append("-s", size.argument) }
        if let frameRate = video.frameRate { append("-r", String(frameRate)) }
        if let preset = video.preset { append("-preset", preset.rawValue) }
        if let pixelFormat = video.pixelFormat { append("-pix_fmt", pixelFormat) }

        arguments.append(contentsOf: video.additionalOptions)
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
        if let sampleRate = audio.sampleRate { append("-ar", String(sampleRate)) }
        if let channels = audio.channels { append("-ac", String(channels)) }

        arguments.append(contentsOf: audio.additionalOptions)
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
        case "mkv", "webm": return "matroska"
        case "m4a":         return "ipod"
        case "wav":         return "wav"
        case "mp3":         return "mp3"
        case "flac":        return "flac"
        case "aac":         return "adts"
        default:
            throw FFmpegError.indeterminateContainer(output.url)
        }
    }

    static func request(for conversion: Conversion) throws -> Built {
        var builder = RequestBuilder()

        if conversion.overwriteExisting { builder.append("-y") }
        builder.arguments.append(contentsOf: conversion.additionalGlobalOptions)

        // Input options precede the -i they belong to, and -fd precedes both: it is a protocol
        // option applying to the URL that follows.
        for input in conversion.inputs {
            if input.readAtNativeRate { builder.append("-re") }
            if let format = input.format { builder.append("-f", format) }
            builder.append(timeRange: input.timeRange)
            builder.arguments.append(contentsOf: input.additionalOptions)

            let token = try builder.token(forReading: input.url)
            builder.append("-fd", token, "-i", "fd:")
        }

        if let graph = conversion.filterGraph {
            builder.append("-filter_complex", graph.description)
        }

        for output in conversion.outputs {
            for map in output.streamMaps { builder.append("-map", map.argument) }

            builder.append(video: output.video, streamIndex: "v")
            builder.append(audio: output.audio, streamIndex: "a")
            builder.append(timeRange: output.timeRange)

            for (key, value) in output.metadata.sorted(by: { $0.key < $1.key }) {
                builder.append("-metadata", "\(key)=\(value)")
            }

            builder.append("-f", try RequestBuilder.container(for: output))
            builder.arguments.append(contentsOf: output.additionalOptions)

            let token = try builder.token(forWriting: output.url)
            builder.append("-fd", token, "fd:")
        }

        return Built(request: FFmpegRequest(request: "-ffmpeg", arguments: builder.arguments),
                     tokens: builder.tokens, handles: builder.handles,
                     placeholders: builder.placeholders)
    }

    /// The escape hatch: the caller's own arguments, with each named file opened and its path
    /// replaced by ffmpeg's descriptor form.
    static func raw(verb: String, arguments: [String], files: [URL]) throws -> Built {
        var builder = RequestBuilder()
        var substituted: [String] = []

        var tokensByPath: [String : String] = [:]
        for url in files {
            tokensByPath[url.path] = try builder.token(forReading: url)
        }

        for argument in arguments {
            if let token = tokensByPath[argument] {
                substituted.append(contentsOf: ["-fd", token, "fd:"])
            } else {
                substituted.append(argument)
            }
        }

        builder.arguments = substituted

        return Built(request: FFmpegRequest(request: verb, arguments: builder.arguments),
                     tokens: builder.tokens, handles: builder.handles, placeholders: [])
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
