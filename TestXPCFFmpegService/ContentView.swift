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
    let service: MyServiceProtocol
    
    init(){
        connection = NSXPCConnection(serviceName: "com.siliconink.XPCFFmpegService")
        connection.remoteObjectInterface = NSXPCInterface(with: MyServiceProtocol.self)
        connection.resume()
        
        service = connection.remoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as! MyServiceProtocol
    }
    
    func makeUppperCaseString(string: String, contentView: ContentView) {
        service.upperCaseString("Hello XPC") { response in
            contentView.string = response
        }
    }
}


struct ContentView: View {
    let myService: MyServiceProxy = MyServiceProxy()
    
    @State var string: String = "Hello World!"

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
