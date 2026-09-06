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
        check(info.audioStreams.isEmpty, "audio dropped as requested")
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

    section("7. version, and the service is still healthy")
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
