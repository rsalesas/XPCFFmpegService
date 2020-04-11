//
//  ContentView.swift
//  TestXPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import SwiftUI
import XPCFFmpegService
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j




public class MyServiceStatusObject: NSObject, XPCFFmpegStatusProtocol {
    
    let contentView: ContentView
    
    public func progress(progress: String) {
        print("---------- \(progress)")
        contentView.string = progress
    }
    
    init(contentView: ContentView) {
        self.contentView = contentView
    }
}

public class MyServiceListener: NSObject, NSXPCListenerDelegate {
    let listener: NSXPCListener
    let contentView: ContentView
    
    var endpoint: NSXPCListenerEndpoint {
        get {
            return listener.endpoint
        }
    }
    
    init(contentView: ContentView){
        listener = NSXPCListener.anonymous()
                
        self.contentView = contentView
        
        super.init()
        
        listener.delegate = self
        listener.resume()
    }
    
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let exportedObject = MyServiceStatusObject(contentView: contentView)
        newConnection.exportedInterface = NSXPCInterface(with: XPCFFmpegStatusProtocol.self)
        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
}


public class MyServiceProxy {
    let connection: NSXPCConnection
    let service: XPCFFmpegInvokeProtocol
    var listener: MyServiceListener? = nil

    init(){
        connection = NSXPCConnection(serviceName: "com.siliconink.XPCFFmpegService")
        connection.remoteObjectInterface = NSXPCInterface(with: XPCFFmpegInvokeProtocol.self)
        connection.resume()
        
        connection.interruptionHandler = { print("MyServiceProxy.interruptionHandler") }
        connection.invalidationHandler = { print("MyServiceProxy.invalidationHandler") }
        
        
        // TODO: This should be handled in a way that lets the caller retry, etc.
        service = connection.remoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as! XPCFFmpegInvokeProtocol
    }
    
    
    func invoke(request: String, globalOptions: [String], inputs: [String], outputs: [String], contentView: ContentView) {
        
        if listener == nil {
            self.listener = MyServiceListener(contentView: contentView)
        }

        service.invoke(endpoint: listener!.endpoint, request: request, globalOptions: globalOptions, inputs: inputs, outputs: outputs) { object, error  in
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


struct ContentView: View {
     let myService: MyServiceProxy = MyServiceProxy()
    
    @State var string: String = ""
    
    var body: some View {
        VStack {
            Text("\(string)")
            Button(action: { self.invoke() }) {
                Text("Make Uppercase")
            }
            Button(action: { self.string = "" }) {
                Text("Reset")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    func invoke() {
        // self.myService.invoke(request: "-ffmpeg", globalOptions: [], inputs: ["d"], outputs: [], contentView: self)
        self.myService.invoke(request: "-version", globalOptions: [], inputs: [], outputs: [], contentView: self)
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
