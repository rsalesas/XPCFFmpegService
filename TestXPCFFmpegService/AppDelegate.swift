//
//  AppDelegate.swift
//  TestXPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//
//  This app is the sample for the XPCFFmpeg package: it does everything a consumer would, and
//  nothing more. Note what is absent - no NSXPCConnection, no listener endpoint, no job IDs, no
//  bookmarks. All of that is the package's business.
//

import Cocoa
import SwiftUI
import XPCFFmpeg


@NSApplicationMain
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!

    let model = ConversionModel()


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let contentView = ContentView(model: model)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("Main Window")
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
}


/// Everything the sample needs, which is one FFmpeg session and one job at a time.
@MainActor
final class ConversionModel: ObservableObject {

    @Published var status = ""
    @Published var result = ""
    @Published var error = ""
    @Published var progress: Double?
    @Published var isRunning = false
    @Published var sourceURL: URL?

    private let ffmpeg = FFmpeg()
    private var job: Job?

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.title = "Choose a movie"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url
        reset()

        Task { await describe(url) }
    }

    func probe() {
        guard let url = sourceURL else { return }
        Task { await describe(url) }
    }

    /// Transcodes to H.264 beside the source, reporting progress as it goes.
    func convert() {
        guard let source = sourceURL else { return }

        let destination = source
            .deletingPathExtension()
            .appendingPathExtension("converted.mp4")

        reset()
        isRunning = true

        Task {
            do {
                let conversion = Conversion(from: source, to: destination,
                                            video: .h264(quality: 23, preset: .veryfast),
                                            audio: .aac())

                // Started rather than awaited, so the job can be cancelled while it runs.
                let job = try ffmpeg.startConversion(conversion)
                self.job = job

                for await event in job.events {
                    switch event {
                    case .progress(let p):
                        progress = p.fractionCompleted
                        status = "frame \(p.frame) at \(Int(p.framesPerSecond)) fps"

                    case .log(let message) where message.isError:
                        error = message.message

                    case .log:
                        break
                    }
                }

                _ = try await job.value()
                result = "Wrote \(destination.lastPathComponent)"

            } catch let failure as FFmpegError {
                switch failure {
                case .cancelled: status = "Cancelled"
                default:         error = failure.localizedDescription
                }

            } catch {
                self.error = error.localizedDescription
            }

            isRunning = false
            progress = nil
            job = nil
        }
    }

    func cancel() {
        job?.cancel()
    }

    private func describe(_ url: URL) async {
        do {
            let info = try await ffmpeg.probe(url)

            var lines: [String] = []
            if let duration = info.duration {
                lines.append(String(format: "%.2fs", duration))
            }
            if let format = info.format {
                lines.append(format.formatLongName ?? format.formatName)
            }
            for stream in info.videoStreams {
                let size = stream.frameSize.map { "\($0.width)x\($0.height)" } ?? "?"
                let rate = stream.frameRate.map { String(format: "%.2f fps", $0) } ?? ""
                lines.append("video: \(stream.codecName ?? "?") \(size) \(rate)")
            }
            for stream in info.audioStreams {
                lines.append("audio: \(stream.codecName ?? "?") \(stream.channels ?? 0)ch")
            }

            result = lines.joined(separator: "\n")

        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        status = ""
        result = ""
        error = ""
        progress = nil
    }
}
