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



struct ContentView: View {
    
    weak var ffmpegInvoke: XPCFFmpegInvoke?
    
    @State var progress: String = ""
    @State var error: String = ""
    @State var status: String = ""
    @State var result: String = ""

    var body: some View {
        VStack {
            HStack {
                Text("Result: ")
                Text("\(result)")
            }
            HStack {
                Text("Error: ")
                Text("\(error)")
            }
            HStack {
                Text("Status: ")
                Text("\(status)")
            }
            HStack {
                Text("Progress: ")
                Text("\(progress)")
            }
            Button(action: { self.invoke() }) {
                Text("Make Uppercase")
            }
            Button(action: {
                self.progress = ""
                self.error = ""
                self.status = ""
                self.result = ""
            }) {
                Text("Reset")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    
    init() {
        ffmpegInvoke = nil
    }
    
    init(ffmpegInvoke: XPCFFmpegInvoke) {
        self.ffmpegInvoke = ffmpegInvoke
    }
    
    func invoke() {
        assert(ffmpegInvoke != nil, "Service has not been initiatised")
        ffmpegInvoke?.invoke(request: "-version", globalOptions: [], inputs: [], outputs: [], contentView: self)
//        ffmpegInvoke?.invoke(request: "-ffprobe", globalOptions: [], inputs: ["-i", "NotAFile"], outputs: [], contentView: self)
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
