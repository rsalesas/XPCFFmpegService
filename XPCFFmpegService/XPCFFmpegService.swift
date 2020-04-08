//
//  XPCFFmegService.swift
//  XPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//




// TODO: Look at @functionbuilder as a way of creating the arguments for filters, inputs, etc.
// Class subscripts?

/*
 
 Before we get further into the data case, a quick note about NSXPCConnection and the low-level <xpc/xpc.h> API.  These are closely related and, for the most part, the high-level API supports everything supported by the low-level API.  There is, however, one critical caveat: The low-level API lets you transport more types over the connection.
 For example, imagine you want to create an XPC Service where one part of your code uses NSXPCConnection and another part uses the low-level API.  Historically this was tricky because a) an XPC Service can only register a single service, and b) there’s no way to transport an xpc_endpoint_t over NSXPCConnection and there’s no way to transport an NSXPCListenerEndpoint over xpc_connection_t.
 This has been resolved in 10.15.  There we added -[NSXPCInterface setXPCType:forSelector:argumentIndex:ofReply:], which allows you to transport arbitrary XPC objects over NSXPCConnection.  Yay!
 Note The availability macros on that method indicate that it’s available since 10.14.  That’s not my experience, and I’ve filed a bug to get that corrected (r. 57736296).
 Historically this use to crop up when folks were trying to transport an IOSurface.  That API has an IOSurfaceCreateXPCObject routine that returns a low-level XPC object that represents the surface, but you couldn’t transport that over an NSXPCConnection.  However, that specific problem got resolved on 10.12 where we introduced a new Objective-C IOSurface object, and that object is transportable directly over NSXPCConnection.  So double yay!
 
 Both NSXPCConnection and the low-level XPC API let you explicitly transport shared memory objects over the connection.  The low-level API supports this explicitly via a shared memory object (XPC_TYPE_SHMEM), create using xpc_shmem_create.  In contrast, for NSXPCConnection you must created a POSIX shared memory object (using shm_open man page), wrap the resulting file descriptor into an NSFileHandle, and then pass that over the XPC connection.
 Note You can actually use the latter technique with the low-level API as well, using an XPC_TYPE_FD object created using xpc_fd_create.  I can’t see any advantage of doing that, but there’s probably some subtlety I’ve missed.
 Overall, I can’t help but think that this might be the best option for you.  That is, set up a pool of shared memory regions and then just include the region ID in the XPC message.  It’s hard to imagine any other approach having a lower overhead.
 Of course shared memory raises both security and correctness issues.  Given that this is an app-specific XPC Service, I don’t think security is a big concern.  However, correctness is always a challenge.  Specifically, you have to prevent the XPC Service from modifying the buffer while the client is still using it.
 
 https://forums.developer.apple.com/thread/126716
 */


import Foundation
import SiliconInk_Helper


@objc public protocol XPCFFmegServiceProtocol {
    
    typealias CompletionHandler = (_ response: Data?, _ log: Data?, _ error: Error?) -> Void

    
    func invoke(request: String, completionHandler handler: @escaping (CompletionHandler))
    
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], completionHandler handler: @escaping (CompletionHandler))

    func invoke(request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], completionHandler handler: @escaping (CompletionHandler))

}


class XPCFFmegService: NSObject, XPCFFmegServiceProtocol {
    
    func invoke(request: String, completionHandler handler: @escaping (CompletionHandler)) {
        invoke(request: request, globalOptions: [], inputs: [], filters: [], outputs: [], completionHandler: handler)
    }
        
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], completionHandler handler: @escaping (CompletionHandler)) {
        invoke(request: request, globalOptions: globalOptions, inputs: inputs, filters: [], outputs: outputs, completionHandler: handler)
    }
    
    func invoke(request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], completionHandler handler: @escaping (CompletionHandler)) {
        
//        handler(String("Test").data(using: .utf8), nil, nil)
//        return
        
        let ffmpegTaskProcess = FFmpegTaskProcess(completionHandler: handler)
        ffmpegTaskProcess.invoke(arguments: [request] + globalOptions + inputs + filters + outputs)
    }
    
}
