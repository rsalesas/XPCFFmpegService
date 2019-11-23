//
//  test.c
//  ProcessTask
//
//  Created by Robert Salesas on 23/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
#include "ffprobe.h"
#include <stdlib.h>

int main(int argc, char **argv)
{
    // Set the necessary environment variables to control output
    setenv("AV_LOG_FORCE_NOCOLOR", "1", 1);
    
    // Set the necessary arguments to control output
    
    
    ffprobe(argc, argv);
}
