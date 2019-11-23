//
//  processTask.cpp
//  ProcessTask
//
//  Created by Robert Salesas on 23/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//

extern "C" {
    #include "ffmpeg.h"
}

#include <stdlib.h>
#include <stdio.h>

#include <string>
#include <vector>
#include <iostream>


// Output will be sent to stdout, and errors to stderr
// Intput is disabled, and -nostdin passed as argument
// To receive progress, use the -progress flag and a named pipe
// Or try pipe:2 to send to stderr and parse?

int main(int argc, char **argv)
{
    // Close stdin handle to prevent accidental input
    fclose(stdin);  // Use with "-nostdin" for ffmpeg

    // Set the necessary environment variables to control output
    setenv("AV_LOG_FORCE_NOCOLOR", "1", 1);
    
    // Set the necessary arguments to control input and output
    std::vector<std::string> flags = {"-hide_banner", "-loglevel", "repeat+level+warning",
        "-nostdin"};
    std::vector<std::string> args(argv, argv + argc);
    args.insert(args.end(), flags.begin(), flags.end());
        
    // Convert to array of C strings compatible with main()
    std::vector<const char*> cargs{};
    for(const auto& string : args)
        cargs.push_back(string.c_str());
    cargs.push_back(NULL);
    
    // Call the main ffmpeg tool function
    ffmpeg((int)cargs.size()-1, (char**)cargs.data());
}
