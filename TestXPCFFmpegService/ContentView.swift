//
//  ContentView.swift
//  TestXPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import SwiftUI
import XPCFFmpegService


public class FFmpegStatusUpdate: XPCFFmpegStatusProtocol {
    
    let contentView: ContentView
    
    init(contentView: ContentView) {
        self.contentView = contentView
    }

    public func progress(progress: String) {
        print("---------- \(progress)")
        contentView.string = progress
    }
}


struct ContentView: View {
    
    weak var ffmpegInvoke: XPCFFmpegInvoke?
    
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
    
    
    init() {
        ffmpegInvoke = nil
    }
    
    init(ffmpegInvoke: XPCFFmpegInvoke) {
        self.ffmpegInvoke = ffmpegInvoke
    }
    
    func invoke() {
        assert(ffmpegInvoke != nil, "Service has not been initiatised")
        ffmpegInvoke?.invoke(request: "-version", globalOptions: [], inputs: [], outputs: [], contentView: self)
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
