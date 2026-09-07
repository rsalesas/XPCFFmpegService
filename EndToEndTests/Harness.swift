//
//  Harness.swift
//  EndToEndTests
//
//  Drives the real XPC service and the real FFmpegTask through the public XPCFFmpeg API only.
//  No NSXPCConnection, no endpoints, no job IDs anywhere in this file - that is the whole point:
//  if this passes, an app written the documented way works.
//
//  The unit suites all run against stubs, so this is the only thing that exercises the three
//  processes together. Run it with Scripts/end-to-end.sh.
//
//  Takes one argument: a directory containing src.mp4, which the script generates.
//
import Foundation
import XPCFFmpeg
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
    if !ok { failures += 1 }
}
func section(_ s: String) { print("\n\(s)") }

/// Collects progress from the @Sendable callback, which cannot capture a var.
final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Double] = []

    func append(_ value: Double) { lock.lock(); seen.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return seen }
}

func fileSize(_ url: URL) -> Int {
    return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
}

func runningFFmpegTasks() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "FFmpegTask"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: out, encoding: .utf8)!.split(separator: "\n").count
}

let media = URL(fileURLWithPath: CommandLine.arguments[1])
let source = media.appendingPathComponent("src.mp4")

let ffmpeg = FFmpeg()

func main() async {
    section("0. the source is what the rest of these assume")
    do {
        let info = try await ffmpeg.probe(source)
        // Until the harness generated a soundtrack, every audio check below passed vacuously and
        // anything naming an audio stream failed on the media rather than on the code.
        check(!info.videoStreams.isEmpty, "source has video")
        check(!info.audioStreams.isEmpty, "source has audio")
    } catch {
        check(false, "threw: \(error)")
    }

    section("1. probe returns typed MediaInfo")
    do {
        let info = try await ffmpeg.probe(source)
        check(info.duration != nil, "duration decoded from sexagesimal (\(info.duration.map { String(format: "%.2fs", $0) } ?? "nil"))")
        check(abs((info.duration ?? 0) - 40) < 0.5, "duration is ~40s")
        check(info.videoStreams.count == 1, "one video stream")
        if let v = info.videoStreams.first {
            check(v.frameSize == FrameSize(width: 640, height: 480), "frame size \(v.frameSize.map { "\($0.width)x\($0.height)" } ?? "?")")
            check(v.frameRate.map { abs($0 - 25) < 0.01 } ?? false, "frame rate parsed from rational (\(v.frameRate ?? -1))")
            check(v.codecName == "h264", "codec \(v.codecName ?? "?")")
        }
        check(info.format?.formatName.contains("mp4") ?? false, "container \(info.format?.formatName ?? "?")")
    } catch {
        check(false, "probe threw: \(error)")
    }

    section("2. a typed Conversion transcodes, with fractional progress")
    let out1 = media.appendingPathComponent("facade_out.mov")
    do {
        var seen: [Double] = []
        let conversion = Conversion(inputs: [Input(url: source, timeRange: .first(6))],
                                    outputs: [Output(url: out1,
                                                     container: .mov,
                                                     video: .h264(quality: 28, preset: .ultrafast),
                                                     audio: .disabled)])
        try await ffmpeg.convert(conversion) { progress in
            if let f = progress.fractionCompleted { seen.append(f) }
        }
        check(FileManager.default.fileExists(atPath: out1.path), "output written")
        check(!seen.isEmpty, "fractionCompleted reported (\(seen.count) samples, max \(String(format: "%.2f", seen.max() ?? 0)))")

        let info = try await ffmpeg.probe(out1)
        check(abs((info.duration ?? 0) - 6) < 0.7, "output is ~6s - the input timeRange was honoured (\(String(format: "%.2f", info.duration ?? 0)))")
        check(info.audioStreams.isEmpty, "audio dropped as requested, and there was audio to drop")
        check(info.format?.formatName.contains("mov") ?? false, "container is mov")
    } catch {
        check(false, "convert threw: \(error)")
    }

    section("3. filter graph + resize through the typed API")
    let out2 = media.appendingPathComponent("facade_scaled.mp4")
    do {
        let conversion = Conversion(inputs: [Input(url: source, timeRange: .first(2))],
                                    outputs: [Output(url: out2,
                                                     video: .h264(quality: 30, preset: .ultrafast),
                                                     audio: .disabled)],
                                    filterGraph: .scale(width: 320, height: 240))
        _ = try await ffmpeg.convert(conversion)
        check(FileManager.default.fileExists(atPath: out2.path), "scaled output written")
    } catch {
        check(false, "scaled convert threw: \(error)")
    }
    do {
        let info = try await ffmpeg.probe(out2)
        check(info.videoStreams.first?.frameSize == FrameSize(width: 320, height: 240),
              "filter_complex applied: \(info.videoStreams.first?.frameSize.map { "\($0.width)x\($0.height)" } ?? "?")")
    } catch {
        check(false, "probe of scaled output threw: \(error)")
    }

    section("4. cancel through the façade")
    let out3 = media.appendingPathComponent("facade_cancel.mp4")
    do {
        let conversion = Conversion(inputs: [Input(url: source, readAtNativeRate: true)],
                                    outputs: [Output(url: out3, video: .h264(preset: .ultrafast), audio: .aac())])
        let job = try ffmpeg.startConversion(conversion)

        var progressCount = 0
        let watcher = Task {
            for await event in job.events {
                if case .progress = event { progressCount += 1 }
            }
        }

        var waited = 0
        while progressCount < 3 && waited < 200 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        check(progressCount >= 3, "progress flowing (\(progressCount))")
        check(runningFFmpegTasks() >= 1, "child running")

        job.cancel()

        do {
            _ = try await job.value()
            check(false, "value() should have thrown")
        } catch FFmpegError.cancelled {
            check(true, "value() threw FFmpegError.cancelled")
        } catch {
            check(false, "wrong error: \(error)")
        }

        _ = await watcher.value
        check(true, "events stream terminated rather than hanging")

        try await Task.sleep(nanoseconds: 3_000_000_000)
        check(runningFFmpegTasks() == 0, "child reaped, no orphan")
    } catch {
        check(false, "cancel test threw: \(error)")
    }

    section("5. structured cancellation cancels the conversion")
    let out4 = media.appendingPathComponent("facade_taskcancel.mp4")
    do {
        let conversion = Conversion(inputs: [Input(url: source, readAtNativeRate: true)],
                                    outputs: [Output(url: out4, video: .h264(preset: .ultrafast), audio: .aac())])
        let job = try ffmpeg.startConversion(conversion)
        let task = Task { try await job.value() }

        try await Task.sleep(nanoseconds: 2_000_000_000)
        task.cancel()

        do {
            _ = try await task.value
            check(false, "should have thrown")
        } catch FFmpegError.cancelled {
            check(true, "cancelling the awaiting Task cancelled the job")
        } catch {
            check(false, "wrong error: \(error)")
        }
    } catch {
        check(false, "task cancel test threw: \(error)")
    }

    section("6. failure carries ffmpeg's own words")
    do {
        let missing = media.appendingPathComponent("does-not-exist.mp4")
        _ = try await ffmpeg.probe(missing)
        check(false, "should have thrown for a missing file")
    } catch let e as FFmpegError {
        check(true, "threw FFmpegError")
        print("        \(e.localizedDescription)")
    } catch {
        check(false, "wrong error type: \(error)")
    }

    section("7. capability queries answer from the real build")
    do {
        let codecs = try await ffmpeg.codecs()
        let encoders = try await ffmpeg.encoders()
        check(codecs.count > 100, "\(codecs.count) codecs")
        check(encoders.count > 100, "\(encoders.count) encoders")

        // The asymmetry the queries exist for: this build reads mp3 and, since libmp3lame was
        // added, writes it too.
        let mp3 = codecs.first { $0.name == "mp3" }
        check(mp3?.canDecode == true, "mp3 decodes")
        check(encoders.contains { $0.name == "libmp3lame" }, "libmp3lame is present")
        check(encoders.contains { $0.name == "libvpx-vp9" }, "libvpx-vp9 is present")
        check(encoders.contains { $0.name == "libopus" }, "libopus is present")
        check(encoders.contains { $0.name == "libaom-av1" }, "libaom-av1 is present")

        let muxers = try await ffmpeg.muxers()
        check(muxers.contains { $0.name == "mp4" && $0.canMux }, "mp4 muxer")
        check(try await ffmpeg.filters().contains { $0.name == "loudnorm" }, "loudnorm filter")
        check(try await ffmpeg.pixelFormats().contains { $0.name == "yuv420p" }, "yuv420p")
        check(try await ffmpeg.protocols().input.contains("file"), "file protocol")
        check(!(try await ffmpeg.license()).isEmpty, "licence text")

        let hardware = await ffmpeg.hardwareEncoder(for: .hevc)
        check(hardware == .hevcVideoToolbox, "hardware HEVC offered as an option, not a default")
    } catch {
        check(false, "threw: \(error)")
    }

    section("8. the new codec libraries actually encode")
    for (name, output, settings) in [
        ("mp3", "e2e.mp3", AudioSettings(codec: .other("libmp3lame"), bitrate: .kbps(128))),
        ("opus", "e2e.opus", AudioSettings(codec: .other("libopus"), bitrate: .kbps(96))),
        ("vorbis", "e2e.ogg", AudioSettings(codec: .other("libvorbis"))),
    ] {
        let destination = media.appendingPathComponent(output)
        try? FileManager.default.removeItem(at: destination)
        do {
            let conversion = Conversion(
                inputs: [Input(url: source, timeRange: .first(2))],
                outputs: [Output(url: destination,
                                 container: output == "e2e.mp3" ? .mp3 : .ogg,
                                 video: .disabled, audio: settings)])
            _ = try await ffmpeg.convert(conversion)
            let size = fileSize(destination)
            check(size > 0, "\(name) encoded (\(size) bytes)")
        } catch {
            check(false, "\(name) threw: \(error)")
        }
    }

    section("9. two-pass runs twice and reports one continuous progress")
    do {
        let destination = media.appendingPathComponent("e2e_twopass.mp4")
        try? FileManager.default.removeItem(at: destination)

        let fractions = Fractions()
        let conversion = Conversion(
            inputs: [Input(url: source, timeRange: .first(4))],
            outputs: [Output(url: destination, container: .mp4,
                             video: VideoSettings(codec: .h264, bitrate: .kbps(400),
                                                  preset: .ultrafast, isTwoPass: true),
                             audio: .disabled, optimizeForStreaming: true)])

        _ = try await ffmpeg.convert(conversion) { progress in
            if let f = progress.fractionCompleted { fractions.append(f) }
        }

        let size = fileSize(destination)
        check(size > 0, "two-pass output written (\(size) bytes)")

        // The whole point of the scratch path: the first job wrote statistics the second read.
        // Without them the second pass fails outright, so a written file is the proof.
        let seen = fractions.values
        check(!seen.isEmpty, "progress reported (\(seen.count) samples)")
        check(seen.allSatisfy { $0 >= 0 && $0 <= 1 }, "fractions stay within 0...1 across both passes")
        check(seen.contains { $0 > 0.34 }, "the second pass reported into the upper range")

        // faststart moves the moov atom to the front; ffprobe seeing the streams is enough here.
        let info = try await ffmpeg.probe(destination)
        check(info.videoStreams.first?.codecName == "h264", "two-pass output is h264")
    } catch {
        check(false, "threw: \(error)")
    }

    section("10. loudness normalisation measures, then applies")
    do {
        let destination = media.appendingPathComponent("e2e_loudnorm.m4a")
        try? FileManager.default.removeItem(at: destination)

        let conversion = Conversion(
            inputs: [Input(url: source, timeRange: .first(3))],
            outputs: [Output(url: destination, container: .m4a,
                             video: .disabled,
                             audio: AudioSettings(codec: .aac, bitrate: .kbps(128),
                                                  loudness: .streaming))])
        _ = try await ffmpeg.convert(conversion)

        let info = try await ffmpeg.probe(destination)
        check(info.audioStreams.first?.codecName == "aac", "normalised audio written")
        check((info.duration ?? 0) > 2, "and it is the right length (\(info.duration ?? 0))")
    } catch {
        check(false, "threw: \(error)")
    }

    section("11. stills and joining")
    do {
        let thumbnail = media.appendingPathComponent("e2e_thumb.png")
        try? FileManager.default.removeItem(at: thumbnail)
        _ = try await ffmpeg.convert(.thumbnail(of: source, to: thumbnail, at: 5))
        let size = fileSize(thumbnail)
        check(size > 0, "thumbnail written (\(size) bytes)")

        let sheet = media.appendingPathComponent("e2e_sheet.png")
        try? FileManager.default.removeItem(at: sheet)
        _ = try await ffmpeg.convert(.contactSheet(of: source, to: sheet, columns: 3, rows: 2,
                                                   interval: 5))
        let sheetSize = fileSize(sheet)
        check(sheetSize > 0, "contact sheet written (\(sheetSize) bytes)")

        let joined = media.appendingPathComponent("e2e_joined.mp4")
        try? FileManager.default.removeItem(at: joined)
        _ = try await ffmpeg.convert(.joining([source, source], to: joined, container: .mp4))
        let info = try await ffmpeg.probe(joined)
        let original = try await ffmpeg.probe(source)
        check((info.duration ?? 0) > (original.duration ?? 0) * 1.8,
              "joined file is about twice as long (\(info.duration ?? 0) vs \(original.duration ?? 0))")
    } catch {
        check(false, "threw: \(error)")
    }

    section("12. chapters and colour survive the probe")
    do {
        let info = try await ffmpeg.probe(source, options: ProbeOptions(showChapters: true))
        check(info.chapters.isEmpty, "no chapters in generated media, and asking did not fail")

        let stream = info.videoStreams.first
        check(stream != nil, "video stream present")
        check(stream?.isHighDynamicRange == false, "SDR source reported as SDR")
    } catch {
        check(false, "threw: \(error)")
    }

    section("13. version, and the service is still healthy")
    do {
        let version = try await ffmpeg.version()
        check(version.version.contains("9."), "version \(version.version)")
        let info = try await ffmpeg.probe(source)
        check(info.duration != nil, "probe still works after everything above")
    } catch {
        check(false, "threw: \(error)")
    }

    print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
    exit(failures == 0 ? 0 : 1)
}

Task { await main() }
RunLoop.main.run()
