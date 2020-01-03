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
    private var signalled: Bool = false

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
    
    private func unregisterIfSignalled(pipe: Pipe) {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
            
        if let signalled = pipes[pipe], signalled == true {
            pipes[pipe] = false
            unregister(pipe: pipe)
        }
    }

    func enter(fileHandle: FileHandle) -> Data? {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }

        var data = fileHandle.availableData
        if signalled, FFmpegSynchronize.SynchronizeSignalBytes == data.suffix(FFmpegSynchronize.SynchronizeSignalBytes.count) {
            if let pipe = pipeForFileHandle(fileHandle: fileHandle) {
                pipes[pipe] = true
            }

            data = data.dropLast(FFmpegSynchronize.SynchronizeSignalBytes.count)
        }
        
        return data.isEmpty ? nil : data
    }
    
    func exit(fileHandle: FileHandle) {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
            
        if let pipe = pipeForFileHandle(fileHandle: fileHandle) {
            unregisterIfSignalled(pipe: pipe)
        }
    }
    
    func signal() {
        objc_sync_enter(group)
        defer { objc_sync_exit(group) }
            
        signalled = true
        pipes.forEach { element in
            element.key.fileHandleForWriting.write(FFmpegSynchronize.SynchronizeSignalBytes)
        }
    }
    
    func wait() {
        group.wait()
    }
    

}
