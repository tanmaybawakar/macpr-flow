# Changelog

## 2.0.0

- Hold-to-talk and tap-for-hands-free shortcut on fn, right ⌥, right ⌘ or ⌃⌘, on its own event-tap thread.
- Warm speech pipeline: persistent engine, prepared analyzer, model kept in memory.
- Instant cleanup of fillers and stutters, plus spoken self-corrections resolved without the model.
- Apple Intelligence polish only when needed, prewarmed while you speak, with output vetting.
- Universal paste with clipboard restore, smart spacing and layout-aware ⌘V.
- Personal dictionary that learns from your corrections, snippets, history and usage stats.
- Metal listening orb with two styles, Ember and Orbit, and adjustable sensitivity.
- Microphone picker with an *Automatic* mode that avoids Bluetooth call-quality audio.
- Liquid Glass app icon that follows the system icon style.
- Fixed crashes caused by `MainActor.assumeIsolated` in callbacks on macOS 26/27.
