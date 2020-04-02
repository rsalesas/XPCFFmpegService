//
//  ContentView.swift
//  TestXPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import SwiftUI
import XPCFFmpegService


class MyServiceProxy {
    let connection: NSXPCConnection
    let service: XPCFFmegServiceProtocol
    
    init(){
        connection = NSXPCConnection(serviceName: "com.siliconink.XPCFFmpegService")
        connection.remoteObjectInterface = NSXPCInterface(with: XPCFFmegServiceProtocol.self)
        connection.resume()
        
        service = connection.remoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as! XPCFFmegServiceProtocol
    }
    
    func makeUppperCaseString(string: String, contentView: ContentView) {
        service.invoke(request: string) { response, log, error  in
            contentView.string = response ?? error.debugDescription
        }
    }
}


struct ContentView: View {
    let myService: MyServiceProxy = MyServiceProxy()
    
    @State var string: String = "-version"

    var body: some View {
        VStack {
            Text("\(string)")
            Button(action: { self.myService.makeUppperCaseString(string: self.string, contentView: self) }) {
                Text("Make Uppercase")
            }
            Button(action: { self.string = "Hello World!" }) {
                Text("Reset")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
