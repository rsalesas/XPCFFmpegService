# XPCFFmpegService

## An FFmpeg XPC Service for macOS

This project and instructions will allow you to build XPCFFmpegService with FFmpeg built on your macOS platform _from scratch_. You will need to know how to use Terminal and already have installed Xcode and the Xcode command line tools. It also assumes you have at least a decent understanding of the FFmpeg project and Xcode. 

There are two projects, one that provides the XPC Service, and the other that provides the task run by the XPC Service.

The task is named FFmpegTask, and is a special executable with the functionality of FFmpeg and FFprobe. The XPC Service is named XPCFFmpegService, and spawns the task as required.

### FFmpegTask ###

