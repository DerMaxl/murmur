# Murmur, Build Plan

Milestones in priority order. Each is independently useful and shippable.

## M1, Crash-safe recorder (IN PROGRESS)
- [x] Project scaffold, build script, stable self-signed identity
- [x] Menu-bar shell (start/stop, open recordings folder, quit)
- [x] `CrashSafeRecorder`: mic → 16 kHz mono Float32 → streamed CAF
- [x] `RecordingStore`: JSON journal + orphan recovery on launch
- [ ] Smoke test: record, confirm file grows on disk, kill -9 mid-record, relaunch,
      confirm the partial recording is recovered and playable
- [ ] Microphone permission flow (just-in-time prompt + guidance if denied)

## M2, Transcription engine (IN PROGRESS)
- [x] `TranscriptionEngine` protocol
- [x] FluidAudio dependency (0.14.7) + Parakeet TDT v3 `ParakeetEngine`
- [x] Auto-transcribe on stop → `.txt` sidecar + journal fields
- [x] Recent-recordings menu with status, copy transcript, reveal, delete
- [x] Verify de/en/nl quality (perfect per-language on real samples, conf 0.97-0.99)
- [x] Silero VAD segmentation + per-segment transcription (bounds memory, trims
      silence, ≤14 s chunks) with progressive .txt autosave per segment
- [x] Auto-retry pending/failed transcriptions on launch (crash self-heals)
- [x] Agent-readable storage: folder-per-recording, `transcript.md` (YAML
      frontmatter + body), `INDEX.md` manifest, offline heuristic titles, migration
      from the old flat layout
- [x] Live recording HUD: animated mic-level bars + elapsed timer (memo + dictation)
- [x] On-device AI summary via Apple Foundation Models (macOS 26, fully local);
      stored in frontmatter + INDEX + menu preview. Best-effort, no-ops if Apple
      Intelligence is off. No backfill for pre-existing recordings yet.
- [x] Persist push-to-talk on/off across relaunches (UserDefaults + silent restore)
- [ ] Simple history/transcript window (currently menu submenu + INDEX.md)
- [ ] Optional: LLM-generated titles/tags; backfill summaries for old recordings
- [ ] Optional manual language override (auto-detect can misfire when ONE utterance
      mixes languages; per-language audio is accurate). Low priority.

## M3, Push-to-talk dictation (DONE)
- [x] CGEventTap global hotkey (`HotkeyMonitor`, default: hold Right Option)
- [x] Hold-to-talk state machine → record → transcribe → inject (`DictationController`)
- [x] Text injection: pasteboard + synthesized Cmd-V with clipboard restore (`TextInjector`)
- [x] Accessibility permission flow + menu toggle; mutual-exclusion with voice memos
- [x] Persist on/off across relaunches; dictations saved text-only (no audio) to history
- [x] Configurable trigger key (default Fn / Globe; Right Option also supported)
- [x] Four selectable interaction modes (hold-to-talk, tap-toggle, hybrid, hold+latch)
      via menu submenu; default hold-to-talk
- [ ] Optional: CGEvent Unicode-typing fallback for terminals

## Post-processing & settings
- [x] Filler-word removal (uh/um/äh/…, de/en/nl-safe) with menu toggle (default on)
- [x] Minimalistic settings/history UI — SwiftUI window (sidebar History|Settings),
      System-Settings-native grouped form, day-grouped searchable/filterable history with
      read-only detail (summary, metadata chips, copy/reveal/delete). Brand accent applied.
- [x] Dictation history records the target app (frontmost at inject time)
- [x] Silent meetings auto-discarded (no empty recording folder); empty dictations already skip
- [x] Self-heal: re-arm meeting Hyper+R chord on menu open (fixes "granted Accessibility
      after launch → hotkey dead until relaunch")
- [x] Brand palette codified (`UI/Brand.swift`): teal→indigo on near-black; matches the icon
- [x] **App icon** — teal→indigo sound-wave that forms an "M" (G3, tails up, design in
      `design/icon-options/genfinal.swift`). Built `Resources/AppIcon.icns`, wired into
      Info.plist (CFBundleIconFile/Name) + build.sh; macOS resolves it for the bundle.
- [x] **AI stutter cleanup** (`Polisher.swift`, Apple Foundation Models) — removes
      stutters/false-starts/self-corrections, keeps meaning+language; strips chatty
      preamble; falls back to raw text on guardrail errors (more common on non-English).
      `Settings.polishTranscripts` (default off, ~1-2s latency), applied to dictation
      (before inject) + non-meeting transcribe. Verified on en samples; nl can hit Apple's
      guardrail → graceful fallback.
- [x] **Custom hotkey recorder** — `Shortcut` (chord OR bare-modifier hold) + unified
      `GlobalHotkey` (replaces HotkeyMonitor + ChordHotkey) + SwiftUI `ShortcutField`
      (click-to-record NSView; captures key chords via keyDown/performKeyEquivalent and
      bare modifiers like Fn via flagsChanged; Esc cancels). Settings "Hotkeys" section with
      a recorder + ↺ reset for the dictation trigger and meeting toggle. Persisted as JSON in
      Settings (migrates old `dictationTrigger`). Chord matching ignores Fn (F-keys set it).
- [x] **Dock / Mission Control icon** — window open flips activation policy to `.regular`
      (Dock icon + Mission Control label), back to `.accessory` on close; app icon set
      explicitly via `NSApp.applicationIconImage`.
- [x] **Meeting hotkey default → ⌘E** (was Hyper+R). One-time migration
      `Settings.migrateDefaultsIfNeeded()` moves a stored Hyper+R default to ⌘E.
- [x] **Hyper key now usable** — moved the global tap from `.headInsertEventTap` to
      `.tailAppendEventTap` so we observe events *after* Hyperkey rewrites CapsLock→⌘⌥⌃⇧
      (head-insert saw the raw keystroke first, before the rewrite → never matched). User can
      now record Hyper+<key> in Settings → Hotkeys. ⌘E stays the default. NEEDS USER TEST.
- [x] Removed the storage breakdown bar (kept the size text) per user preference.
- [x] **Code cleanup pass** — removed dead code (coordinator `dictationShortcut`,
      `GlobalHotkey.shortcutValue`, `Brand.violet`, `Log.debug`, `AudioProcessProbe.bestSourceApp`,
      `MeetingRecorder.currentSourceApp`), made `StorageInfo.directorySize` private, fixed a
      stale HUD comment, consolidated brand colors (`Brand.tealNS/indigoNS`), and DRY'd the
      polish call via `Polisher.polishIfEnabled`.
- [x] **⌘=/-/0 window zoom** — scales the History + transcript reading content. macOS
      ignores `dynamicTypeSize` for this content, so we scale fonts ourselves: a `fontScale`
      env value (`FontScale.swift`) + `.scaledFont(size:)` on each Text, driven by the View
      menu (`MainMenu.swift`, `NSApp.mainMenu`). Zoom-in bound to ⌘= (no Shift). App + Edit
      menus added too (text fields get Copy/Paste/Undo/Select-All).
- [x] **Zoom scales cleanly as a whole** — not just text: History rows + transcript detail
      scale their spacing/padding/icon-frames/chips by `fontScale` too; Settings scales its
      text (scaled base font) and bumps `controlSize` (.large/.extraLarge) so toggles/pickers
      grow with it. Settings sections reordered (General at top: General, Dictation, Hotkeys,
      Transcription, Model, Storage, About).
- [x] **Menu-bar icon = wave-M** (`Resources/MenuBarIcon.png`, template glyph, red tint while
      recording) instead of the microphone SF Symbol.
- [x] **Meeting fixes**: HUD meter now shows YOUR mic (not whichever track was loudest);
      mic echo-cancellation via `setVoiceProcessingEnabled` (AEC, reduces speaker bleed);
      interleaved chronological transcript (You / app turns by time, coalesced) instead of two
      walls of text; source label now the set of apps that actually produced audio during the
      meeting (sampled every 3s), not the frontmost window; history row shows the app icon
      (speaker/arrow) to match the detail view.
- [x] **Brand color, minimal** — HUD level meter now teal→indigo gradient (matches icon);
      history/detail source icons use the brand gradient; storage bar in brand colors.
- [x] **Storage usage** in Settings — Recordings total + audio/transcripts split (visual bar +
      footer) and **Model size** (FluidAudio cache, ~975 MB). `StorageInfo.measure()`.
- [ ] **Onboarding flow** (future) — first-run walkthrough: request permissions (mic,
      Accessibility, screen/system-audio) one at a time with rationale, and let the user
      choose where recordings are stored. For when others download the app.
- [ ] Model switcher with friendly names (Fast/Accurate) — needs a 2nd model first

## M4, Meeting capture (mic + system audio, separate tracks) — IN PROGRESS
- [x] Core Audio process tap (`SystemAudioTap`) for system audio (macOS 14.4+)
- [x] Two crash-safe tracks: mic.caf + system.caf (`SystemAudioRecorder`, `MeetingRecorder`)
- [x] Per-track transcription → sectioned transcript ("## You" / "## <app>")
- [x] Source-app label (frontmost app at start) in metadata + meeting title
- [x] Menu item "Start / Stop meeting recording" + mutual exclusion with memo/dictation
- [x] Global chord hotkey Hyper+R (⌘⌥⌃⇧R) toggles meeting (`ChordHotkey`, consumes event;
      needs Accessibility — armed at launch / when dictation is enabled)
- [x] Identify the actually-audio-producing app (`AudioProcessProbe`, Core Audio
      process objects + isRunningOutput) with a deferred re-check; frontmost fallback
- [x] Speaker diarization on the system track (`Diarizer`, FluidAudio Pyannote);
      aligns diarized speakers with timestamped ASR segments → "**Speaker N:**" turns

## M5, File / URL import
- [x] Import audio files by LINKING to the original (source: imported, no copy);
      `transcript.md` carries `source_file:`. Driven by opening a file with the app
      (Open With / drag / `open -a`); no menu item (reserved for a future UI).
- [ ] Optional YouTube/URL via yt-dlp (needs the tool installed)
- [ ] Audio extraction for video containers (mp4/mov) if needed

## Decisions / removed
- Voice memo (mic-only recording) REMOVED at user request: dictation (saves text) +
  meeting (saves audio) cover their needs. `CrashSafeRecorder` stays (meeting mic +
  dictation use it). Old `.memo` recordings still display and re-transcribe.
- Dictation stays Fn-only (no menu start button, by choice).

## Model-swap candidates (kept behind `TranscriptionEngine`)
- Parakeet TDT v3 / FluidAudio (default, de/en/nl + 22 more, ANE, low RAM)
- whisper.cpp large-v3-turbo (Metal/Core ML), for the ~75 non-European languages
- Apple SpeechAnalyzer (macOS 26), fastest, zero bundle size, if quality proves out

## Session 2026-06-01 (night) - code-review fixes
- [x] **Stuck transcription after crash** - `RecordingStore.demoteRunningTranscriptions()`
      resets `.running` to `.none` at launch (before retry) so an interrupted transcription
      re-runs instead of hanging on "Transcribing...".
- [x] **Auto-copy/sound at launch** - `transcribe`/`transcribeMeeting` take `userInitiated`
      (default true); launch-retry and recovery pass false, so they no longer overwrite the
      clipboard or play the done-sound.
- [x] **AudioDucker device correctness** - stores the muted device id + its volume in instance
      state and restores that exact device; persists device UID for crash recovery; fallback uses
      the saved volume, not max.
- [x] **TextInjector preserves full clipboard** - snapshots all pasteboard items (every type) and
      rewrites them on restore, so images/files/RTF survive a dictation.
- [x] **Ghost orphans** - `recoverOrphans` checks the audio file first and permanently drops an
      audioless orphan instead of surfacing a broken row.
- [x] **sync() redraw storm** - `Recording: Equatable` + compare-then-assign each mirror (avoids
      the inout/`_modify` notification trap), so unchanged values don't re-render open windows.
- [x] **Bare-modifier hotkey** - Fn-hold uses subset matching (required modifiers present, extras
      allowed), so adding a modifier mid-hold no longer stops/restarts dictation.
- [x] **Event-tap `isDown` reset** on tap re-enable; **`makeFolder` logs** createDirectory failures.
- [x] **Meeting two-track alignment** - persist each track's start instant; `trackOffsets`/`shift`
      put both tracks on a shared t=0 before interleaving turns.
- [x] **Dashes** - removed em/en dashes from make-cert.sh, SettingsView, README. **build.sh** drops
      deprecated `--deep`. **ARCHITECTURE** min-OS reconciled to macOS 15+ (AI features need 26).
- Review points deliberately not actioned: `make-cert.sh -A` (review was wrong; without it codesign
  falls back to ad-hoc, documented in the script); `disable-library-validation` kept (removing risks
  breaking FluidAudio/CoreML loading, can't verify without a live transcription); paste-restore 0.25s
  race (inherent to paste injection, no reliable completion signal).

## Session 2026-06-01 (evening) — visibility, clipboard, sounds, trash, import, pause fix
- [x] **App visibility mode** (`AppVisibility`: menu-bar only / Dock only / Dock & menu bar;
      default menu-bar only). `Settings.appVisibility` + General picker. `AppDelegate.applyVisibility()`
      toggles `statusItem.isVisible` and the activation policy; `MainWindowController` keeps the
      Dock icon on close unless menu-bar-only; `applicationShouldHandleReopen` reopens the window
      from a Dock click (the way back in when running Dock-only).
- [x] **Auto-copy to clipboard** (`Settings.autoCopyToClipboard`, default on) — copies a finished
      transcript to the clipboard. Excludes dictation (already injects at the cursor). Applied in
      `AppCoordinator.onTranscriptionFinished` for memo/import + meeting.
- [x] **Sound effects** (`Sounds.swift`, `Settings.soundEffects`, default off) — system sounds on
      record start (dictation + meeting), record stop, and transcription done.
- [x] **Recently Deleted + soft delete** — `Recording.deletedAt`; store split into `entries`
      (all) with `recordings` (active) / `deletedRecordings` views. `softDelete`/`restore`/
      `emptyTrash`/`delete`(permanent). Manual deletes (menu, history swipe/context menu, detail
      view) now soft-delete. New sidebar "Recently Deleted" tab (`RecentlyDeletedView`) with
      per-item Restore / Delete-permanently + Empty. Purged 30 days after deletion.
- [x] **Auto-delete old recordings** (`AutoDeletePeriod`, `Settings.autoDeleteAfter`, default
      1 year) — `RecordingStore.runRetention` at launch moves old recordings to Recently Deleted
      and purges trash past the 30-day window. Storage-section picker.
- [x] **Import via sidebar** (`ImportView`) — drag-and-drop or file-picker an audio/video file
      (voice memos etc.); links + transcribes via the existing `importFile` path, jumps to History.
- [x] **Easy delete in History** — swipe-to-delete + right-click context menu (Copy / Reveal /
      Delete) on each row.
- [x] **Media-pause, final approach** (`AudioDucker`) - two earlier tries failed: the blind
      media-key toggle started paused media, and a 350ms self-correct could not fix it (a paused
      app keeps its audio device warm, so `isRunningOutput` looks identical to playing). A second
      try used Apple Events to pause Music/Spotify, but that prompts for Automation per app and
      misses browser video (YouTube). Final approach mirrors Wispr Flow: mute the default output
      device's `VirtualMainVolume` ('vmvc') on dictation start and restore it on stop, only when
      something is actually playing. App-agnostic (covers YouTube etc.), no Automation prompt, and
      since it saves/restores an explicit volume value (not a toggle) it can never start paused
      media. Pre-duck volume persisted so a crash mid-dictation self-heals at next launch
      (`restoreAfterCrashIfNeeded`). Skips muting when a browser or comms app (Safari, Chrome,
      Zoom, Teams, etc.) is producing audio, so a Google-Meet-in-Safari call is never silenced
      (music just keeps playing in that case). Dictation-only; Murmur meetings never duck. Removed the apple-events entitlement + usage string and the
      old `MediaControl.swift`/`MediaPauseController.swift`. Setting/UI copy updated to "Mute audio
      while dictating".

## Session 2026-06-01 (later) — music pause + review fixes
- [x] **Pause playback while dictating** — on dictation start, if something is producing
      audio (`AudioProcessProbe`), send the system Play/Pause key (`MediaControl`) and flag it;
      resume on stop only if we paused (never starts music that wasn't playing). Setting
      `pauseMusicWhileDictating` (default on) + toggle in Settings → Dictation. Dictation-only
      (meetings intentionally capture system audio).
- [x] **Review fixes (all 8 were real):** (1) menu-bar delete now refreshes window+menu;
      (2) `enable()` fires onStateChange on Accessibility-denied so the toggle snaps back;
      (3) `GlobalHotkey` key-up only consumed when the matching key-down was (no stuck keys);
      (4) storage measure moved off the main actor; (5) `durationSeconds` persisted in
      finalizeAndExport so `regenerateIndex` stops reopening audio files; (6) status menu rows
      only rebuilt while the menu is open (not on every transcription tick); (7) latch timer →
      `Task`+`Task.sleep` (Swift-6-clean); (8) removed redundant `save()` in folder migration.
