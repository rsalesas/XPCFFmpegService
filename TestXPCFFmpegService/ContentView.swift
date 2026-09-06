//
//  ContentView.swift
//  TestXPCFFmpegService
//
//  Created by Robert Salesas on 10/3/20.
//  Copyright © 2020 Robert Salesas. All rights reserved.
//

import SwiftUI
import XPCFFmpeg


struct ContentView: View {

    @ObservedObject var model: ConversionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose File…") { model.choose() }
                Button("Probe") { model.probe() }
                    .disabled(model.sourceURL == nil)
                Button("Convert to H.264") { model.convert() }
                    .disabled(model.sourceURL == nil || model.isRunning)
                Button("Cancel") { model.cancel() }
                    .disabled(!model.isRunning)
            }

            if let source = model.sourceURL {
                Text(source.lastPathComponent).font(.headline)
            }

            if model.isRunning {
                if let fraction = model.progress {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }

            if !model.status.isEmpty {
                Text(model.status).foregroundColor(.secondary)
            }

            if !model.result.isEmpty {
                Text(model.result).font(.system(.body, design: .monospaced))
            }

            if !model.error.isEmpty {
                Text(model.error).foregroundColor(.red)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
