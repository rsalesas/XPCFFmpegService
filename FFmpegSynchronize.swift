//
//  FFmpegSynchronize.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 2/1/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation


private extension UUID {

    var data: Data {
        return withUnsafeBytes(of: self.uuid, { Data($0) })
    }

}

internal class FFmpegSynchronize {
    
    private static let SynchronizeSignalBytes = UUID().data

    private let group = DispatchGroup()
    private var pipes: [Pipe:Bool] = [:]
    
    func register(pipe: Pipe) {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }

        if pipes[pipe] == nil {
            pipes[pipe] = false
            group.enter()
        }
    }
    
    func unregister(pipe: Pipe) {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
        
        if pipes[pipe] != nil {
            group.leave()
            pipes.removeValue(forKey: pipe)
        }
    }
    
    private func pipeForFileHandle(fileHandle: FileHandle) -> Pipe? {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
        
        pipes.forEach { element in
            
        }
        
        if let element = pipes.first(where: { element in element.key.fileHandleForReading == fileHandle || element.key.fileHandleForWriting == fileHandle }) {
            return element.key
        }
        
        return nil
    }
    
    func unregisterIfSignalled(pipe: Pipe) {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
            
        if let signalled = pipes[pipe], signalled == true {
            pipes[pipe] = false
            unregister(pipe: pipe)
        }
    }

    func unregisterIfSignalled(fileHandle: FileHandle) {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
            
        if let pipe = pipeForFileHandle(fileHandle: fileHandle) {
            unregisterIfSignalled(pipe: pipe)
        }
    }
    
    func signal(pipe: Pipe) {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
            
        pipe.fileHandleForWriting.write(FFmpegSynchronize.SynchronizeSignalBytes)
    }
    
    func wait() {
        group.wait()
    }
    
    func checkSignalAndAvailableData(fileHandle: FileHandle) -> Data {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }

        let data = fileHandle.availableData
        if FFmpegSynchronize.SynchronizeSignalBytes == data.suffix(FFmpegSynchronize.SynchronizeSignalBytes.count) {
            if let pipe = pipeForFileHandle(fileHandle: fileHandle) {
                pipes[pipe] = true
            }

            return data.dropLast(FFmpegSynchronize.SynchronizeSignalBytes.count)
        }
        
        return data
    }
}
