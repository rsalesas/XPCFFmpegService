//
//  main.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Foundation

class MyServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let exportedObject = XPCFFmegService()
        newConnection.exportedInterface = NSXPCInterface(with: XPCFFmegServiceProtocol.self)
        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
}


// If you assign the delegate directly to listener.delegate, the XPC stops working... ?
let delegate = MyServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
