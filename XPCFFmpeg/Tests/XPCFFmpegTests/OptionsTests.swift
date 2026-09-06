import XCTest
@testable import XPCFFmpeg

final class OptionsTests: XCTestCase {

    func testVideoCodecArguments() {
        XCTAssertEqual(VideoCodec.h264.argument, "libx264")
        XCTAssertEqual(VideoCodec.hevc.argument, "libx265")
        XCTAssertEqual(VideoCodec.proRes.argument, "prores_videotoolbox")
        XCTAssertEqual(VideoCodec.copy.argument, "copy")
        XCTAssertEqual(VideoCodec.other("av1_videotoolbox").argument, "av1_videotoolbox")
    }

    func testAudioCodecArguments() {
        XCTAssertEqual(AudioCodec.aac.argument, "aac")
        XCTAssertEqual(AudioCodec.alac.argument, "alac")
        XCTAssertEqual(AudioCodec.flac.argument, "flac")
        XCTAssertEqual(AudioCodec.copy.argument, "copy")
        XCTAssertEqual(AudioCodec.other("opus").argument, "opus")
    }

    func testContainerArguments() {
        XCTAssertEqual(Container.mp4.argument, "mp4")
        XCTAssertEqual(Container.mov.argument, "mov")
        XCTAssertEqual(Container.matroska.argument, "matroska")
        // ffmpeg's m4a muxer is spelled "ipod", which is exactly the sort of thing the typed
        // vocabulary exists to hide.
        XCTAssertEqual(Container.m4a.argument, "ipod")
        XCTAssertEqual(Container.wav.argument, "wav")
        XCTAssertEqual(Container.other("webm").argument, "webm")
    }

    func testBitrate() {
        XCTAssertEqual(Bitrate(bitsPerSecond: 128_000).argument, "128000")
        XCTAssertEqual(Bitrate.kbps(320).bitsPerSecond, 320_000)
        XCTAssertEqual(Bitrate.mbps(2.5).bitsPerSecond, 2_500_000)
        XCTAssertEqual(Bitrate.kbps(1).argument, "1000")
    }

    func testFrameSize() {
        XCTAssertEqual(FrameSize(width: 640, height: 480).argument, "640x480")
        XCTAssertEqual(FrameSize.hd720, FrameSize(width: 1280, height: 720))
        XCTAssertEqual(FrameSize.hd1080, FrameSize(width: 1920, height: 1080))
        XCTAssertEqual(FrameSize.uhd4K, FrameSize(width: 3840, height: 2160))
    }

    func testTimeRangeConstructors() {
        XCTAssertEqual(TimeRange.from(12).start, 12)
        XCTAssertNil(TimeRange.from(12).duration)
        XCTAssertEqual(TimeRange.first(5).duration, 5)
        XCTAssertNil(TimeRange.first(5).start)

        let both = TimeRange(start: 1, duration: 2)
        XCTAssertEqual(both.start, 1)
        XCTAssertEqual(both.duration, 2)
    }

    func testStreamMapSpecifiers() {
        XCTAssertEqual(StreamMap.allStreams(ofInput: 1).argument, "1")
        XCTAssertEqual(StreamMap.video(ofInput: 0).argument, "0:v")
        XCTAssertEqual(StreamMap.video(ofInput: 0, index: 2).argument, "0:v:2")
        XCTAssertEqual(StreamMap.audio(ofInput: 1).argument, "1:a")
        XCTAssertEqual(StreamMap.audio(ofInput: 1, index: 0).argument, "1:a:0")
        XCTAssertEqual(StreamMap.subtitles(ofInput: 2).argument, "2:s")
        XCTAssertEqual(StreamMap.subtitles(ofInput: 2, index: 1).argument, "2:s:1")
        XCTAssertEqual(StreamMap.specifier("0:v:m:language:eng").argument, "0:v:m:language:eng")
    }

    func testEncoderPresetRawValues() {
        XCTAssertEqual(EncoderPreset.ultrafast.rawValue, "ultrafast")
        XCTAssertEqual(EncoderPreset.veryslow.rawValue, "veryslow")
        XCTAssertEqual(EncoderPreset(rawValue: "medium"), .medium)
    }

    func testFilterGraphComposition() {
        XCTAssertEqual(FilterGraph.scale(width: 1280, height: 720).description, "scale=1280:720")
        XCTAssertEqual(FilterGraph.chain(["scale=640:480", "fps=30"]).description, "scale=640:480,fps=30")
        XCTAssertEqual(FilterGraph.graph(["[0:v]scale=640:480[a]", "[a]fps=30"]).description,
                       "[0:v]scale=640:480[a];[a]fps=30")

        let literal: FilterGraph = "hflip"
        XCTAssertEqual(literal.description, "hflip")
        XCTAssertEqual(FilterGraph("vflip"), FilterGraph("vflip"))
    }

    func testSettingsConveniences() {
        XCTAssertEqual(VideoSettings.h264().codec, .h264)
        XCTAssertEqual(VideoSettings.h264(quality: 18, preset: .slow).quality, 18)
        XCTAssertEqual(VideoSettings.h264(quality: 18, preset: .slow).preset, .slow)
        XCTAssertEqual(VideoSettings.hevc().codec, .hevc)
        XCTAssertEqual(VideoSettings.hevc().quality, 28)
        XCTAssertEqual(VideoSettings.copy.codec, .copy)
        XCTAssertTrue(VideoSettings.disabled.isDisabled)
        XCTAssertFalse(VideoSettings.copy.isDisabled)

        XCTAssertEqual(AudioSettings.aac().codec, .aac)
        XCTAssertEqual(AudioSettings.aac(.kbps(96)).bitrate, .kbps(96))
        XCTAssertEqual(AudioSettings.copy.codec, .copy)
        XCTAssertTrue(AudioSettings.disabled.isDisabled)
    }

    func testConversionConvenienceInit() {
        let sandbox = Fixture.Sandbox()
        let conversion = Conversion(from: sandbox.existingFile, to: sandbox.url("out.mp4"),
                                    video: .copy, audio: .copy, container: .mp4)

        XCTAssertEqual(conversion.inputs.count, 1)
        XCTAssertEqual(conversion.outputs.count, 1)
        XCTAssertEqual(conversion.outputs[0].container, .mp4)
        XCTAssertTrue(conversion.overwriteExisting)
        XCTAssertNil(conversion.filterGraph)
    }
}
