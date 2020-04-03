//
//  PipeConnector.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 13/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import SiliconInk_Helper
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
            return mutex.synchronize(buffer)
        }
    }
        
    public let flushHandle: FileHandle?
    public let readPipe: Pipe
    public let writePipe: Pipe

    // Add support for multiple buffers to match, for example in progress the two end of package markers
    init(read: Pipe, write: Pipe, flush: FileHandle? = nil, relayMode: RelayMode, outputHandlerType: FFmpegOutputHandler.Type? = nil) {
        
        self.readPipe = read
        self.writePipe = write
        self.flushHandle = flush
        self.outputHandlerType = outputHandlerType
        self.relayMode = relayMode
        
        if relayMode == .terminators, let outputHandlerType = self.outputHandlerType as? FFmpegOutputHandlerWithTerminators.Type {
            self.terminators = outputHandlerType.terminators
        } else {
            self.terminators = []
        }
        
        self.readPipe.fileHandleForReading.readabilityHandler = self.readabilityHandler
    }
    
    public func close() {
        mutex.synchronize {
            readPipe.fileHandleForWriting.closeFile()  // ? Flush instead?
            flushHandle?.closeFile()
            
            let availableData = self.readPipe.fileHandleForReading.availableData
            appendAvailableDataToBuffer(data: availableData)
            write(data: buffer)
        }
    }
    
    private func write(data: Data) {
        if !data.isEmpty {
            if let outputHandlerType = self.outputHandlerType {
                guard let outputHandler = outputHandlerType.init(from: data) else {
                    return
                }
        
                writePipe.fileHandleForWriting.write(outputHandler.JSON)
                writePipe.fileHandleForWriting.synchronizeFile()
                
            } else {
                writePipe.fileHandleForWriting.write(buffer)
                writePipe.fileHandleForWriting.synchronizeFile()
            }
        }
    }

    private func readabilityHandler(fileHandle: FileHandle) {
        mutex.synchronize {
            let availableData = fileHandle.availableData
            appendAvailableDataToBuffer(data: availableData)
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
                        let line = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        write(data: line)
                    }
                }
            }
        }
    }
}


