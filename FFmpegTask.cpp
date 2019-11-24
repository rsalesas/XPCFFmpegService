//
//  FFmpegTask.c
//  Main file for FFmpegTask, a calleable process for accessing ffmpeg and ffprobe programs
//
//  Created by Robert Salesas on 24/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//

extern "C" {
    #include "ffprobe.h"
    #include "ffmpeg.h"
}

#include <stdlib.h>
#include <stdio.h>

#include <string>
#include <vector>
#include <iostream>


// The following three items result in duplicste symbols if included in ffmpeg.c and ffprobe.c
const char program_name[] = "FFmpegTask";
const int program_birth_year = 2019;

void show_help_default(const char *opt, const char *arg)
{
    // Empty function as we don't ever show help
}


// Output will be sent to stdout, and errors to stderr
// Intput is disabled, and -nostdin passed as argument
// To receive progress, use the -progress flag and a named pipe
// Or try pipe:2 to send to stderr and parse?

int callFFmpeg(std::vector<std::string> args)
{
    // Set the necessary arguments to control input and output
    std::vector<std::string> flags = {"-hide_banner",
        "-nostats", "-progress", "pipe:2",
        "-loglevel", "repeat+level+warning",
        "-nostdin"};
    args.insert(args.end(), flags.begin(), flags.end());
        
    // Convert to array of C strings compatible with main()
    std::vector<const char*> cargs{};
    for(const auto& string : args)
        cargs.push_back(string.c_str());
    cargs.push_back(NULL);
    
    // Call the main ffmpeg tool function
    return ffmpeg((int)cargs.size()-1, (char**)cargs.data());
}


// Output will be sent to stdout, and errors to stderr
// Intput is disabled, although not used in ffprobe

int callFFprobe(std::vector<std::string> args)
{
    // Set the necessary arguments to control input and output
    std::vector<std::string> flags = {"-hide_banner",
        "-loglevel", "repeat+level+warning",
        "-print_format", "json", "-sexagesimal"};
    args.insert(args.end(), flags.begin(), flags.end());
        
    // Convert to array of C strings compatible with main()
    std::vector<const char*> cargs{};
    for(const auto& string : args)
        cargs.push_back(string.c_str());
    cargs.push_back(NULL);
    
    // Call the main ffmpeg tool function
    return ffprobe((int)cargs.size()-1, (char**)cargs.data());
}

// Main entry point to the service.
// The first parameter determines whether to process (-ffmpeg) or probe (-ffprobe).
// Anything else results in an error returned.
int main(int argc, char **argv)
{
    // Close stdin handle to prevent accidental input
    fclose(stdin);  // Use with "-nostdin" for ffmpeg but not needed with ffprobe

    // Set the necessary environment variables to control output
    setenv("AV_LOG_FORCE_NOCOLOR", "1", 1);
    
    // Convert the incoming arguments into a vector of strings
    std::vector<std::string> args(argv, argv + argc);
    if (args[1] == "-ffmpeg") {
        args.erase(args.begin()+1);
        return callFFmpeg(args);
    } else if (args[1] == "-ffprobe") {
        args.erase(args.begin()+1);
        return callFFprobe(args);
    } else {
        return EXIT_FAILURE;
    }
}

