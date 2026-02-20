; macOS AudioUnit output module (vanilla PureBasic)
; Realtime output with user render callback, transport controls, and safe lifecycle.
; by foodsnacker – license: MIT
EnableExplicit
CompilerIf #PB_Compiler_OS <> #PB_OS_MacOS
  CompilerError "This module is macOS-only."
CompilerEndIf

DeclareModule MacAudioOut
  Prototype RenderBlockCallback(*left.Float, *right.Float, frames.i, sampleRate.i, userData.i)
  Declare.i Init(sampleRate.i = 48000)
  Declare Shutdown()
  Declare.i Play()
  Declare Stop()
  Declare.i IsPlaying()
  Declare SetVolume(volume.f)
  Declare.f GetVolume()
  Declare SetRenderCallback(*proc.RenderBlockCallback, userData.i = 0)
  Declare ClearRenderCallback()
  Declare SetDefaultFrequency(hz.f)
  Declare.l LastStatus()
EndDeclareModule

Module MacAudioOut
  EnableExplicit

  #kTwoPi = 6.283185307179586

  ; FourCC constants
  #kAudioUnitType_Output          = $61756F75           ; 'auou'
  #kAudioUnitSubType_DefaultOutput = $64656620          ; 'def '
  #kAudioUnitManufacturer_Apple   = $6170706C           ; 'appl'
  #kAudioFormatLinearPCM          = $6C70636D           ; 'lpcm'

  ; Audio format flags
  #kAudioFormatFlagIsFloat        = $00000001
  #kAudioFormatFlagIsPacked       = $00000008
  #kAudioFormatFlagIsNonInterleaved = $00000020
  #kLinearPCMFlags = #kAudioFormatFlagIsFloat | #kAudioFormatFlagIsPacked | #kAudioFormatFlagIsNonInterleaved

  ; AudioUnit properties/scopes
  #kAudioUnitProperty_StreamFormat     = 8
  #kAudioUnitProperty_SetRenderCallback = 23
  #kAudioUnitScope_Input               = 1
  #kAudioUnitRenderAction_OutputIsSilence = (1 << 4)

  ; AudioBufferList layout (macOS 64-bit)
  #ABL_NUMBUFFERS_OFF   = 0
  #ABL_FIRSTBUFFER_OFF  = 8
  #AUDIOBUFFER_SIZE     = 16
  #ABUF_CHANNELS_OFF    = 0
  #ABUF_DATABYTESIZE_OFF = 4
  #ABUF_DATA_OFF        = 8

  Structure AudioComponentDescription
    componentType.l
    componentSubType.l
    componentManufacturer.l
    componentFlags.l
    componentFlagsMask.l
  EndStructure

  Structure AudioStreamBasicDescription
    mSampleRate.d
    mFormatID.l
    mFormatFlags.l
    mBytesPerPacket.l
    mFramesPerPacket.l
    mBytesPerFrame.l
    mChannelsPerFrame.l
    mBitsPerChannel.l
    mReserved.l
  EndStructure

  Structure AURenderCallbackStruct
    inputProc.i
    inputProcRefCon.i
  EndStructure

  Structure State
    unit.i
    mutex.i
    sampleRate.i
    isPlaying.i
    volume.f
    defaultFreq.f
    phase.d
    lastStatus.l
    renderProc.RenderBlockCallback
    renderUserData.i
    snapRenderProc.RenderBlockCallback
    snapRenderUserData.i
    snapVolume.f
    snapDefaultFreq.f
    tempFrames.i
    *tempLeft.Float
    *tempRight.Float
  EndStructure

  Global g.State

  ImportC "-framework AudioToolbox"
    AudioComponentFindNext(inComponent.i, inDesc.i)
    AudioComponentInstanceNew(inComponent.i, outInstance.i)  ; OSStatus
    AudioComponentInstanceDispose(inInstance.i)              ; OSStatus
    AudioUnitSetProperty(inUnit.i, inID.l, inScope.l, inElement.l, inData.i, inDataSize.l) ; OSStatus
    AudioUnitInitialize(inUnit.i)                            ; OSStatus
    AudioUnitUninitialize(inUnit.i)                          ; OSStatus
    AudioOutputUnitStart(ci.i)                               ; OSStatus
    AudioOutputUnitStop(ci.i)                                ; OSStatus
  EndImport

  Procedure.f ClampVolume(value.f)
    If value < 0.0 : ProcedureReturn 0.0 : EndIf
    If value > 2.0 : ProcedureReturn 2.0 : EndIf
    ProcedureReturn value
  EndProcedure

  Procedure FillDefaultSine(*left.Float, *right.Float, frames.i, freq.f)
    Protected i.i, s.f
    Protected phaseStep.d = freq / g\sampleRate
    For i = 0 To frames - 1
      s = Sin(#kTwoPi * g\phase)
      g\phase + phaseStep
      If g\phase >= 1.0 : g\phase - 1.0 : EndIf
      *left\f  = s
      *right\f = s
      *left  + SizeOf(Float)
      *right + SizeOf(Float)
    Next
  EndProcedure

  Procedure ApplyVolume(*left.Float, *right.Float, frames.i, v.f)
    Protected i.i
    If v = 1.0 : ProcedureReturn : EndIf
    For i = 0 To frames - 1
      *left\f  * v
      *right\f * v
      *left  + SizeOf(Float)
      *right + SizeOf(Float)
    Next
  EndProcedure

  Procedure FillInterleavedFromLR(*dst.Float, channels.i, *left.Float, *right.Float, frames.i)
    Protected i.i, ch.i, l.f, r.f
    If channels <= 0 : ProcedureReturn : EndIf
    For i = 0 To frames - 1
      l = *left\f  : *left  + SizeOf(Float)
      r = *right\f : *right + SizeOf(Float)
      If channels >= 1 : PokeF(*dst + ((i * channels + 0) * SizeOf(Float)), l) : EndIf
      If channels >= 2 : PokeF(*dst + ((i * channels + 1) * SizeOf(Float)), r) : EndIf
      For ch = 2 To channels - 1
        PokeF(*dst + ((i * channels + ch) * SizeOf(Float)), 0.0)
      Next
    Next
  EndProcedure

  Procedure CleanupPartialInit()
    If g\unit
      AudioComponentInstanceDispose(g\unit)
      g\unit = 0
    EndIf
    g\isPlaying = #False
  EndProcedure

  Procedure FreeTempBuffers()
    If g\tempLeft  : FreeMemory(g\tempLeft)  : g\tempLeft  = 0 : EndIf
    If g\tempRight : FreeMemory(g\tempRight) : g\tempRight = 0 : EndIf
    g\tempFrames = 0
  EndProcedure

  ProcedureC.l RenderCallback(inRefCon.i, ioActionFlags.i, inTimeStamp.i, inBusNumber.l, inNumberFrames.l, ioData.i)
    Protected numBuffers.l
    Protected *buf0, *buf1, *bufN
    Protected *left.Float, *right.Float, *dataN.Float
    Protected channels0.l, channels1.l, channelsN.l
    Protected bi.i, ch.i, i.i
    Protected renderProc.RenderBlockCallback
    Protected renderUserData.i
    Protected volume.f, defaultFreq.f, s.f

    If ioData = 0 : ProcedureReturn 0 : EndIf

    ; Lock-free snapshots for audio thread hot path
    renderProc      = g\snapRenderProc
    renderUserData  = g\snapRenderUserData
    volume          = g\snapVolume
    defaultFreq     = g\snapDefaultFreq

    numBuffers = PeekL(ioData + #ABL_NUMBUFFERS_OFF)
    If numBuffers <= 0 : ProcedureReturn 0 : EndIf

    *buf0     = ioData + #ABL_FIRSTBUFFER_OFF
    channels0 = PeekL(*buf0 + #ABUF_CHANNELS_OFF)
    *left     = PeekI(*buf0 + #ABUF_DATA_OFF)
    If *left = 0 Or channels0 <= 0 : ProcedureReturn 0 : EndIf

    ; Preferred path: stereo non-interleaved (2 mono buffers)
    If numBuffers >= 2
      *buf1     = *buf0 + #AUDIOBUFFER_SIZE
      channels1 = PeekL(*buf1 + #ABUF_CHANNELS_OFF)
      *right    = PeekI(*buf1 + #ABUF_DATA_OFF)
      If *right = 0 Or channels1 <= 0 : ProcedureReturn 0 : EndIf

      If channels0 = 1 And channels1 = 1
        If renderProc
          renderProc(*left, *right, inNumberFrames, g\sampleRate, renderUserData)
        Else
          FillDefaultSine(*left, *right, inNumberFrames, defaultFreq)
        EndIf
        ApplyVolume(*left, *right, inNumberFrames, volume)
      Else
        If inNumberFrames <= g\tempFrames And g\tempLeft And g\tempRight
          If renderProc
            renderProc(g\tempLeft, g\tempRight, inNumberFrames, g\sampleRate, renderUserData)
          Else
            FillDefaultSine(g\tempLeft, g\tempRight, inNumberFrames, defaultFreq)
          EndIf
          ApplyVolume(g\tempLeft, g\tempRight, inNumberFrames, volume)
          For i = 0 To inNumberFrames - 1
            For ch = 0 To channels0 - 1
              If ch = 0
                PokeF(*left + ((i * channels0 + ch) * SizeOf(Float)), PeekF(g\tempLeft + i * SizeOf(Float)))
              Else
                PokeF(*left + ((i * channels0 + ch) * SizeOf(Float)), 0.0)
              EndIf
            Next
            For ch = 0 To channels1 - 1
              If ch = 0
                PokeF(*right + ((i * channels1 + ch) * SizeOf(Float)), PeekF(g\tempRight + i * SizeOf(Float)))
              Else
                PokeF(*right + ((i * channels1 + ch) * SizeOf(Float)), 0.0)
              EndIf
            Next
          Next
        Else
          For i = 0 To inNumberFrames - 1
            s = Sin(#kTwoPi * g\phase) * volume
            g\phase + (defaultFreq / g\sampleRate)
            If g\phase >= 1.0 : g\phase - 1.0 : EndIf
            For ch = 0 To channels0 - 1 : PokeF(*left  + ((i * channels0 + ch) * SizeOf(Float)), s) : Next
            For ch = 0 To channels1 - 1 : PokeF(*right + ((i * channels1 + ch) * SizeOf(Float)), s) : Next
          Next
        EndIf
      EndIf
      PokeL(*buf0 + #ABUF_DATABYTESIZE_OFF, inNumberFrames * channels0 * SizeOf(Float))
      PokeL(*buf1 + #ABUF_DATABYTESIZE_OFF, inNumberFrames * channels1 * SizeOf(Float))
    Else
      ; Interleaved single-buffer fallback
      If channels0 >= 2 And inNumberFrames <= g\tempFrames And g\tempLeft And g\tempRight
        If renderProc
          renderProc(g\tempLeft, g\tempRight, inNumberFrames, g\sampleRate, renderUserData)
        Else
          FillDefaultSine(g\tempLeft, g\tempRight, inNumberFrames, defaultFreq)
        EndIf
        ApplyVolume(g\tempLeft, g\tempRight, inNumberFrames, volume)
        FillInterleavedFromLR(*left, channels0, g\tempLeft, g\tempRight, inNumberFrames)
      Else
        For i = 0 To inNumberFrames - 1
          s = Sin(#kTwoPi * g\phase) * volume
          g\phase + (defaultFreq / g\sampleRate)
          If g\phase >= 1.0 : g\phase - 1.0 : EndIf
          For ch = 0 To channels0 - 1
            PokeF(*left + ((i * channels0 + ch) * SizeOf(Float)), s)
          Next
        Next
      EndIf
      PokeL(*buf0 + #ABUF_DATABYTESIZE_OFF, inNumberFrames * channels0 * SizeOf(Float))
    EndIf

    ; Zero extra buffers if present
    If numBuffers > 2
      For bi = 2 To numBuffers - 1
        *bufN    = ioData + #ABL_FIRSTBUFFER_OFF + bi * #AUDIOBUFFER_SIZE
        channelsN = PeekL(*bufN + #ABUF_CHANNELS_OFF)
        *dataN   = PeekI(*bufN + #ABUF_DATA_OFF)
        If *dataN And channelsN > 0
          FillMemory(*dataN, inNumberFrames * channelsN * SizeOf(Float), 0)
          PokeL(*bufN + #ABUF_DATABYTESIZE_OFF, inNumberFrames * channelsN * SizeOf(Float))
        EndIf
      Next
    EndIf

    ; Clear silence hint – we produced audio
    If ioActionFlags
      PokeL(ioActionFlags, PeekL(ioActionFlags) & (~#kAudioUnitRenderAction_OutputIsSilence))
    EndIf
    ProcedureReturn 0
  EndProcedure

  Procedure.i Init(sampleRate.i = 48000)
    Protected desc.AudioComponentDescription
    Protected comp.i
    Protected cb.AURenderCallbackStruct
    Protected fmt.AudioStreamBasicDescription

    If sampleRate <= 0 : sampleRate = 48000 : EndIf
    If g\mutex = 0
      g\mutex = CreateMutex()
      If g\mutex = 0 : g\lastStatus = -2 : ProcedureReturn #False : EndIf
    EndIf
    LockMutex(g\mutex)
    If g\unit : UnlockMutex(g\mutex) : ProcedureReturn #True : EndIf

    g\sampleRate      = sampleRate
    g\volume          = 1.0
    g\defaultFreq     = 220.0
    g\snapVolume      = g\volume
    g\snapDefaultFreq = g\defaultFreq
    g\snapRenderProc  = 0
    g\snapRenderUserData = 0
    g\phase           = 0.0
    g\isPlaying       = #False
    g\lastStatus      = 0
    g\tempFrames      = 8192
    g\tempLeft  = AllocateMemory(g\tempFrames * SizeOf(Float))
    g\tempRight = AllocateMemory(g\tempFrames * SizeOf(Float))
    If g\tempLeft = 0 Or g\tempRight = 0 : FreeTempBuffers() : EndIf

    desc\componentType         = #kAudioUnitType_Output
    desc\componentSubType      = #kAudioUnitSubType_DefaultOutput
    desc\componentManufacturer = #kAudioUnitManufacturer_Apple
    desc\componentFlags        = 0
    desc\componentFlagsMask    = 0

    comp = AudioComponentFindNext(0, @desc)
    If comp = 0 : g\lastStatus = -1 : UnlockMutex(g\mutex) : ProcedureReturn #False : EndIf

    g\lastStatus = AudioComponentInstanceNew(comp, @g\unit)
    If g\lastStatus <> 0 Or g\unit = 0 : g\unit = 0 : UnlockMutex(g\mutex) : ProcedureReturn #False : EndIf

    cb\inputProc       = @RenderCallback()
    cb\inputProcRefCon = @g

    fmt\mSampleRate       = g\sampleRate
    fmt\mFormatID         = #kAudioFormatLinearPCM
    fmt\mFormatFlags      = #kLinearPCMFlags
    fmt\mBytesPerPacket   = SizeOf(Float)
    fmt\mFramesPerPacket  = 1
    fmt\mBytesPerFrame    = SizeOf(Float)
    fmt\mChannelsPerFrame = 2
    fmt\mBitsPerChannel   = 32
    fmt\mReserved         = 0

    g\lastStatus = AudioUnitSetProperty(g\unit, #kAudioUnitProperty_StreamFormat, #kAudioUnitScope_Input, 0, @fmt, SizeOf(AudioStreamBasicDescription))
    If g\lastStatus <> 0 : Goto InitFail : EndIf

    g\lastStatus = AudioUnitSetProperty(g\unit, #kAudioUnitProperty_SetRenderCallback, #kAudioUnitScope_Input, 0, @cb, SizeOf(AURenderCallbackStruct))
    If g\lastStatus <> 0 : Goto InitFail : EndIf

    g\lastStatus = AudioUnitInitialize(g\unit)
    If g\lastStatus <> 0 : Goto InitFail : EndIf

    UnlockMutex(g\mutex)
    ProcedureReturn #True

    InitFail:
    CleanupPartialInit()
    UnlockMutex(g\mutex)
    ProcedureReturn #False
  EndProcedure

  Procedure.i Play()
    Protected unit.i, sr.i, status.l
    If g\mutex : LockMutex(g\mutex) : EndIf
    unit = g\unit : sr = g\sampleRate
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    If unit = 0
      If Init(sr) = #False : ProcedureReturn #False : EndIf
    EndIf
    If g\mutex : LockMutex(g\mutex) : EndIf
    If g\isPlaying : If g\mutex : UnlockMutex(g\mutex) : EndIf : ProcedureReturn #True : EndIf
    unit = g\unit
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    If unit = 0 : ProcedureReturn #False : EndIf
    status = AudioOutputUnitStart(unit)
    If g\mutex : LockMutex(g\mutex) : EndIf
    g\lastStatus = status
    If status = 0 : g\isPlaying = #True : EndIf
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    ProcedureReturn Bool(status = 0)
  EndProcedure

  Procedure Stop()
    Protected unit.i, doStop.i, status.l
    If g\mutex : LockMutex(g\mutex) : EndIf
    unit = g\unit : doStop = g\isPlaying
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    If unit = 0 Or doStop = 0 : ProcedureReturn : EndIf
    status = AudioOutputUnitStop(unit)
    If g\mutex : LockMutex(g\mutex) : EndIf
    g\lastStatus = status
    If status = 0 : g\isPlaying = #False : EndIf
    If g\mutex : UnlockMutex(g\mutex) : EndIf
  EndProcedure

  Procedure.i IsPlaying()
    Protected v.i
    If g\mutex : LockMutex(g\mutex) : EndIf
    v = g\isPlaying
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    ProcedureReturn v
  EndProcedure

  Procedure Shutdown()
    Protected unit.i, status.l
    Stop()
    If g\mutex : LockMutex(g\mutex) : EndIf
    If g\isPlaying : If g\mutex : UnlockMutex(g\mutex) : EndIf : ProcedureReturn : EndIf
    unit = g\unit : g\unit = 0 : g\isPlaying = #False
    g\renderProc = 0 : g\renderUserData = 0
    FreeTempBuffers()
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    If unit
      status = AudioUnitUninitialize(unit)
      If status = 0
        status = AudioComponentInstanceDispose(unit)
      Else
        AudioComponentInstanceDispose(unit)
      EndIf
      If g\mutex : LockMutex(g\mutex) : EndIf
      g\lastStatus = status
      If g\mutex : UnlockMutex(g\mutex) : EndIf
    EndIf
  EndProcedure

  Procedure SetVolume(volume.f)
    If g\mutex : LockMutex(g\mutex) : EndIf
    g\volume = ClampVolume(volume) : g\snapVolume = g\volume
    If g\mutex : UnlockMutex(g\mutex) : EndIf
  EndProcedure

  Procedure.f GetVolume()
    Protected v.f
    If g\mutex : LockMutex(g\mutex) : EndIf
    v = g\volume
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    ProcedureReturn v
  EndProcedure

  Procedure SetRenderCallback(*proc.RenderBlockCallback, userData.i = 0)
    If g\mutex : LockMutex(g\mutex) : EndIf
    g\renderProc = *proc : g\renderUserData = userData
    g\snapRenderProc = *proc : g\snapRenderUserData = userData
    If g\mutex : UnlockMutex(g\mutex) : EndIf
  EndProcedure

  Procedure ClearRenderCallback()
    If g\mutex : LockMutex(g\mutex) : EndIf
    g\renderProc = 0 : g\renderUserData = 0
    g\snapRenderProc = 0 : g\snapRenderUserData = 0
    If g\mutex : UnlockMutex(g\mutex) : EndIf
  EndProcedure

  Procedure SetDefaultFrequency(hz.f)
    If hz < 10.0 : hz = 10.0 : EndIf
    If hz > 20000.0 : hz = 20000.0 : EndIf
    If g\mutex : LockMutex(g\mutex) : EndIf
    g\defaultFreq = hz : g\snapDefaultFreq = hz
    If g\mutex : UnlockMutex(g\mutex) : EndIf
  EndProcedure

  Procedure.l LastStatus()
    Protected s.l
    If g\mutex : LockMutex(g\mutex) : EndIf
    s = g\lastStatus
    If g\mutex : UnlockMutex(g\mutex) : EndIf
    ProcedureReturn s
  EndProcedure

EndModule
; IDE Options = PureBasic 6.12 LTS - C Backend (MacOS X - arm64)
; EnableThread
