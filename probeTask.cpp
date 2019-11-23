//
//  probeTask.cpp
//  ProbeTask
//
//  Created by Robert Salesas on 23/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//

extern "C" {
    #include "ffprobe.h"
}

#include <stdlib.h>
#include <stdio.h>

#include <string>
#include <vector>
#include <iostream>


// Output will be sent to stdout, and errors to stderr
// Intput is disabled, although not used in ffprobe

int main(int argc, char **argv)
{
    // Close stdin handle to prevent accidental input
    fclose(stdin);  // Use with "-nostdin" for ffmpeg but not needed with ffprobe

    // Set the necessary environment variables to control output
    setenv("AV_LOG_FORCE_NOCOLOR", "1", 1);
    
    // Set the necessary arguments to control input and output
    std::vector<std::string> flags = {"-hide_banner", "-loglevel", "repeat+level+warning",
        "-print_format", "json", "-sexagesimal"};
    std::vector<std::string> args(argv, argv + argc);
    args.insert(args.end(), flags.begin(), flags.end());
        
    // Convert to array of C strings compatible with main()
    std::vector<const char*> cargs{};
    for(const auto& string : args)
        cargs.push_back(string.c_str());
    cargs.push_back(NULL);
    
    // Call the main ffmpeg tool function
    ffprobe((int)cargs.size()-1, (char**)cargs.data());
}
