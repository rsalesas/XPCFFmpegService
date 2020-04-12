//
//  AppDelegate.swift
//  TestXPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import Cocoa
import SwiftUI
import XPCFFmpegService
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j



public class MyServiceListener: XPCAnonymousListenerDelegate {
    
    init(contentView: ContentView){
        super.init(interface: XPCFFmpegStatusProtocol.self, object: FFmpegStatusUpdate(contentView: contentView))
    }

}

class XPCFFmpegInvoke: XPCServiceProxy<XPCFFmpegInvokeProtocol> {
    
    var contentView: ContentView?
    
    private lazy var listener: MyServiceListener = {
        let listener = MyServiceListener(contentView: contentView!)
        listener.resume()
        return listener
    }()

    init() {
        super.init(serviceName: "com.siliconink.XPCFFmpegService", protocol: XPCFFmpegInvokeProtocol.self)
    }
    
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], contentView: ContentView) {
        
        self.contentView = contentView
    
        service.invoke(endpoint: listener.endpoint, request: request, globalOptions: globalOptions, inputs: inputs, outputs: outputs) { object, error  in
            os_log("***** MyServiceProxy.invoke->callback")

            if object is Data {
                let data = object as! Data
                contentView.string = String(data: data, encoding: .utf8) ?? "<Error encoding to .utf8>"
            } else if let error = error {
                contentView.string = error.localizedDescription
            }
        }
    }

}



@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    
    let ffmpegInvoke = XPCFFmpegInvoke()


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView(ffmpegInvoke: ffmpegInvoke)
        ffmpegInvoke.contentView = contentView
        
        ffmpegInvoke.resume()

        // Create the window and set the content view. 
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("Main Window")
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }


}

