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
  chronological transcript, source-app labelling. Optional own-side speaker labelling
  (Settings, off by default) diarizes the mic track too, so two people sharing one Mac's
  mic are split into "You" (most talkative) + "Local"/"Local 2"/… instead of both "You".
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
- **Live dictation transcription**: finished speech segments are transcribed in the
  background *while you speak* (Parakeet; the work is consumed by the final pass, so
  long memos finish near-instantly). The HUD preview (setting, default off) only
  controls whether the words are shown as they land.

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

## To investigate

- **Meeting transcripts get progressively more garbled the longer the recording.**
  Reported by a user on a long meeting; words are phonetically mangled (both the mic
  "You" track and the system track), and it worsens deeper in. Dictation (same mic →
  16 kHz → Parakeet path, but short and mic-only) stays clean, so the pipeline itself
  is sound — the differentiators are **length** and the **simultaneous system-audio
  tap**. Leading suspects, in order: (1) progressive buffer/sample **drops** while the
  mic engine and the aggregate-device tap both run for a long time on a loaded/slower
  Mac — we concatenate whatever arrives with no gap detection, so drops splice
  non-adjacent audio and garble words; (2) **clock drift** between the mic's input
  device and the tap's output device (two crystals, aligned only by a fixed offset at
  start, no drift compensation) — explains worsening turn *misordering* but not
  within-word garbling; (3) VAD 14 s hard-cap force-cutting continuous speech
  (secondary, boundary-only). **Next step when revisiting:** add instrumentation at
  meeting stop — recorded-duration vs wall-clock per track (detects drops), mic-vs-
  system duration delta (detects drift), and VAD segment count + max chunk length —
  then have an affected user reproduce so the numbers say which it is before fixing.

## Roadmap / ideas

- **Adaptive layout for narrow / half-screen windows.** The History tab is three
  fixed columns (sidebar 232 + list 340 + a flexible detail), so a half-screen window
  leaves the detail pane only ~150pt: barely enough to read a transcript, and the title
  and metadata get cramped. Hit regularly in practice (the app is often used at
  half-screen). Mitigations already shipped, the metadata chips flow onto a second row
  instead of squishing into ovals, and the reading column is width-capped, but those
  don't make a half-screen window genuinely usable. The real fix is to collapse to a
  single navigable column on narrow widths (the way Mail, or an automatic
  NavigationSplitView, does), so a half-screen window shows one useful pane at a time.
  The layout is a plain HStack today specifically to avoid NavigationSplitView's
  draggable-divider bug (the sidebar could be dragged off the left of the screen), so an
  adaptive version has to keep that property: no user-draggable or hideable divider on a
  wide window, auto-collapse only when the window is genuinely narrow.

- **Custom vocabulary**: a user-editable replacement table (wrong → right: product
  names, jargon, names the model habitually misspells) applied word-boundary,
  case-aware in `TextCleaner` after every transcription, stored as a human-editable
  file under Application Support with a small editor in Settings. Parakeet can't be
  biased at inference time, so post-processing is the right seam. (A model-level
  alternative — FluidAudio's CTC keyword-boosting / CTC-spotter — is still in
  development in FluidAudio and not production-ready in Swift, so the post-processing
  table is the path that works today and is engine-independent.)
- **Onboarding flow**: first-run walkthrough that requests each permission with rationale
  and lets the user choose where recordings are stored. For when others install it.
- **URL import** (YouTube etc. via yt-dlp) and audio extraction from video containers.
- **Manual language override** for the rare case where one utterance mixes languages
  (auto-detect can misfire; per-language audio is accurate).
- **Terminal typing fallback**: CGEvent Unicode typing for apps where paste is unreliable.
- **Smarter titles/summaries**: optional LLM-generated titles/tags; backfill summaries
  for old recordings.

## Model-swap candidates (behind `TranscriptionEngine`)

- Apple SpeechAnalyzer (macOS 26): **shipped**; the default for fresh installs on
  macOS 26+ (OS-managed model, zero download; single fixed locale).
- Parakeet TDT v3 / FluidAudio: **shipped**; the multilingual step-up engine, and
  the default on macOS 15 and for installs predating the picker.
- whisper.cpp large-v3-turbo (Metal/Core ML), for the ~75 non-European languages.
- Evaluated and **declined for now** (Jul 2026): NVIDIA Canary-1B-v2 (live on HF, but
  same 25 European languages as Parakeet, heavier encoder-decoder, no inherent custom
  vocab), Qwen3-ASR (more languages — not wanted), streaming Parakeet (streaming — not
  a current need). No compelling engine to add given Apple + Parakeet already cover the
  need; revisit if FluidAudio's Canary/CTC custom-vocab lands or non-European languages
  become a requirement.
