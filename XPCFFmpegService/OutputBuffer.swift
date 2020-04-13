//
//  BufferedPipe.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 13/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation

class OutputBuffer {
    private var buffer: Data

    
    init(handle: FileHandle, capacity: Int = 4096) {
        self.buffer = Data(capacity: capacity)
        handle.readabilityHandler = appendAvailableDataToBuffer
        
    }
    
    private func appendAvailableDataToBuffer(fileHandle: FileHandle) {
        synchronized(fileHandle) {
            buffer.append(fileHandle.availableData)
        }
    }
}
