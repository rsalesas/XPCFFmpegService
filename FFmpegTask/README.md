# FFmpegTask

## Build with FFmpeg (4.2) and XPCFFmpegService Project on Mac (10.15)

This project and instructions will allow you to build FFmpegTask with FFmpeg built on your macOS platform _from scratch_. You will need to know how to use Terminal and already have installed Xcode and the Xcode command line tools. It also assumes you have at least a decent understanding of the FFmpeg project and Xcode. 


### You will need to install HomeBrew and a few packages ###

If you do not follow these steps, the project will fail to build with an error telling you what's missing.

1. Install Brew:
```
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)”
```

2. Install pkg-config, nasm, and x264 and x265 encoders. 
    - `brew install pkg-config`
    - `brew install nasm`
    - `brew install x264`
    - `brew install x265`

You can add more if you want to add them to your build of FFmpeg, but I won't cover this here (for example, libmp3lame or sdl2).


### Building the project ###

Once you have prepared the environment as above, you can open the project and build the `ffmpeg` target.

The `Make FFmpeg` build phase script will do the following.

1. It will ensure that the FFmpeg submodule is available and the required packages were installed.

2. It will configure FFmpeg with a minimum configuration required to transcode most videos, and copy it to the project folder. You may modify this as required, but be advised that it will almost certainly require additional libraries be added above. The configuration used is as follows.

```
./configure --prefix=${CONFIGURATION_BUILD_DIR} --arch=x86_64 cc="clang" \
    --extra-cflags="-fno-stack-check -mmacosx-version-min=10.13" --pkg-config="pkg-config --static" \
    --libdir=${PROJECT_DIR}/lib --incdir=${PROJECT_DIR}/include --shlibdir=${PROJECT_DIR}/Frameworks \
    --fatal-warnings --disable-shared --enable-static --enable-pthreads --enable-gpl --enable-version3 \
    --disable-avresample --disable-sdl2 --disable-bzlib --disable-xlib --disable-zlib \
    --enable-libx264 --enable-libx265 \
    --disable-programs --disable-doc 
```

This will allow x264 and x265 encoding, won't require any other third-party libraries, and will compile for a static build (as opposed to .dylibs).

**NOTE:** The `--extra-cflags="-fno-stack-check"` flag is specified to work around an Xcode 11 defect. This may be fixed in future versions. See https://trac.ffmpeg.org/ticket/8073.

3. It will run `make` and `make install` and place the `include` and `lib` files built by the process in the project folder.
      
4. It will copy additional header files from the appropriate folders in the FFmpeg folder to the `include` folder. Some of the files needed to compile the FFmpeg tools are not automatically output as part of the build process from FFmpeg.
        
This executables will not depend on any external libraries and can be deployed to any macOS 10.13 and above (this is primarily because of the HEVC encoding expected from the VideoToolbox Framework).

