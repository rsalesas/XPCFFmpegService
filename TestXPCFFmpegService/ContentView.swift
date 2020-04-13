//
//  ContentView.swift
//  TestXPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import SwiftUI
import XPCFFmpegService
import SiliconInk_Helper
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


func openfiledlg (title: String, message: String) -> URL?
{
    let myFiledialog: NSOpenPanel = NSOpenPanel()

    myFiledialog.prompt = "Test"
    myFiledialog.worksWhenModal = true
    myFiledialog.allowsMultipleSelection = false
    myFiledialog.canChooseDirectories = false
    myFiledialog.resolvesAliases = true
    myFiledialog.title = title
    myFiledialog.message = message
    myFiledialog.runModal()
    return myFiledialog.url
}

struct ContentView: View {
    
    weak var ffmpegInvoke: XPCFFmpegInvoke?
    
    @State var url: URL? = nil

    
    @State var progress: String = ""
    
    @State var error: String = ""
    @State var status: String = ProcessInfo.processInfo.isSandboxed.string
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
                Text("Invoke")
            }
            Button(action: {
                if let url = openfiledlg(title: "Test", message: "Select a file") {
                    self.url = url
                    if let data = try? Data(contentsOf: url) {
                        self.progress = data.count.string
                    }
                }
            }) {
                Text("Choose File")
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
        if let url = $url.wrappedValue, let bookmark = try? url.bookmarkData() {
            ffmpegInvoke?.invoke(request: "-ffprobe", globalOptions: ["-show_format"], inputs: ["-i"], outputs: [], url: bookmark, contentView: self)
    //        ffmpegInvoke?.invoke(request: "-version", globalOptions: [], inputs: [], outputs: [], contentView: self)
    //        ffmpegInvoke?.invoke(request: "-ffprobe", globalOptions: [], inputs: ["-i", "NotAFile"], outputs: [], contentView: self)
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
