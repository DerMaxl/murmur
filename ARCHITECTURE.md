# Murmur, Architecture

A lean, native-Swift, menu-bar macOS app for private speech-to-text. Requires
macOS 15+ on Apple Silicon; the optional on-device AI summary and stutter cleanup
use Apple Foundation Models, which need macOS 26 (they're skipped on 15). Three
capabilities, one shared core:

1. **Crash-safe long recording**, audio streams to disk continuously, so a crash
   never loses more than the last fraction of a second.
2. **Push-to-talk dictation**, global hotkey → speak → text injected at the cursor
   in any app.
3. **Meeting capture**, mic + system/Safari audio as two separate clean tracks.
4. **File import**, drop in a file (or URL) and transcribe.

## Design principles

- **Lean.** No Tauri/Electron/React, no Rust. Pure Swift + AppKit + AVFoundation.
- **Maintainable & swappable.** The speech model sits behind one protocol
  (`TranscriptionEngine`). Switching from Parakeet to whisper.cpp or Apple's
  SpeechAnalyzer is a config change, not a rewrite.
- **Crash-safety by construction.** Recordings are written to disk as they happen,
  tracked in a journal. On launch we recover any recording that was in progress.
- **Private by default.** All audio and transcription stay on-device. The only
  optional network is the one-time model download.

## Module map

```
Sources/Murmur/
  App/            NSApplication bootstrap, menu-bar UI, app coordinator
  Recording/      Crash-safe recorder + journal/recovery + Markdown export
  Transcription/  TranscriptionEngine protocol + Parakeet/FluidAudio impl
  Dictation/      Global hotkey, text injection, push-to-talk controller
  UI/             Floating recording HUD (level meter + timer)
  Support/        Paths, logging, title heuristic, small shared helpers
```

## Speech engine

- **Default:** NVIDIA Parakeet TDT v3 (0.6B) via [FluidAudio](https://github.com/FluidInference/FluidAudio),
  running on the Apple Neural Engine. Covers German, English, Dutch (and 22 other
  European languages) with automatic language detection, one model for all three
  target languages.
- **Audio contract:** the engine consumes 16 kHz mono Float32 PCM. The recorder
  always writes that format, so recording and transcription share one pipeline.
- **Swapping models:** implement `TranscriptionEngine` and point the coordinator at
  the new type. Candidates documented in PLAN.md.

## Crash-safe recording

- Capture mic via `AVAudioEngine`, downsample to 16 kHz mono Float32 with
  `AVAudioConverter`, and append each buffer to an `AVAudioFile` (CAF container).
- CAF stays readable mid-write (its header doesn't depend on a final size field the
  way canonical WAV does), so an interrupted recording is recoverable as-is.
- A small JSON **journal** (`journal.json`) records every recording as `{id, folder,
  startedAt, status, source, transcription, title}`. Clean stop → `status: finished`.
  On launch, any `recording` entry is an orphan from a crash; we finalize and surface
  it, and any unfinished transcription is retried.

## On-disk layout (human- and agent-readable)

Each recording is a self-contained folder, so an agent (or you) can find and read
everything about it without joining across files:

```
Recordings/
  index.yaml                            manifest (YAML list), newest first
  2026-05-31T1432-0f9c/
      audio.caf                         16 kHz mono audio
      transcript.md                     YAML frontmatter + transcript body
```

- `transcript.md` frontmatter: `id, title, summary, created, duration_seconds, source,
  words, audio`. Body is the transcript. Memos get a plain body; meetings/imports will
  add a timestamped (later speaker-labelled) `## Segments` section.
- Titles are derived offline from the first words of the transcript. Summaries are an
  optional one-liner from Apple's on-device model (macOS 26).
- `index.yaml` is a human-readable + agent-parseable aggregate (chosen over a Markdown
  table since the whole index is regenerated on each change).
- `journal.json` is the app's fast internal state; `transcript.md` + `index.yaml` are
  derived exports, so there's a single source of truth. The store migrates the old
  flat layout into this folder layout on first launch.

## Permissions (TCC)

- **Microphone**, recording. (`NSMicrophoneUsageDescription`)
- **Accessibility + Input Monitoring**, global hotkey + text injection (dictation).
- **Screen Recording** / `NSAudioCaptureUsageDescription`, system-audio capture
  (meetings). Requested just-in-time, only when those features are first used.

Grants are tied to the app's code signature. We sign with a *stable self-signed
identity* (see `scripts/`) so grants survive rebuilds. The app is **not sandboxed**
(a sandbox blocks sending paste events to other apps) and distributed only to this
machine, no notarization needed.
