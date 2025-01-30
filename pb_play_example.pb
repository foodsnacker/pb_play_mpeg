;########################################################################################################
;# mpeg-player v 0.1 (example)
;# by Jörg Burbach
;# https://joerg-burbach.de
;# license: MIT
;# This is a wrapper around the one-file mpeg-1-decoder pl_mpeg.h. This source also demonstrates how to
;# (not elegantly) play a file in an imagegadget. However, audio is missing at the moment. Have to figure
;# that out.
;########################################################################################################
;# based on pl_mpeg.h by Dominic Szablewski, https://phoboslab.org, https://github.com/phoboslab/pl_mpeg
;# Big Buck Bunny by Blender Foundation: https://studio.blender.org/projects/big-buck-bunny/
;########################################################################################################
; functions
; - load from disk
; - check for mpeg-file
; - decode video and audio frames on demand
; - get information about the video
; - enable or disable video or audio
; - audio is always stereo-interleaved!
;
; todo
; - improve and optimize the code
; - play audio as a test case
; - use a precision timer for playback
;   - like: decode frame, wait For the timer, display And already decode the Next frame
; - make a Github-repo and upload it
;########################################################################################################

EnableExplicit

IncludeFile "pb_play_mpeg.pb"

Define mpeg = plm_create_with_filename("big_buck_bunny.mpg")
Define samplerate = plm_get_samplerate(mpeg)
Define framerate.d = plm_get_framerate(mpeg)
Define width  = plm_get_width(mpeg)
Define height = plm_get_height(mpeg)

Define count = 0, i
Define *frame.plm_frame_t, *samples.plm_samples_t

Define *pixels = AllocateMemory(width * height * 3)  ; 3 Bytes pro Pixel (BGR)
Define decoding = #True

OpenWindow(0, 100, 100, width, height, "MPEG-Player")
ImageGadget(0, 0, 0, WindowWidth(0), WindowHeight(0), 0)

If mpeg
  
  If Not plm_probe(mpeg)
    Debug "this might be no mpeg-file!"
    End
  EndIf
  
  ;   CreateFile(0, "sound.raw")
  
  If plm_decode(mpeg)
    count = 0
    ;     plm_seek(mpeg, 10)
    While decoding = #True
      *frame = plm_decode_video(mpeg)
      *samples = plm_decode_audio(mpeg)
      
      If *frame
        plm_frame_to_rgb(*frame, *pixels, width * 3)
        
        Define myimage = plm_Convert_Frame_to_Image(*pixels, width, height)
        SetGadgetState(0, ImageID(myimage))
        FreeImage(myimage)
      EndIf
      
      ; !! how would I play the sound? ring-buffer?
      ;       If *samples
      ;         WriteData(0, @*samples\interleaved, #PLM_AUDIO_SAMPLES_PER_FRAME * 2 * SizeOf(Float))
      ;       EndIf
      
      If Not *frame Or count = 100
        decoding = #False
        Break
      EndIf
      
      count + 1
      Delay(1000 / framerate)
      
      WindowEvent()
    Wend
    ;     CloseFile(0)
  EndIf
  plm_destroy(mpeg)
Else
  Debug "error loading mpeg!"
EndIf
; IDE Options = PureBasic 6.12 LTS - C Backend (MacOS X - arm64)
; CursorPosition = 19
; EnableThread
; EnableXP