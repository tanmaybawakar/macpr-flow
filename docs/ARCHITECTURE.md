# Architecture

Macpr Flow is a single Swift package (`Sources/MacprFlow`) with no dependencies beyond Apple's frameworks. The rule throughout is that the main thread never waits on anything slow, and nothing that runs on every keystroke or audio cycle touches the main actor.

```
shortcut (event-tap thread) ──► FlowController (main actor) ──► Recorder ──► SpeechAnalyzer
                                         │                         │
                                         │                         └─► VoiceSignal ──► Orb (Metal)
                                         ▼
                        TextPolish ─► SelfCorrection ─► Polisher (Apple Intelligence, optional)
                                         │
                                         ▼
                                  Inserter (paste) ──► CorrectionWatcher (learns edits)
```

## Files

| File | Role |
| --- | --- |
| `MacprFlowApp.swift` | App entry, menu-bar menu, single-instance guard, window and HUD wiring |
| `Controller.swift` | `FlowController`: the dictation state machine, setup checks, history, sounds |
| `Session.swift` | Pure types: phases, `TriggerMachine` (shortcut logic), dictionary/snippet/history models, `firstResult` deadline helper |
| `Hotkey.swift` | Global shortcut via a `CGEventTap` on a dedicated thread |
| `Recorder.swift` | `AVAudioEngine` + `SpeechAnalyzer` pipeline, kept warm between dictations |
| `AudioDevices.swift` | Core Audio input listing and the *Automatic* microphone rule |
| `VoiceSignal.swift` | Lock-free voice level and three frequency bands, measured on the audio I/O thread |
| `TextPolish.swift` | Deterministic cleanup, the "does this need the model?" test, and output vetting |
| `SelfCorrection.swift` | Resolves spoken corrections ("3, sorry, 4 pm") without the model |
| `Cleanup.swift` | `Polisher`: prewarmed Apple Intelligence session with a deadline |
| `Insertion.swift` | Pasting, clipboard restore, smart spacing, layout-aware ⌘V |
| `Learning.swift` | Word-level diff of your edits; adds misheard terms to the dictionary |
| `Orb.swift` | Metal renderer and shaders for the Ember and Orbit orbs |
| `HUD.swift` | Non-activating floating panel: the orb plus native glass controls |
| `SettingsView.swift` | Settings window (SwiftUI `NavigationSplitView` + grouped `Form`) |
| `Preferences.swift` | `UserDefaults`-backed settings, stats, login item, history store |
| `Diagnostics.swift` | Command-line checks (`--model-check`, `--microphone-check`, `--render-orbs`, `--transcribe-file`) |

## Shortcut

`HotkeyTap` creates a session-level `CGEventTap` for `flagsChanged` and `keyDown` on its own thread with its own run loop. Every keystroke on the Mac passes through an active tap, so the callback only advances `TriggerMachine`, a small pure state machine, and posts the result to the main actor with `Task { @MainActor in … }`. A busy main thread can't slow typing system-wide, and macOS has no reason to disable the tap. If it does (`tapDisabledByTimeout`), the tap is re-enabled and the modifier state resynced from `CGEventSource.flagsState`, so a held key can't get stuck.

`TriggerMachine` emits four intents:

- `pressed`: the trigger went down with no other modifiers.
- `released(held:)`: released cleanly. Held ≥ 0.3 s means push-to-talk, so it finishes. A shorter tap locks hands-free.
- `interrupted`: another key or modifier arrived within 0.5 s, so it was a shortcut like ⌃⌘Space. The session is discarded without a trace (the HUD waits 90 ms before appearing, so nothing flashes).
- `escape`: cancel.

Left and right modifiers are told apart through the device-dependent bits in `CGEventFlags`.

## Speech pipeline

`Recorder` keeps one `AVAudioEngine` and rebuilds it only when you change microphones, because switching the device on a live engine is unreliable. Each `SpeechAnalyzer` is used once, so after every dictation the next one is created and `prepareToAnalyze` is called while you're idle. `modelRetention: .processLifetime` keeps the model in memory. When you press the shortcut:

1. Audio starts immediately and buffers into an unbounded `AsyncStream`, so the first word is never lost.
2. The prepared analyzer is attached to that stream.
3. When you finish, the app keeps listening for 140 ms so the last syllable isn't clipped, then calls `finalizeAndFinishThroughEndOfInput()`, with a 6 s deadline that falls back to the partial transcript.

Audio reaches the transcriber through a tap, which delivers large buffers. The orb needs something much faster, so an `AVAudioSinkNode` on the same input runs `VoiceSignal.process` on the real-time thread each I/O cycle. It uses two one-pole filters to split low, mid and high bands, with no allocation and no locks on the read side (`Atomic<UInt32>` float bits).

## Cleanup

1. **`TextPolish.basic`** (microseconds) handles spoken breaks ("new paragraph"), fillers, stutters for a fixed set of words (so "had had" survives), and casing that leaves "iPhone" alone. Then it runs `SelfCorrection` and applies dictionary spellings.
2. **`SelfCorrection.resolve`** finds markers ("sorry", "I mean", "no wait", "scratch that", …), skips apologies by looking at the preceding word ("I'm sorry"), and repairs only when it's unambiguous:
   - negation swap: "not John, Mike"
   - restart from a repeated word: "the blue design, sorry, the red design"
   - number swap: "at 3, sorry, 4 pm"
   - short swap: "Monday, I mean Tuesday"
   - erase: "scratch that"
3. **`TextPolish.needsModel`** decides whether Apple Intelligence earns its latency: remaining correction cues, enumerations, spoken punctuation, or 45+ words. Settings can force it *Always* or *Off*.
4. **`Polisher`** creates a `LanguageModelSession` and calls `prewarm()` the moment you start speaking, so the model is loaded by the time you stop. It uses greedy sampling and a deadline of 2.5 s + 30 ms per word, up to 8 s.
5. **`TextPolish.vetted`** strips prefaces, fences and quotes, then rejects output that grew too much, deleted most of the text, adds more than about 20% new words, or introduces a capitalised name that wasn't spoken. A dictated question can never come back answered.

## Insertion and learning

`Inserter` always pastes, because it's the only route that works across native, web and Electron apps. It:

- snapshots the clipboard (keeping the *original* one across back-to-back dictations)
- writes the text with the `org.nspasteboard.TransientType` marker
- posts ⌘V using the key code that types "v" with Command on the current keyboard layout
- restores the clipboard after 1.2 s if nothing else changed it

Smart spacing asks Accessibility for the character before the caret, with a 150 ms messaging timeout so a hung app can't stall us. Secure input is never typed into.

After a paste, `CorrectionWatcher` re-reads that text field every 4 s for about 45 s. `CorrectionLearner` runs a word-level LCS diff between what was inserted and what's there now. A replacement is learned when it holds still across two checks, is similar to what was heard, and isn't a common English word according to `NSSpellChecker` (or has inner capitals, like "GitHub").

## Orb

`OrbView` is an `MTKView` drawing at the screen's maximum refresh rate. It pauses itself once the orb has faded out, so it costs nothing when idle. The renderer is deliberately not actor-isolated. It shapes the signal the way an audio visualiser does:

- instant-attack, short-release envelopes
- syllable onsets detected as jumps above a slower average, which kick an underdamped spring
- Apple-style damping/response springs for appearing, leaving and the "writing" state

Sensitivity applies a curve to the input, so quiet voices are lifted rather than everything simply being multiplied.

- **Ember**: a lit sphere with 3D value-noise light inside, silk-like ribbons, fresnel rim, specular highlight and a premultiplied halo. Low, mid and high bands each ripple the rim.
- **Orbit**: glass tubes in a fixed composition (outer circle, two thick loops on a diagonal, inner band, circuit ring with dots). The CPU projects the ring curves each frame and the shader only measures distance to segments. The whole piece turns slowly as one, light pulses travel along the tubes, and syllables ripple outward ring by ring through chained springs.

The HUD panel is `nonactivatingPanel` and can't become key, so typing focus never leaves your app. The cancel and stop controls are SwiftUI with the system `.glass` and `.glassProminent` button styles.

## Concurrency notes

Swift 6 strict concurrency is on. On macOS 26/27, using `MainActor.assumeIsolated` inside framework callbacks was seen to corrupt the runtime's executor check and crash later main-actor thunks. The code therefore never uses `assumeIsolated`. Callbacks hop with `Task { @MainActor in … }`, and AppKit entry points that only return constants (`canBecomeKey`) are `nonisolated`.

## Tests

`swift test` covers:

- the shortcut state machine (holds, taps, interrupted shortcuts, left/right modifiers)
- fillers, stutters, casing, spoken breaks and the dictionary
- self-corrections and the apologies that must survive them
- model gating and output vetting (answers, prefaces, quotes)
- smart spacing, correction learning, snippets, decoding of older settings, and deadlines
