# Murmur, Status and Roadmap

The full change history lives in git. This file is the current state and what's next.

## Shipped

The four core capabilities and the polish around them are done and released:

- **Crash-safe recording** with journal + recovery on launch.
- **Push-to-talk dictation**: configurable hotkey, four interaction modes
  (hold / tap-toggle / hybrid / hold-with-latch), text injected at the cursor, clipboard
  preserved. Holding the trigger as part of a key combo (e.g. Fn+Delete) cancels instead
  of dictating. Return / Command-Delete to finish a hands-free dictation.
- **Meeting capture**: mic + system audio as two tracks, speaker diarization, interleaved
  chronological transcript, source-app labelling.
- **File import**: drag-and-drop or pick an audio file (linked, not copied).
- **Transcription**: Parakeet TDT v3 on the Neural Engine via FluidAudio, Silero VAD
  segmentation, filler-word removal, optional AI summary + stutter cleanup (Apple
  Foundation Models, macOS 26).
- **History window**: searchable, day-grouped, read-only detail; soft delete with a
  30-day Recently Deleted, plus auto-delete retention.
- **Quality of life**: mute background audio while dictating (leaves browser/call apps
  alone), auto-copy to clipboard, sound effects, menu-bar/Dock visibility modes, launch
  at login, window zoom, brand palette + icon.
- **Automatic updates** via Sparkle (background, silent), plus a Check for Updates item.
- **Data-safety hardening**: an engine failure can no longer delete a meeting's audio
  (marked failed + retryable, and UI retries use the two-track path); a failed
  dictation keeps its audio as a retryable History entry; sustained write failures
  (disk full) surface a HUD warning; the journal survives read failures at launch;
  quitting mid-dictation restores the ducked volume.
- **Lighter when idle**: speech/diarization models unload after ~10 min unused
  (setting, default on) and reload from the CoreML cache in seconds; chord hotkeys
  register through Carbon instead of an active event tap, so idle Murmur does zero
  per-keystroke work (and the meeting hotkey no longer needs Accessibility).
- **Live dictation preview** (setting, default off): the trailing seconds are
  re-transcribed on a short cadence and shown in the HUD while you speak.

## Known issues

- **Meeting system-audio track records silence (other side missing).** A meeting captures
  the mic fine ("You:") but the system-audio track comes through as pure digital silence,
  so the other side never appears in the transcript. Observed with the **System Audio
  Recording permission granted**, so it is *not* (only) a permissions problem — the initial
  permission theory was wrong. Root cause unknown; suspects: the Core Audio process-tap /
  aggregate-device setup in `SystemAudioTap` (e.g. tapping the wrong output device, an
  aggregate-device misconfig, or a macOS-version behaviour change). `SystemAudioRecorder`
  now tracks whether any non-silent audio arrived (`capturedAudio`) and the app shows a
  one-time heads-up when a meeting's system track was silent, but this only surfaces the
  problem — it does not fix it. **TODO: investigate why the tap yields silence.**

- **Dictation captures no usable audio while another app is using the microphone.**
  Repro: join a Google Meet call in Safari (its mic is active — macOS shows the orange
  mic-in-use indicator), then start a dictation. The HUD appears and the recording runs,
  but the level meter stays flat and no text is produced. **TODO: make dictation capture
  usable mic audio in this situation.** Measured facts (from a since-removed temporary
  instrumentation pass, all on the built-in "MacBook Air Microphone"):
  - Normal dictation (no other app using the mic): input format `48000 Hz, 1 channel`;
    ~116021 frames captured over ~7 s; transcription works.
  - Dictation during the call: CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`
    returned `true`; input format was `48000 Hz, **3 channels**`; frames were still
    captured (e.g. 95755, 40526), so buffers do arrive — it is not a zero-callback case.
  - In that 3-channel call state, the peak amplitude on **every** input channel was at the
    noise floor (measured `0.009, 0.009, 0.006`), i.e. all channels were effectively
    silent — the voice was not present on any channel Murmur received.
  - Observed when `setVoiceProcessingEnabled(true)` was enabled on Murmur's dictation input
    during the call: the audio device audibly reconfigured (the call's mic indicator briefly
    dropped and restarted) and the capture was still silent.
  - Next experiment: capture via `AVCaptureSession` + `AVCaptureAudioDataOutput`
    (designed for shared mic access) when the device is already running somewhere.

## Roadmap / ideas

- **Onboarding flow**: first-run walkthrough that requests each permission with rationale
  and lets the user choose where recordings are stored. For when others install it.
- **Model switcher** (Fast / Accurate) once a second engine is added.
- **URL import** (YouTube etc. via yt-dlp) and audio extraction from video containers.
- **Manual language override** for the rare case where one utterance mixes languages
  (auto-detect can misfire; per-language audio is accurate).
- **Terminal typing fallback**: CGEvent Unicode typing for apps where paste is unreliable.
- **Smarter titles/summaries**: optional LLM-generated titles/tags; backfill summaries
  for old recordings.

## Model-swap candidates (behind `TranscriptionEngine`)

- Parakeet TDT v3 / FluidAudio (current default; de/en/nl + 22 more, ANE, low RAM).
- whisper.cpp large-v3-turbo (Metal/Core ML), for the ~75 non-European languages.
- Apple SpeechAnalyzer (macOS 26), fastest and zero bundle size, if quality proves out.
