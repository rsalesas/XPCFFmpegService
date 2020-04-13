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
import XPCFFmpegServiceFramework
import SiliconInk_Helper

import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j




public class FFmpegStatusUpdateListenerDelegate: XPCAnonymousListenerDelegate, XPCFFmpegStatusProtocol {
    
    let contentView: ContentView

    init(contentView: ContentView){
        self.contentView = contentView

        super.init(interface: XPCFFmpegStatusProtocol.self)
    }
    
    public func progress(progress: String) {
        os_log("---------- %@", progress)
        contentView.progress = progress
    }

}

class XPCFFmpegInvoke: XPCServiceProxy<XPCFFmpegInvokeProtocol> {
    
    init() {
        super.init(serviceName: "com.siliconink.XPCFFmpegService", protocol: XPCFFmpegInvokeProtocol.self)
    }
    
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], contentView: ContentView) {
        
        var listener: FFmpegStatusUpdateListenerDelegate? = FFmpegStatusUpdateListenerDelegate(contentView: contentView)
        listener?.resume()
    
        proxy.invoke(endpoint: listener!.endpoint, request: request, globalOptions: globalOptions, inputs: inputs, outputs: outputs) { object, error  in
            os_log("***** MyServiceProxy.invoke->callback")

            listener = nil
            
            if object is Data {
                let data = object as! Data
                contentView.result = String(data: data, encoding: .utf8) ?? "<Error encoding to .utf8>"
            } else if let error = error {
                contentView.error = error.localizedDescription
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

