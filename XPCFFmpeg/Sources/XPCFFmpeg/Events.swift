//
//  Events.swift
//  XPCFFmpeg
//
//  What a running job reports as it goes.
//

import Foundation
import XPCFFmpegServiceFramework


public struct Progress: Equatable {
    public let frame: Int
    public let framesPerSecond: Double
    public let quality: Double
    public let bitrate: Bitrate?
    public let bytesWritten: Int?
    /// How far into the output we have got.
    public let encodedDuration: TimeInterval?
    public let duplicateFrames: Int
    public let droppedFrames: Int
    /// Encoding speed as a multiple of realtime, when ffmpeg reports it. 2.0 means two seconds of
    /// media encoded per second of wall clock.
    public let speed: Double?
    public let isFinished: Bool

    /// 0...1, but only when the total duration is known - which it is if the job was started from
    /// a Conversion whose input we could probe. Nil otherwise rather than a guess.
    public let fractionCompleted: Double?

    /// How much longer this looks like taking, from how much is left and how fast it is going.
    ///
    /// Nil unless both are known. It is a projection from the current speed, so it moves around
    /// early on and settles: ffmpeg's speed over the first second of a file is not what it will
    /// average over the rest of it.
    public let estimatedTimeRemaining: TimeInterval?

    init(_ raw: FFmpegProgress, totalDuration: TimeInterval?) {
        frame = raw.frame
        framesPerSecond = raw.fps
        quality = raw.quality
        bitrate = raw.bitrate.map { Bitrate(bitsPerSecond: Int($0 * 1000)) }
        bytesWritten = raw.totalSize
        encodedDuration = raw.outTime
        duplicateFrames = raw.duplicateFrames
        droppedFrames = raw.droppedFrames
        speed = raw.speed
        isFinished = raw.finished

        if let total = totalDuration, total > 0, let encoded = raw.outTime {
            fractionCompleted = min(max(encoded / total, 0), 1)

            if let speed = raw.speed, speed > 0 {
                estimatedTimeRemaining = max(total - encoded, 0) / speed
            } else {
                estimatedTimeRemaining = nil
            }
        } else {
            fractionCompleted = nil
            estimatedTimeRemaining = nil
        }
    }

    private init(_ other: Progress, fractionCompleted: Double?) {
        frame = other.frame
        framesPerSecond = other.framesPerSecond
        quality = other.quality
        bitrate = other.bitrate
        bytesWritten = other.bytesWritten
        encodedDuration = other.encodedDuration
        duplicateFrames = other.duplicateFrames
        droppedFrames = other.droppedFrames
        speed = other.speed
        isFinished = other.isFinished
        self.fractionCompleted = fractionCompleted

        // Deliberately not rescaled with the fraction. The estimate is for the pass in flight, and
        // stretching it to cover a pass that has not started would be inventing a number.
        estimatedTimeRemaining = other.estimatedTimeRemaining
    }

    /// This pass's progress expressed as its slice of the whole conversion.
    ///
    /// A two-pass encode reports one bar, not two. `isFinished` is left alone: it says the pass
    /// ended, and the caller learns the conversion ended by the call returning.
    func scaled(from start: Double, to end: Double) -> Progress {
        guard let fraction = fractionCompleted else { return self }
        return Progress(self, fractionCompleted: start + fraction * (end - start))
    }
}


extension Progress: CustomStringConvertible {
    public var description: String {
        var parts = ["frame \(frame)", String(format: "%.1f fps", framesPerSecond)]

        if let fraction = fractionCompleted {
            parts.append(String(format: "%.0f%%", fraction * 100))
        }
        if let remaining = estimatedTimeRemaining {
            parts.append(String(format: "%.0fs left", remaining))
        }
        if let encoded = encodedDuration {
            parts.append(String(format: "%.2fs", encoded))
        }
        if let bitrate = bitrate {
            parts.append(String(format: "%.1f kbits/s", Double(bitrate.bitsPerSecond) / 1000))
        }
        if droppedFrames > 0 {
            parts.append("\(droppedFrames) dropped")
        }
        if isFinished {
            parts.append("finished")
        }

        return parts.joined(separator: ", ")
    }
}


public struct LogMessage: Equatable {
    public enum Level: String {
        case unknown, quiet, panic, fatal, error, warning, info, verbose, debug, trace
    }

    public let level: Level
    public let message: String

    public var isError: Bool {
        switch level {
        case .panic, .fatal, .error: return true
        default: return false
        }
    }

    init(_ raw: FFmpegStatus) {
        level = Level(rawValue: raw.domain.rawValue) ?? .unknown
        message = raw.message
    }
}


public enum JobEvent {
    case progress(Progress)
    case log(LogMessage)
}
