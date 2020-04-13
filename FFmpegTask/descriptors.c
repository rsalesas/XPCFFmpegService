//
//  The following three items result in duplicate symbols if included in ffmpeg.c and ffprobe.c
//  descriptors.c
//  FFmpegTask
//
//  Created by Robert Salesas on 24/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//


const char program_name[] = "FFmpegTask";
const int program_birth_year = 2020;


// We do this here in order to not have to change the one in ffmpeg_opt.c as it is added by reference.
#define show_help_default() show_help_default_2()

void show_help_default_2(const char *opt, const char *arg)
{
    // Empty function as we don't ever show help
}


