//
//  PipeReader.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 13/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation
import SiliconInk_Helper


class PipeReader {
    private var buffer: Data
    private var mutex = MutexSynchronized()

    public var data: Data {
        get {
            return buffer
        }
    }
    
    init(_ pipe: Pipe, capacity: Int = 4096) {
        self.buffer = Data(capacity: capacity)
        pipe.fileHandleForReading.readabilityHandler = appendAvailableDataToBuffer
        
    }
    
    private func appendAvailableDataToBuffer(fileHandle: FileHandle) {
        mutex.synchronize {
            buffer.append(fileHandle.availableData)
        }
    }
}
