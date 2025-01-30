;########################################################################################################
;# mpeg-player v 0.1
;# by Jörg Burbach
;# https://joerg-burbach.de
;# license: MIT
;# This is a wrapper around the one-file mpeg-1-decoder pl_mpeg.h. This source also demonstrates how to
;# (not elegantly) play a file in an imagegadget. However, audio is missing at the moment. Have to figure
;# that out.
;########################################################################################################
;# based on pl_mpeg.h by Dominic Szablewski, https://phoboslab.org, https://github.com/phoboslab/pl_mpeg
;########################################################################################################
; functions
; - load from disk
; - check for mpeg-file
; - decode video and audio frames on demand
; - get information about the video
; - enable or disable video or audio
;
; todo
; - improve and optimize the code
; - play audio as a test case
; - use a precision timer for playback
;   - like: decode frame, wait For the timer, display And already decode the Next frame
; - make a Github-repo and upload it
;########################################################################################################

EnableExplicit

ImportC "libplmpeg.a"
  plm_create_with_filename(FileName.p-utf8)     ; load an mpeg-file from disk
  plm_destroy(handle)                           ; remove the handle and all data associated. HAS to be called
  plm_probe(handle)                             ; is this a real mpeg 1-file? 
  
  ; Decoding
  plm_decode(handle)                            ; start decoding
  plm_decode_video(handle)                      ; decode exactly one frame of the video
  plm_decode_audio(handle)                      ; decode audio
  plm_audio_decode_frame(handle)                ; decode exactly one frame of the audio
  
  ; conversion
  plm_frame_to_rgb(handle, buffer, stride)      ; convert to RGB-format
  plm_frame_to_bgr(frame, buffer, stride)       ; convert to BGR-format (e.g. BMP)
  
  ; Stream-Information
  plm_get_num_video_streams(handle)             ; how many video-streams?
  plm_get_video_enabled(handle)                 ; is a video-stream available?
  plm_set_video_enabled(handle, enabled)        ; enable the video-stream
  plm_get_framerate.d(handle)                   ; framerate of this video, e.g. 25
  plm_get_width(handle)                         ; width of the video, e.g. 640
  plm_get_height(handle)                        ; height of the video, e.g. 480
  plm_get_duration.d(handle)                    ; length of the video in seconds, e.g. 10
  
  ; Callback
  plm_set_video_decode_callback(handle, callback, user) ; not implemented yet
  plm_set_audio_decode_callback(handle, callback, user) ; not implemented yet
  
  ; Seeking
  plm_seek(handle, time.d)                      ; seek to a moment in time, e.g. 10 seconds
  plm_rewind(handle)                            ; jump to beginning
  plm_get_time.d(handle)                        ; get current position in video
  plm_set_loop(handle, enabled)                 ; loop the video?
  
  ; Audio-Handling and information
  plm_set_audio_enabled(handle, enabled)        ; enable audio
  plm_set_audio_stream(handle, number)          ; set number of audio-stream
  plm_get_samplerate(handle)                    ; samplerate of the video, e.g. 48000
  plm_get_num_audio_streams(handle)             ; how many audio-streams?
  
EndImport

#PLM_AUDIO_SAMPLES_PER_FRAME = 1152

Structure plm_frame_t Align #PB_Structure_AlignC
  width.l
  height.l
  y_stride.l
  cr_stride.l
  cb_stride.l
  *y
  *cr
  *cb
EndStructure

Structure plm_samples_t Align #PB_Structure_AlignC
  time.d
  count.l
  interleaved.f[#PLM_AUDIO_SAMPLES_PER_FRAME]
EndStructure

Procedure plm_Convert_Frame_to_Image(*input, inputwidth, inputheight)
  Protected imageid = CreateImage(#PB_Any, inputwidth, inputheight, 32, #Black)
  Protected x,y, pixelspos
  
  If IsImage(imageid)
    pixelspos = *input
    If StartDrawing(ImageOutput(imageid))
      For y = 0 To inputheight - 1
        For x = 0 To inputwidth - 1
          Plot(x, y, RGB(PeekA(pixelspos), PeekA(pixelspos + 1), PeekA(pixelspos + 2))) ; RGB
          pixelspos + 3
        Next x
      Next y
      StopDrawing()
    EndIf    
    ProcedureReturn imageid
  EndIf
EndProcedure

Define mpeg = plm_create_with_filename("video.mpg")
Define samplerate = plm_get_samplerate(mpeg)
Define framerate.d = plm_get_framerate(mpeg)
Define width  = plm_get_width(mpeg)
Define height = plm_get_height(mpeg)

Define count = 0, i
Define *frame.plm_frame_t, *samples.plm_samples_t

Define *pixels = AllocateMemory(width * height * 3)  ; 3 Bytes pro Pixel (BGR)
Define decoding = #True

OpenWindow(0, 100, 100, width / 2, height / 2, "MPEG-Player")
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
; Folding = +
; EnableXP
; DPIAware