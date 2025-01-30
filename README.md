pb_play_mpeg v 0.1
by Jörg Burbach, https://joerg-burbach.de
license: MIT
This is a wrapper around the one-file mpeg-1-decoder pl_mpeg.h. This source also demonstrates how to (not elegantly) play a file in an imagegadget. However, audio is missing at the moment. Have to figure that out.

based on pl_mpeg.h by Dominic Szablewski, https://phoboslab.org, https://github.com/phoboslab/pl_mpeg

functions
- load from disk
- check for mpeg-file
- decode video and audio frames on demand
- get information about the video
- enable or disable video or audio

todo
- improve and optimize the code
- play audio as a test case
- use a precision timer for playback
  - like: decode frame, wait For the timer, display And already decode the Next frame
- make a Github-repo and upload it
