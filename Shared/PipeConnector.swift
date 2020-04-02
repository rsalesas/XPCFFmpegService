//
//  PipeConnector.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 13/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import SiliconInk_Helper


class PipeConnector {
            
    private let NewLine = Data([0x0A])

    enum RelayMode {
        case buffer
        case array
        case line
    }
    
    private var mutex = MutexSynchronized()
    private var buffer = Data()
    private var handler: (Data) -> Bool
    
    public let bufferMode: RelayMode

    public var data: Data {
        get {
            return buffer
        }
    }
        
    public let readPipe: Pipe
    public let writePipe: Pipe

    // Add support for multiple buffers to match, for example in progress the two end of package markers
    init(read: Pipe, write: Pipe, bufferMode: RelayMode, handler: @escaping (Data) -> Bool) {
        self.readPipe = read
        self.writePipe = write
        self.handler = handler
        self.bufferMode = bufferMode
        
        self.readPipe.fileHandleForReading.readabilityHandler = self.appendAvailableDataToBuffer
    }
    
    public func close() {
        mutex.synchronize {
            readPipe.fileHandleForWriting.closeFile()  // ? Flush instead?
            relay(data: buffer)
        }
    }
    
    public func flush() {
        mutex.synchronize {
            readPipe.fileHandleForWriting.synchronizeFile()
            relay(data: buffer)
        }
    }
    
    private func relay(data: Data) {
        mutex.synchronize {
            if !buffer.isEmpty {
                writePipe.fileHandleForWriting.write(data)
            }
        }
    }
    
    private func appendAvailableDataToBuffer(fileHandle: FileHandle) {
        mutex.synchronize {
            let availableData = fileHandle.availableData
            if !availableData.isEmpty {
                buffer.append(fileHandle.availableData)

                if bufferMode == .buffer {
                    relay(data: buffer)
                }
                else if let range = buffer.range(of: NewLine) {
                    //buffer.range(of: NewLine, options: [], in: buffer.startIndex..<buffer.endIndex) {
                    let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.remove(buffer.startIndex..<range.upperBound)
                    //buffer.replaceSubrange(buffer.startIndex..<range.upperBound, with: [])
                    relay(data: line)
                }
            }
        }
    }
}



extension Data {
    
    mutating func remove(_ subrange: Range<Data.Index>) {
        replaceSubrange(subrange, with: [])
    }
    
}
