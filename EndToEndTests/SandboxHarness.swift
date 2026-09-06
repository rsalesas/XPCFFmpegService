//
//  SandboxHarness.swift
//  EndToEndTests
//
//  The same stack, but with the App Sandbox actually in force on all three processes, converting a
//  file that lives outside every container. This is what proves the descriptor design: a sandbox
//  extension cannot cross two process hops, so if FFmpegTask can read and write here, it is
//  because the descriptors carried the access.
//
//  Takes one argument: a directory outside any container - the script grants the app access to it
//  with a temporary-exception entitlement, which stands in for a user's Open panel selection.
//  (A genuine NSOpenPanel grant was verified by hand; the mechanism only requires that the client
//  can open the file, not how it came by the right.)
//
import Foundation
import XPCFFmpeg
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  PASS  \(what)" : "  FAIL  \(what)"); if !ok { failures += 1 } }

let workspace = URL(fileURLWithPath: CommandLine.arguments[1])
let outside = workspace.appendingPathComponent("outside.mp4")
let outsideOut = workspace.appendingPathComponent("outside-out.mp4")
try? FileManager.default.removeItem(at: outsideOut)

print("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
print("container: \(NSHomeDirectory())")
print("target is OUTSIDE every container: \(outside.path)")

let ffmpeg = FFmpeg()

func main() async {
    print("\n1. probe a file outside every container")
    do {
        let i = try await ffmpeg.probe(outside)
        check(i.duration != nil, "duration \(i.duration.map { String(format: "%.2fs", $0) } ?? "nil")")
        check(i.videoStreams.first?.frameSize == FrameSize(width: 640, height: 480), "640x480")
    } catch { check(false, "threw: \((error as? FFmpegError)?.localizedDescription ?? "\(error)")") }

    print("\n2. convert it, writing outside every container")
    do {
        _ = try await ffmpeg.convert(Conversion(inputs: [Input(url: outside, timeRange: .first(2))],
                                                outputs: [Output(url: outsideOut,
                                                                 video: .h264(quality: 30, preset: .ultrafast),
                                                                 audio: .disabled)]))
        check(FileManager.default.fileExists(atPath: outsideOut.path), "output written where asked")
        let info = try await ffmpeg.probe(outsideOut)
        check(abs((info.duration ?? 0) - 2) < 0.6, "output is ~2s (\(String(format: "%.2f", info.duration ?? 0)))")
    } catch { check(false, "threw: \((error as? FFmpegError)?.localizedDescription ?? "\(error)")") }

    print("\n3. a file the app itself cannot open is still refused")
    do {
        _ = try await ffmpeg.probe(URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist"))
        check(false, "reached a file it has no grant for")
    } catch { check(true, "refused") }

    print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
    exit(failures == 0 ? 0 : 1)
}
Task { await main() }
RunLoop.main.run()
