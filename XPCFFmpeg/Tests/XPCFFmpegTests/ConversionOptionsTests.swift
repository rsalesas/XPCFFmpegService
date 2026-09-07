//
//  ConversionOptionsTests.swift
//  XPCFFmpegTests
//
//  The options added on top of the original typed model: rate control, colour, per-stream
//  settings, subtitles, hardware, joining, stills, and the passes that some of them need.
//
//  All argument construction, which is pure. What needs a running service is in the end-to-end
//  harness.
//

import XCTest
@testable import XPCFFmpeg
import XPCFFmpegServiceFramework


final class ConversionOptionsTests: XCTestCase {

    private var source: URL!
    private var second: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        source = directory.appendingPathComponent("in.mov")
        second = directory.appendingPathComponent("in2.mov")
        destination = directory.appendingPathComponent("out.mp4")
        try Data("not really a movie".utf8).write(to: source)
        try Data("nor is this".utf8).write(to: second)
    }

    private func readable(_ request: FFmpegRequest) -> [String] {
        return request.arguments.map {
            if $0.hasPrefix(FFmpegRequest.tokenPrefix) { return "<fd>" }
            if $0.hasPrefix(FFmpegRequest.scratchTokenPrefix) { return "<scratch>" }
            return $0
        }
    }

    private func arguments(_ conversion: Conversion,
                           pass: RequestBuilder.Pass = .single) throws -> [String] {
        return readable(try RequestBuilder.request(for: conversion, pass: pass).request)
    }

    /// The index of `flag`, so a test can assert on ordering without pinning the whole vector.
    private func position(of flag: String, in arguments: [String]) -> Int? {
        return arguments.firstIndex(of: flag)
    }

    // MARK: - Rate control

    func testConstrainedRateEmitsBothHalvesOrNeither() throws {
        let withBoth = VideoSettings(codec: .h264, bitrate: .mbps(5),
                                     maxBitrate: .mbps(6), bufferSize: .mbps(12))
        let arguments = try self.arguments(Conversion(from: source, to: destination, video: withBoth))

        XCTAssertTrue(arguments.contains("-maxrate:v"))
        XCTAssertTrue(arguments.contains("-bufsize:v"))
        XCTAssertEqual(arguments[position(of: "-maxrate:v", in: arguments)! + 1], "6000000")
        XCTAssertEqual(arguments[position(of: "-bufsize:v", in: arguments)! + 1], "12000000")

        // x264 ignores a ceiling with no window, so emitting one alone would put a constraint on
        // the command line that is not on the encode.
        let ceilingOnly = VideoSettings(codec: .h264, bitrate: .mbps(5), maxBitrate: .mbps(6))
        let partial = try self.arguments(Conversion(from: source, to: destination, video: ceilingOnly))
        XCTAssertFalse(partial.contains("-maxrate:v"))
        XCTAssertFalse(partial.contains("-bufsize:v"))
    }

    func testStreamingPresetFillsInTheCeilingAndWindow() {
        let settings = VideoSettings.streaming(bitrate: .mbps(5))

        XCTAssertEqual(settings.bitrate, .mbps(5))
        XCTAssertEqual(settings.maxBitrate?.bitsPerSecond, 6_250_000)
        XCTAssertEqual(settings.bufferSize?.bitsPerSecond, 12_500_000)
    }

    func testProfileLevelTuneAndKeyframes() throws {
        let settings = VideoSettings(codec: .h264, quality: 22, keyframeInterval: 48,
                                     profile: "high", level: "4.1", tune: "film")
        let arguments = try self.arguments(Conversion(from: source, to: destination, video: settings))

        XCTAssertEqual(arguments[position(of: "-g", in: arguments)! + 1], "48")
        XCTAssertEqual(arguments[position(of: "-profile:v", in: arguments)! + 1], "high")
        XCTAssertEqual(arguments[position(of: "-level:v", in: arguments)! + 1], "4.1")
        XCTAssertEqual(arguments[position(of: "-tune", in: arguments)! + 1], "film")
    }

    func testEncoderOptionsAreEmittedInAStableOrder() throws {
        let settings = VideoSettings(codec: .h264,
                                     encoderOptions: ["x264-params" : "keyint=50",
                                                      "aq-mode" : "3",
                                                      "refs" : "4"])
        let arguments = try self.arguments(Conversion(from: source, to: destination, video: settings))

        // Sorted by name: a dictionary has no order of its own, and a command line that changes
        // between runs cannot be asserted on.
        let emitted = ["-aq-mode", "3", "-refs", "4", "-x264-params", "keyint=50"]
        XCTAssertNotNil(arguments.firstRange(of: emitted))
    }

    // MARK: - Colour

    func testColourPropertiesAreEmitted() throws {
        let settings = VideoSettings(codec: .hevc, colorProperties: .rec2020PQ)
        let arguments = try self.arguments(Conversion(from: source, to: destination, video: settings))

        XCTAssertEqual(arguments[position(of: "-colorspace", in: arguments)! + 1], "bt2020nc")
        XCTAssertEqual(arguments[position(of: "-color_primaries", in: arguments)! + 1], "bt2020")
        XCTAssertEqual(arguments[position(of: "-color_trc", in: arguments)! + 1], "smpte2084")
        XCTAssertEqual(arguments[position(of: "-color_range", in: arguments)! + 1], "tv")
    }

    func testAnEmptyColourSetEmitsNothing() throws {
        let settings = VideoSettings(codec: .h264, colorProperties: ColorProperties())
        let arguments = try self.arguments(Conversion(from: source, to: destination, video: settings))

        XCTAssertFalse(arguments.contains("-colorspace"))
    }

    // MARK: - Hardware

    func testHardwareEncodersAreNamedNotInferred() throws {
        let settings = VideoSettings.hevcVideoToolbox(bitrate: .mbps(8))
        let arguments = try self.arguments(Conversion(from: source, to: destination, video: settings))

        XCTAssertEqual(arguments[position(of: "-c:v", in: arguments)! + 1], "hevc_videotoolbox")
        // A hardware encoder takes a rate, never a CRF.
        XCTAssertEqual(arguments[position(of: "-b:v", in: arguments)! + 1], "8000000")
        XCTAssertFalse(arguments.contains("-crf"))
    }

    func testCodecsKnowWhetherTheyAreHardware() {
        XCTAssertTrue(VideoCodec.hevcVideoToolbox.isHardwareAccelerated)
        XCTAssertTrue(VideoCodec.other("av1_videotoolbox").isHardwareAccelerated)
        XCTAssertFalse(VideoCodec.hevc.isHardwareAccelerated)
        XCTAssertEqual(VideoCodec.hevcVideoToolbox.softwareEquivalent, .hevc)
        XCTAssertNil(VideoCodec.hevc.softwareEquivalent)
    }

    func testHardwareDecodingPrecedesTheInputItAppliesTo() throws {
        let input = Input(url: source, hardwareAcceleration: .videoToolbox)
        let conversion = Conversion(inputs: [input],
                                    outputs: [Output(url: destination, container: .mp4)])
        let arguments = try self.arguments(conversion)

        XCTAssertEqual(arguments[position(of: "-hwaccel", in: arguments)! + 1], "videotoolbox")
        XCTAssertLessThan(position(of: "-hwaccel", in: arguments)!,
                          position(of: "-i", in: arguments)!)
    }

    // MARK: - Faststart

    func testFaststartIsEmittedForContainersThatHaveIt() throws {
        let output = Output(url: destination, container: .mp4, optimizeForStreaming: true)
        let arguments = try self.arguments(Conversion(inputs: [Input(url: source)], outputs: [output]))

        XCTAssertEqual(arguments[position(of: "-movflags", in: arguments)! + 1], "+faststart")
    }

    func testFaststartIsNotEmittedWhereItMeansNothing() throws {
        let output = Output(url: destination, container: .matroska, optimizeForStreaming: true)
        let arguments = try self.arguments(Conversion(inputs: [Input(url: source)], outputs: [output]))

        // ffmpeg would ignore it. A command line carrying an option that cannot apply reads as
        // though it does, which is worse than not asking.
        XCTAssertFalse(arguments.contains("-movflags"))
    }

    // MARK: - Streams

    func testPerStreamOverridesFollowTheBlanketSettings() throws {
        let output = Output(url: destination, container: .matroska,
                            audio: .aac(.kbps(160)),
                            streamOverrides: [StreamOverride(.audio(1), .audio(.aac(.kbps(64))))])
        let arguments = try self.arguments(Conversion(inputs: [Input(url: source)], outputs: [output]))

        // ffmpeg resolves the most specific specifier last, so the override has to come after.
        XCTAssertLessThan(position(of: "-c:a", in: arguments)!,
                          position(of: "-c:a:1", in: arguments)!)
        XCTAssertEqual(arguments[position(of: "-b:a:1", in: arguments)! + 1], "64000")
    }

    func testStreamSelectorsSpellThemselvesAsFFmpegDoes() {
        XCTAssertEqual(StreamSelector.allVideo.specifier, "v")
        XCTAssertEqual(StreamSelector.audio(2).specifier, "a:2")
        XCTAssertEqual(StreamSelector.subtitle(0).specifier, "s:0")
        XCTAssertEqual(StreamSelector.index(3).specifier, "3")
    }

    func testSubtitleSettings() throws {
        let output = Output(url: destination, container: .mp4,
                            subtitles: SubtitleSettings(codec: .movText, language: "eng"))
        let arguments = try self.arguments(Conversion(inputs: [Input(url: source)], outputs: [output]))

        XCTAssertEqual(arguments[position(of: "-c:s", in: arguments)! + 1], "mov_text")
        XCTAssertEqual(arguments[position(of: "-metadata:s:s", in: arguments)! + 1], "language=eng")
    }

    func testDisabledSubtitlesDropThemEntirely() throws {
        let output = Output(url: destination, container: .mp4, subtitles: .disabled)
        let arguments = try self.arguments(Conversion(inputs: [Input(url: source)], outputs: [output]))

        XCTAssertTrue(arguments.contains("-sn"))
        XCTAssertFalse(arguments.contains("-c:s"))
    }

    // MARK: - Audio

    func testChannelLayout() throws {
        let audio = AudioSettings(codec: .aac, channels: 6, channelLayout: .surround51)
        let arguments = try self.arguments(Conversion(from: source, to: destination, audio: audio))

        XCTAssertEqual(arguments[position(of: "-ac", in: arguments)! + 1], "6")
        XCTAssertEqual(arguments[position(of: "-channel_layout", in: arguments)! + 1], "5.1")
    }

    // MARK: - Inputs

    func testARemoteInputIsPassedAsAURLWithNoDescriptor() throws {
        let url = URL(string: "https://example.com/stream.m3u8")!
        let conversion = Conversion(inputs: [.remote(url)],
                                    outputs: [Output(url: destination, container: .mp4)])
        let built = try RequestBuilder.request(for: conversion, pass: .single)

        // One descriptor, for the output. The input has nothing to open here.
        XCTAssertEqual(built.handles.count, 1)
        XCTAssertEqual(readable(built.request)[position(of: "-i", in: readable(built.request))! + 1],
                       "https://example.com/stream.m3u8")
    }

    func testALocalInputStillTravelsAsADescriptor() throws {
        let conversion = Conversion(from: source, to: destination)
        let built = try RequestBuilder.request(for: conversion, pass: .single)

        XCTAssertEqual(built.handles.count, 2)
        XCTAssertEqual(built.tokens.count, 2)
    }

    // MARK: - Joining

    func testJoiningBuildsAConcatGraphAndMapsIt() throws {
        let conversion = Conversion.joining([source, second], to: destination, container: .mp4)
        let arguments = try self.arguments(conversion)

        let graph = arguments[position(of: "-filter_complex", in: arguments)! + 1]
        XCTAssertEqual(graph, "[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]")
        XCTAssertTrue(arguments.contains("[v]"))
        XCTAssertTrue(arguments.contains("[a]"))
        XCTAssertEqual(arguments.filter { $0 == "-i" }.count, 2)
    }

    func testJoiningWithoutAudioAsksForNeither() throws {
        let conversion = Conversion.joining([source, second], to: destination,
                                            container: .mp4, includesAudio: false)
        let arguments = try self.arguments(conversion)

        let graph = arguments[position(of: "-filter_complex", in: arguments)! + 1]
        XCTAssertEqual(graph, "[0:v][1:v]concat=n=2:v=1:a=0[v]")
        XCTAssertTrue(arguments.contains("-an"))
    }

    // MARK: - Stills

    func testThumbnailSeeksTheInputAndTakesOneFrame() throws {
        let output = destination.deletingPathExtension().appendingPathExtension("png")
        let conversion = Conversion.thumbnail(of: source, to: output, at: 12.5)
        let arguments = try self.arguments(conversion)

        // Seeking before -i is what makes it fast: ffmpeg jumps rather than decodes to get there.
        XCTAssertLessThan(position(of: "-ss", in: arguments)!, position(of: "-i", in: arguments)!)
        XCTAssertEqual(arguments[position(of: "-frames:v", in: arguments)! + 1], "1")
        // image2pipe, not image2: image2 reads its output as a filename pattern and writes the
        // picture to stdout when it cannot, exiting 0 with the destination left empty.
        XCTAssertEqual(arguments[position(of: "-f", in: arguments)! + 1], "image2pipe")
        XCTAssertEqual(arguments[position(of: "-c:v", in: arguments)! + 1], "png")
        XCTAssertTrue(arguments.contains("-an"))
    }

    func testContactSheetTilesSampledFrames() throws {
        let output = destination.deletingPathExtension().appendingPathExtension("png")
        let conversion = Conversion.contactSheet(of: source, to: output, columns: 3, rows: 2,
                                                 interval: 5)
        let arguments = try self.arguments(conversion)

        XCTAssertEqual(arguments[position(of: "-filter_complex", in: arguments)! + 1],
                       "fps=1/5.0,scale=320:180,tile=3x2")
        XCTAssertEqual(arguments[position(of: "-frames:v", in: arguments)! + 1], "1")
    }

    // MARK: - Passes

    func testATwoPassEncodeIsRecognisedFromItsSettings() {
        let single = Conversion(from: source, to: destination, video: .h264())
        XCTAssertFalse(single.requiresTwoPasses)

        let twoPass = Conversion(from: source, to: destination,
                                 video: VideoSettings(codec: .h264, bitrate: .mbps(4), isTwoPass: true))
        XCTAssertTrue(twoPass.requiresTwoPasses)

        // And through an override, not only through the blanket settings.
        let override = Output(url: destination, container: .mp4,
                              streamOverrides: [StreamOverride(.video(0),
                                  .video(VideoSettings(codec: .h264, bitrate: .mbps(4), isTwoPass: true)))])
        XCTAssertTrue(Conversion(inputs: [Input(url: source)], outputs: [override]).requiresTwoPasses)
    }

    func testTheMeasuringPassWritesNothingAndKeepsItsLog() throws {
        let conversion = Conversion(from: source, to: destination,
                                    video: VideoSettings(codec: .h264, bitrate: .mbps(4), isTwoPass: true))
        let token = FFmpegRequest.scratchToken(for: UUID(), retained: true)
        let pass = RequestBuilder.Pass(number: 1, logToken: token, discardsOutput: true)
        let arguments = try self.arguments(conversion, pass: pass)

        XCTAssertEqual(arguments[position(of: "-pass", in: arguments)! + 1], "1")
        XCTAssertEqual(arguments[position(of: "-passlogfile", in: arguments)! + 1], "<scratch>")
        // -f null, not the real muxer: the output of a measuring pass is the log, not a file.
        XCTAssertEqual(arguments[position(of: "-f", in: arguments)! + 1], "null")
        XCTAssertFalse(arguments.contains("mp4"))
    }

    func testTheSecondPassWritesTheRealOutput() throws {
        let conversion = Conversion(from: source, to: destination,
                                    video: VideoSettings(codec: .h264, bitrate: .mbps(4), isTwoPass: true))
        let pass = RequestBuilder.Pass(number: 2, logToken: FFmpegRequest.scratchToken())
        let arguments = try self.arguments(conversion, pass: pass)

        XCTAssertEqual(arguments[position(of: "-pass", in: arguments)! + 1], "2")
        XCTAssertEqual(arguments[position(of: "-f", in: arguments)! + 1], "mp4")
        XCTAssertFalse(arguments.contains("null"))
    }

    func testBothPassesNameTheSameScratchAndOnlyTheLastReleasesIt() throws {
        let id = UUID()
        let first = FFmpegRequest.scratchToken(for: id, retained: true)
        let last = FFmpegRequest.scratchToken(for: id)

        // Same directory, different lifetimes - which is what lets one job write the pass log and
        // the next one read it.
        XCTAssertEqual(FFmpegRequest.scratch(from: first)?.id, id.uuidString)
        XCTAssertEqual(FFmpegRequest.scratch(from: last)?.id, id.uuidString)
        XCTAssertEqual(FFmpegRequest.scratch(from: first)?.isRetained, true)
        XCTAssertEqual(FFmpegRequest.scratch(from: last)?.isRetained, false)
    }

    func testAScratchTokenThatIsNotOneIsRejected() {
        XCTAssertNil(FFmpegRequest.scratch(from: "-passlogfile"))
        XCTAssertNil(FFmpegRequest.scratch(from: FFmpegRequest.token()))
        // The id names a directory, so anything that is not a UUID is refused rather than used.
        XCTAssertNil(FFmpegRequest.scratch(from: "\u{1}xpcffmpeg.scratch../../../etc\u{1}"))
    }

    // MARK: - Loudness

    func testLoudnessBecomesAFilterGraphAndItsMaps() throws {
        let audio = AudioSettings(codec: .aac, loudness: .streaming)
        let conversion = Conversion(from: source, to: destination, audio: audio)
        let arguments = try self.arguments(conversion)

        let graph = arguments[position(of: "-filter_complex", in: arguments)! + 1]
        XCTAssertEqual(graph, "[0:a]loudnorm=I=-16.0:TP=-1.5:LRA=11.0[aout]")
        // "0:v?" rather than "0:v": normalising an audio-only file is not a mapping failure.
        XCTAssertTrue(arguments.contains("0:v?"))
        XCTAssertTrue(arguments.contains("[aout]"))
    }

    func testTheMeasuringPassAsksLoudnormToPrintWhatItHeard() throws {
        let audio = AudioSettings(codec: .aac, loudness: .broadcastEBU)
        let conversion = Conversion(from: source, to: destination, audio: audio)
        let pass = RequestBuilder.Pass(number: nil, logToken: nil, discardsOutput: true,
                                       measuresLoudness: true)
        let arguments = try self.arguments(conversion, pass: pass)

        XCTAssertTrue(arguments[position(of: "-filter_complex", in: arguments)! + 1]
            .hasSuffix(":print_format=json[aout]"))

        // Printing it is not enough: loudnorm writes at info level and FFmpegTask runs ffmpeg at
        // warning, so the measuring pass has to ask for the lines it is going to read.
        XCTAssertEqual(arguments[position(of: "-loglevel", in: arguments)! + 1], "repeat+level+info")

        // And only for that pass - info on a real conversion is thousands of lines of noise.
        let real = try self.arguments(Conversion(from: source, to: destination, audio: audio))
        XCTAssertFalse(real.contains("-loglevel"))
    }

    func testTheSecondPassNormalisesAgainstTheMeasurement() throws {
        let audio = AudioSettings(codec: .aac, loudness: .streaming)
        let conversion = Conversion(from: source, to: destination, audio: audio)
        let measured = LoudnessMeasurement(integrated: -21.5, truePeak: -3.2, loudnessRange: 6.1,
                                           threshold: -31.8, offset: 0.4)
        let arguments = try self.arguments(conversion,
                                           pass: RequestBuilder.Pass(number: nil, logToken: nil,
                                                                     loudness: measured))

        let graph = arguments[position(of: "-filter_complex", in: arguments)! + 1]
        XCTAssertTrue(graph.contains("measured_I=-21.5"))
        XCTAssertTrue(graph.contains("measured_TP=-3.2"))
        XCTAssertTrue(graph.contains("offset=0.4"))
        // linear=true is what makes the second pass a single gain change rather than a re-guess.
        XCTAssertTrue(graph.contains("linear=true"))
    }

    func testLoudnessRefusesToShareTheGraphRatherThanGuess() throws {
        let audio = AudioSettings(codec: .aac, loudness: .streaming)
        let conversion = Conversion(inputs: [Input(url: source)],
                                    outputs: [Output(url: destination, container: .mp4, audio: audio)],
                                    filterGraph: .scale(width: 320, height: 240))

        XCTAssertThrowsError(try RequestBuilder.request(for: conversion)) { error in
            guard case FFmpegError.conflictingFilterGraph(let detail) = error else {
                return XCTFail("expected conflictingFilterGraph, got \(error)")
            }
            // The message has to carry the filter, or the caller cannot act on it.
            XCTAssertTrue(detail.contains("loudnorm="))
        }
    }

    func testLoudnessRefusesStreamMapsTheCallerWrote() throws {
        let audio = AudioSettings(codec: .aac, loudness: .streaming)
        let output = Output(url: destination, container: .mp4, audio: audio,
                            streamMaps: [.allStreams(ofInput: 0)])

        XCTAssertThrowsError(try RequestBuilder.request(
            for: Conversion(inputs: [Input(url: source)], outputs: [output])))
    }

    func testLoudnessMeasurementIsReadOutOfTheLog() throws {
        // Built through Fixture.status because a LogMessage is decoded from the service's JSON,
        // and what loudnorm prints is itself JSON - so the quotes have to survive one nesting.
        let measurement = #"{ "input_i": "-21.53", "input_tp": "-3.20", "input_lra": "6.10", "#
                        + #""input_thresh": "-31.83", "output_i": "-16.02", "target_offset": "0.40" }"#

        let log = [LogMessage(Fixture.status(domain: "info", message: "[Parsed_loudnorm_0 @ 0x0]")),
                   LogMessage(Fixture.status(domain: "info", message: measurement, escaping: true))]

        let measured = try XCTUnwrap(LoudnessMeasurement(parsing: log))
        XCTAssertEqual(measured.integrated, -21.53)
        XCTAssertEqual(measured.truePeak, -3.20)
        XCTAssertEqual(measured.loudnessRange, 6.10)
        XCTAssertEqual(measured.threshold, -31.83)
        XCTAssertEqual(measured.offset, 0.40)
    }

    /// Silence measures as -inf, which is a real answer about a real file. Refusing it would fail
    /// the conversion of anything with a silent track.
    func testSilenceMeasuresRatherThanFails() throws {
        let silent = #"{ "input_i": "-inf", "input_tp": "-inf", "input_lra": "0.00", "#
                   + #""input_thresh": "-inf", "target_offset": "0.00" }"#
        let log = [LogMessage(Fixture.status(domain: "info", message: silent, escaping: true))]

        let measured = try XCTUnwrap(LoudnessMeasurement(parsing: log))
        XCTAssertEqual(measured.integrated, -99)
    }

    func testALogWithNoMeasurementYieldsNothing() {
        XCTAssertNil(LoudnessMeasurement(parsing: [LogMessage(Fixture.status(domain: "error", message: "no such file"))]))
        XCTAssertNil(LoudnessMeasurement(parsing: []))
    }
}
