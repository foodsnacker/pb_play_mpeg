;########################################################################################################
;# mpeg-player with audio v 0.2
;# by Jörg Burbach
;# https://joerg-burbach.de
;# license: MIT
;#
;# Plays an MPEG-1 file with video (ImageGadget) and stereo audio (macOS AudioUnit via MacAudioOut).
;# Audio is routed through a lock-free SPSC ring buffer:
;#   - Main thread decodes MPEG audio frames and pushes interleaved stereo floats into the ring.
;#   - MacAudioOut render callback (audio thread) pulls from the ring in separate L/R buffers.
;# Video timing uses ElapsedMilliseconds() for frame-accurate pacing.
;########################################################################################################
;# based on pl_mpeg.h by Dominic Szablewski, https://phoboslab.org, https://github.com/phoboslab/pl_mpeg
;# Big Buck Bunny by Blender Foundation: https://studio.blender.org/projects/big-buck-bunny/
;########################################################################################################

EnableExplicit

IncludeFile "pb_play_mpeg.pb"
IncludeFile "mac_audio_out.pb"

;---- Lock-free SPSC ring buffer ---------------------------------------------------------------
; Size must be a power of 2. We use 32768 samples ≈ 0.74 s at 44100 Hz – plenty of headroom.
#RB_SIZE = 32768
#RB_MASK = #RB_SIZE - 1

; Monotonically increasing write / read counters (only wrap on 64-bit integer overflow – harmless).
; rb_write is written by the main thread only; rb_read by the audio thread only.
Global rb_write.i = 0   ; samples pushed so far
Global rb_read.i  = 0   ; samples consumed so far

; Separate L and R sample arrays (non-interleaved) so the render callback can hand them
; directly to MacAudioOut without an extra copy.
Global Dim rb_L.f(#RB_SIZE - 1)
Global Dim rb_R.f(#RB_SIZE - 1)

; Returns number of samples currently available for the audio callback to read.
Procedure.i RB_Available()
  ProcedureReturn rb_write - rb_read
EndProcedure

; Returns free space (samples the main thread may safely write without overwriting unread data).
Procedure.i RB_Free()
  ProcedureReturn #RB_SIZE - (rb_write - rb_read)
EndProcedure

; Push one decoded plm_samples_t into the ring buffer.
; plm_samples_t\interleaved layout: L0, R0, L1, R1, ... (stereo interleaved, 32-bit float)
Procedure RB_Push(*s.plm_samples_t)
  Protected i.i
  Protected w.i  = rb_write
  Protected free.i = RB_Free()
  Protected n.i  = *s\count
  If n > free : n = free : EndIf   ; drop excess if buffer is full (shouldn't happen with pre-fill)
  For i = 0 To n - 1
    rb_L(w & #RB_MASK) = *s\interleaved[i * 2]       ; left channel
    rb_R(w & #RB_MASK) = *s\interleaved[i * 2 + 1]   ; right channel
    w + 1
  Next
  rb_write = w  ; publish – audio thread reads this after the loop
EndProcedure

;---- MacAudioOut render callback --------------------------------------------------------------
; Called on the CoreAudio real-time thread. Must not allocate memory or block.
; Reads from the ring buffer; outputs silence on underrun.
ProcedureC AudioRenderCallback(*left.Float, *right.Float, frames.i, sampleRate.i, userData.i)
  Protected i.i
  Protected r.i     = rb_read
  Protected avail.i = rb_write - r   ; snapshot of available samples

  For i = 0 To frames - 1
    If i < avail
      *left\f  = rb_L((r + i) & #RB_MASK)
      *right\f = rb_R((r + i) & #RB_MASK)
    Else
      *left\f  = 0.0   ; underrun – output silence
      *right\f = 0.0
    EndIf
    *left  + SizeOf(Float)
    *right + SizeOf(Float)
  Next

  ; Advance read pointer by however many real samples we consumed
  If avail >= frames
    rb_read = r + frames
  Else
    rb_read = r + avail
  EndIf
EndProcedure

;---- Open MPEG file ---------------------------------------------------------------------------
Define mpeg     = plm_create_with_filename("big_buck_bunny.mpg")

If mpeg = 0
  MessageRequester("Error", "Could not open big_buck_bunny.mpg")
  End 1
EndIf

If Not plm_probe(mpeg)
  MessageRequester("Error", "File does not appear to be a valid MPEG-1 stream.")
  plm_destroy(mpeg)
  End 1
EndIf

Define samplerate.i = plm_get_samplerate(mpeg)
Define framerate.d  = plm_get_framerate(mpeg)
Define width.i      = plm_get_width(mpeg)
Define height.i     = plm_get_height(mpeg)
Define duration.d   = plm_get_duration(mpeg)

Define *pixels = AllocateMemory(width * height * 3)
If *pixels = 0
  MessageRequester("Error", "Out of memory for pixel buffer.")
  plm_destroy(mpeg)
  End 1
EndIf

;---- Pre-fill ring buffer with ~0.3 s of audio -----------------------------------------------
; Start decoding from the beginning so audio is ready before the first video frame is shown.
Define *prefillSamples.plm_samples_t
Define prefillTarget.i = samplerate / 3    ; ~333 ms
While RB_Available() < prefillTarget
  *prefillSamples = plm_decode_audio(mpeg)
  If *prefillSamples = 0 : Break : EndIf
  RB_Push(*prefillSamples)
Wend

; Rewind so video and audio both start at t=0
plm_rewind(mpeg)

; The pre-fill samples are still in the ring buffer; the decoder position is at the beginning,
; so audio frames will be re-decoded and will naturally catch up.  The initial latency (~333 ms)
; prevents underruns during the first few video frames.

;---- Init audio output ------------------------------------------------------------------------
MacAudioOut::SetRenderCallback(@AudioRenderCallback())
If MacAudioOut::Init(samplerate) = #False
  MessageRequester("Error", "MacAudioOut::Init failed (OSStatus=" + Str(MacAudioOut::LastStatus()) + ")")
  FreeMemory(*pixels)
  plm_destroy(mpeg)
  End 1
EndIf
MacAudioOut::SetVolume(0.85)

;---- Open window ------------------------------------------------------------------------------
OpenWindow(0, 100, 60, width, height, "MPEG Player – " + width + "×" + height +
           "  " + StrD(framerate, 2) + " fps  " + Str(samplerate) + " Hz  " +
           StrD(duration, 1) + " s")
ImageGadget(0, 0, 0, WindowWidth(0), WindowHeight(0), 0)

;---- Start audio playback ---------------------------------------------------------------------
If MacAudioOut::Play() = #False
  MessageRequester("Error", "MacAudioOut::Play failed (OSStatus=" + Str(MacAudioOut::LastStatus()) + ")")
  MacAudioOut::Shutdown()
  FreeMemory(*pixels)
  plm_destroy(mpeg)
  End 1
EndIf

;---- Main playback loop -----------------------------------------------------------------------
; Strategy:
;   1. Decode the next video frame.
;   2. Decode audio frames until audio time ≥ video time (keeps A/V in sync).
;   3. Push decoded audio into the ring buffer.
;   4. Display the video frame.
;   5. Wait until the wall-clock time matches the frame's presentation time.

Define *frame.plm_frame_t
Define *samples.plm_samples_t
Define myimage.i
Define startWall.i  = ElapsedMilliseconds()
Define frameCount.i = 0
Define msPerFrame.d = 1000.0 / framerate
Define running.i    = #True
Define event.i

While running

  ;-- Decode video ---
  *frame = plm_decode_video(mpeg)
  If *frame = 0
    running = #False
    Break
  EndIf

  ;-- Decode audio up to the current video timestamp ------------------------------------
  ; plm_get_time() returns the decoder's current position (tracks video).
  ; We keep decoding audio frames while the ring has room and audio lags behind video.
  Repeat
    If RB_Free() < #PLM_AUDIO_SAMPLES_PER_FRAME : Break : EndIf
    *samples = plm_decode_audio(mpeg)
    If *samples = 0 : Break : EndIf
    RB_Push(*samples)
  Until *samples\time >= plm_get_time(mpeg)

  ;-- Render video frame to ImageGadget -------------------------------------------------
  plm_frame_to_rgb(*frame, *pixels, width * 3)
  myimage = plm_Convert_Frame_to_Image(*pixels, width, height)
  SetGadgetState(0, ImageID(myimage))
  FreeImage(myimage)

  frameCount + 1

  ;-- Frame timing: wait until the wall clock reaches the frame's due time ---------------
  Define dueMs.i = startWall + frameCount * msPerFrame
  Define nowMs.i = ElapsedMilliseconds()
  If nowMs < dueMs
    Delay(dueMs - nowMs)
  EndIf

  ;-- Process window events (close button etc.) -----------------------------------------
  event = WindowEvent()
  If event = #PB_Event_CloseWindow
    running = #False
  EndIf

Wend

;---- Cleanup ---------------------------------------------------------------------------------
MacAudioOut::Stop()
MacAudioOut::Shutdown()
plm_destroy(mpeg)
FreeMemory(*pixels)

; IDE Options = PureBasic 6.12 LTS - C Backend (MacOS X - arm64)
; CursorPosition = 1
; EnableThread
; EnableXP
; DPIAware
