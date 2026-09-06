//
//  PipeConnector.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 13/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


class PipeConnector {
            
    private let NewLine = Data([0x0A])

    // TODO: Move this to the OutputHandler to self-identify
    enum RelayMode {
        case available
        case terminators
        case line
        case end
    }
    
    private var mutex = MutexSynchronized()
    private var buffer = Data()
    private var outputHandlerType: FFmpegOutputHandler.Type?
    private var terminators: [Data]
    
    public let relayMode: RelayMode

    public var data: Data {
        get {
            return mutex.synchronize { buffer }
        }
    }
        
    public let readFh: FileHandle
    public let writeFh: FileHandle


    init(read: FileHandle, write: FileHandle, relayMode: RelayMode, outputHandlerType: FFmpegOutputHandler.Type? = nil) {
        
        self.readFh = read
        self.writeFh = write
        self.outputHandlerType = outputHandlerType
        self.relayMode = relayMode
        
        if relayMode == .terminators, let outputHandlerType = self.outputHandlerType as? FFmpegOutputHandlerWithTerminators.Type {
            self.terminators = outputHandlerType.terminators
        } else {
            self.terminators = []
        }
        
        self.readFh.readabilityHandler = self.readabilityHandler
    }
    
    public func flush() {
        mutex.synchronize {
            self.readFh.readabilityHandler = nil
            
            if let availableData = try? readFh.availableData(timeout: 0) {
                appendAvailableDataToBuffer(data: availableData)
            }
            
            write(data: buffer)
        }
    }
    
    /// stderr carries two connectors - status lines and progress records - writing to the same
    /// descriptor. A frame split across two interleaved writes would desynchronise the reader for
    /// good, so every frame goes out under one lock, whole.
    private static let writeLock = MutexSynchronized()

    private func write(data: Data) {
        if !data.isEmpty {
            // Relay what FFmpeg actually printed, instead of what the output handler made of it.
            // This is how FFmpegTaskTests' fixtures are captured - see Scripts/ffmpeg-fixtures.sh.
            // Those fixtures have to be real FFmpeg output: hand-written samples would encode
            // someone's reading of the format and would have gone on passing while -pix_fmts and
            // -filters parsed nothing at all. Unframed on purpose, so the capture is exactly what
            // FFmpeg wrote. Never set in production.
            if ProcessInfo.processInfo.environment["FFMPEGTASK_CAPTURE_RAW"] != nil {
                PipeConnector.writeLock.synchronize { writeFh.write(data) }
                return
            }

            let payload: Data

            if let outputHandlerType = self.outputHandlerType {
                guard let outputHandler = outputHandlerType.init(from: data) else {
                    return
                }
                payload = outputHandler.JSON

            } else {
                payload = buffer
            }

            guard let framed = PipeFraming.frame(payload) else { return }
            PipeConnector.writeLock.synchronize { writeFh.write(framed) }
        }
    }

    private func readabilityHandler(fileHandle: FileHandle) {
        mutex.synchronize {
            if let availableData = try? readFh.availableData(timeout: 0) {
                if availableData.isEmpty {
                    self.readFh.readabilityHandler = nil
                } else {
                    appendAvailableDataToBuffer(data: availableData)
                }
            }
        }
    }
    
    private func appendAvailableDataToBuffer(data: Data) {
        if !data.isEmpty {
            buffer.append(data)

            if relayMode == .available {
                write(data: buffer)
                
            } else if relayMode == .line {
                while let range = buffer.range(of: NewLine) {
                    let line = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    if line != NewLine {
                        write(data: line)
                    }
                }
                
            } else if relayMode == .terminators && terminators.count > 0 {
                terminators.forEach { match in
                    while let range = buffer.range(of: match) {
                        let data = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        write(data: data)
                    }
                }
            }
        }
    }
}


