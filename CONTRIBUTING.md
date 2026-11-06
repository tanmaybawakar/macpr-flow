# Contributing

Thanks for helping make Macpr Flow better.

## Ground rules

- **On device only.** No network calls, analytics, or cloud fallbacks. Audio is never written to disk.
- **No third-party dependencies.** Apple frameworks only.
- **Keep the hot paths off the main actor.** The event-tap callback, the audio threads and the orb's `draw` must not block or await main-actor work. Don't use `MainActor.assumeIsolated` in callbacks (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#concurrency-notes)).
- **Text safety first.** Any change to cleanup must keep the model from answering, summarising, or inventing. Extend `TextPolish.vetted` tests when you touch it.

## Develop

```sh
swift build
swift test
Scripts/package_app.sh          # builds, signs, installs to /Applications
INSTALL=0 Scripts/package_app.sh  # build the bundle without installing
```

`Scripts/package_app.sh` restarts a running copy when it installs. Use a stable signing identity (see the README) so macOS keeps Microphone and Accessibility permissions between builds.

Useful checks:

```sh
.build/release/MacprFlow --render-orbs ./out   # renders both orbs offscreen; no microphone
.build/release/MacprFlow --model-check         # Apple Intelligence cleanup cases
```

## Pull requests

- One focused change per PR, with a short description of what you changed and how you checked it.
- Add or update tests for logic changes: shortcut handling, cleanup, corrections, vetting and learning are all pure and easy to test.
- For visual changes to the orb or settings, include a screenshot or a `--render-orbs` image.
- Follow the existing style: Swift 6 strict concurrency, small types, comments that explain *why*.

## Reporting bugs

Include your macOS version, Mac model, the microphone you use, and what you said versus what was inserted, if you're comfortable sharing it. For crashes, attach the report from `~/Library/Logs/DiagnosticReports/MacprFlow-*.ips`.
