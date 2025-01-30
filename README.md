# pb_play_mpeg v 0.1

by Jörg Burbach, [homepage](https://joerg-burbach.de)
license: MIT
This is a wrapper around the one-file mpeg-1-decoder pl_mpeg.h. This source also demonstrates how to (not elegantly) play a file in an imagegadget. However, audio is missing at the moment. Have to figure that out.

based on pl_mpeg.h by Dominic Szablewski, [Repository on Github](https://github.com/phoboslab/pl_mpeg)
this code uses Big Buck Bunny by Blender Foundation, which I converted to MPEG1 [Big Buck Bunny](https://studio.blender.org/projects/big-buck-bunny/)

## functions
- load from disk
- check for mpeg-file
- decode video and audio frames on demand
- get information about the video
- enable or disable video or audio
- audio is always stereo-interleaved!

## todo
- improve and optimize the code
- play audio as a test case
- use a precision timer for playback
  - like: decode frame, wait For the timer, display And already decode the Next frame
- make a Github-repo and upload it


## How-To:

### macOS:
1. pull the source for pl_mpeg.h from [Repository on Github](https://github.com/phoboslab/pl_mpeg)

2. write a small snippet to pl_mpeg.c

```
#ifdef __cplusplus
extern "C" {
#endif

#define PL_MPEG_IMPLEMENTATION
#include "pl_mpeg.h"

#ifdef __cplusplus
}
#endif
```

3. use the terminal.app with these commands
```
	gcc -c -arch arm64 pl_mpeg.c -o pl_mpeg.o
	ar rcs libplmpeg.a pl_mpeg.o
```
	
4. put the resulting libplmpeg.a where you have your PureBasic-code

5. check the example!
5b. If you need to convert your movie, use ffmpeg
```
ffmpeg -i movie.mp4 -c:v mpeg1video -b:v 500k -c:a mp2 -b:a 64k -s 320x240 -t 30 output.mpg 
```

6. You can download sample-videos from https://filesamples.com/formats/mpeg

7. enjoy
