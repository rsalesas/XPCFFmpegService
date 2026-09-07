//
//  MultiPass.swift
//  XPCFFmpeg
//
//  Conversions that need ffmpeg run more than once.
//
//  Two of them do. A two-pass video encode has to measure the whole file before it can decide
//  where the bitrate should go, and `loudnorm` has to hear the whole track before it can say how
//  far off the target it was. Both are the same shape - a measuring run that writes nothing, then
//  the real run informed by it - so they share one, and a conversion needing both pays for one
//  extra decode rather than two.
//
//  None of this is visible to a caller beyond setting `isTwoPass`. That is the point: the whole
//  reason two-pass is rare in application code is that orchestrating it by hand is tedious enough
//  to skip.
//

import Foundation
import XPCFFmpegServiceFramework


extension LoudnessMeasurement {

    /// Reads what `loudnorm=print_format=json` printed.
    ///
    /// ffmpeg writes it to stderr at the end of the run, as a JSON object among ordinary log
    /// lines, so it arrives here as a run of `LogMessage`s rather than as a document. Searching
    /// backwards finds the last one, which is the only one that matters when a graph has several.
    init?(parsing log: [LogMessage]) {
        let text = log.map { $0.message }.joined(separator: "\n")

        guard let start = text.range(of: "{", options: .backwards),
              let end = text.range(of: "}", options: .backwards, range: start.lowerBound ..< text.endIndex),
              let data = String(text[start.lowerBound ... end.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String : Any] else {
            return nil
        }

        // Every field arrives as a string, and any of them can be "-inf" on silence - which is a
        // real measurement of a real file, not a parse failure, so it maps to a number loudnorm
        // will accept back.
        func value(_ key: String) -> Double? {
            guard let raw = json[key] as? String else { return (json[key] as? NSNumber)?.doubleValue }
            if raw == "-inf" { return -99 }
            if raw == "inf" { return 99 }
            return Double(raw)
        }

        guard let integrated = value("input_i"), let truePeak = value("input_tp"),
              let loudnessRange = value("input_lra"), let threshold = value("input_thresh"),
              let offset = value("target_offset") else {
            return nil
        }

        self.init(integrated: integrated, truePeak: truePeak, loudnessRange: loudnessRange,
                  threshold: threshold, offset: offset)
    }
}


extension FFmpeg {

    /// Runs a conversion that needs measuring first.
    ///
    /// Progress from both runs is reported as one continuous 0...1, because two progress bars for
    /// one conversion is an implementation detail leaking into a window. The measuring pass is
    /// given the first third: it decodes without encoding, so it is genuinely quicker, and a bar
    /// that stalls at the handover is worse than one that is slightly wrong.
    func convertInPasses(_ conversion: Conversion, totalDuration: TimeInterval?,
                         onProgress: (@Sendable (Progress) -> Void)?) async throws -> URL? {
        let needsVideoPasses = conversion.outputs.contains { output in
            output.video?.isTwoPass == true
                || output.streamOverrides.contains {
                    if case .video(let settings) = $0.settings { return settings.isTwoPass }
                    return false
                }
        }
        let needsLoudnessPass = conversion.outputs.contains { $0.audio?.loudness?.isTwoPass == true }

        // The pass log is written by one job and read by the next, so both name the same scratch
        // token and only the second asks for it to be cleared away.
        let scratchID = UUID()
        let firstToken = needsVideoPasses ? FFmpegRequest.scratchToken(for: scratchID, retained: true) : nil
        let secondToken = needsVideoPasses ? FFmpegRequest.scratchToken(for: scratchID) : nil

        let measuring = RequestBuilder.Pass(number: needsVideoPasses ? 1 : nil,
                                            logToken: firstToken,
                                            discardsOutput: true,
                                            measuresLoudness: needsLoudnessPass)

        let measured = try await run(conversion, pass: measuring, totalDuration: totalDuration,
                                     onProgress: onProgress, from: 0, to: FFmpeg.measuringShare)

        if needsLoudnessPass && measured == nil {
            throw FFmpegError.measurementFailed("loudnorm printed no measurements")
        }

        let final = RequestBuilder.Pass(number: needsVideoPasses ? 2 : nil,
                                        logToken: secondToken,
                                        loudness: measured)

        _ = try await run(conversion, pass: final, totalDuration: totalDuration,
                          onProgress: onProgress, from: FFmpeg.measuringShare, to: 1)

        return conversion.outputs.first?.url
    }

    /// How much of the reported progress the measuring pass accounts for.
    private static let measuringShare = 0.33

    /// One pass, with its progress rescaled into a slice of the whole.
    @discardableResult
    private func run(_ conversion: Conversion, pass: RequestBuilder.Pass,
                     totalDuration: TimeInterval?,
                     onProgress: (@Sendable (Progress) -> Void)?,
                     from: Double, to: Double) async throws -> LoudnessMeasurement? {
        let job = start(try RequestBuilder.request(for: conversion, pass: pass),
                        totalDuration: totalDuration)

        if let onProgress = onProgress {
            Task { [events = job.events] in
                for await event in events {
                    if case .progress(let progress) = event {
                        onProgress(progress.scaled(from: from, to: to))
                    }
                }
            }
        }

        _ = try await job.value()

        return LoudnessMeasurement(parsing: job.log)
    }
}
