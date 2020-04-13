//
//  main.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 24/11/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  This is a wrapper around the ffmpeg and ffprobe (and possibly one day ffplay) programs.
//  It sets certain options to control output, and intercept it before passing it to the calling
//  program (meant to be an XPC service) in JSON format.
//

import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j

/*
    Error Codes Returned:
        0:  Success
        1:  General failure
        2:  Insufficient arguments
        3:  Invalid arguments
        4:  Unknown request
 */

exit(FFmpegTask.Application.processRequest(CommandLine.arguments).rawValue)
