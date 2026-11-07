import AppKit
import AVFoundation
import Combine
import FoundationModels

struct SetupStatus: Equatable {
    enum Microphone: Equatable { case unknown, granted, denied }
    enum Speech: Equatable { case checking, downloading(Double), ready, failed(String) }

    var microphone: Microphone = .unknown
    var accessibility = false
    var speech: Speech = .checking
    var shortcut = false
    var intelligence = false
    var intelligenceDetail = ""

    var ready: Bool { microphone == .granted && accessibility && speech == .ready && shortcut }
}

struct Notice: Equatable {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let text: String
}

@MainActor
final class FlowController: ObservableObject {
    /// Hold at least this long and release to finish; a shorter tap locks hands-free.
    static let holdThreshold = 0.3

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var handsFree = false
    @Published private(set) var hudVisible = false
    @Published private(set) var notice: Notice?
    @Published private(set) var setup = SetupStatus()
    @Published private(set) var history: [HistoryItem] = []

    let prefs: Preferences
    let recorder = Recorder()
    private let polisher = Polisher()
    private let sounds = Sounds()
    private let watcher = CorrectionWatcher()
    private var listeningSince: ContinuousClock.Instant?
    private var hotkey: HotkeyTap!
    private var session = UUID()
    private var pressOwnsSession = false
    private var stopRequested = false
    private var noticeTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    var openSettings: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
        hotkey = HotkeyTap { [weak self] intent in self?.handle(intent) }
        history = prefs.keepHistory ? HistoryStore.load() : []
        recorder.onFailure = { [weak self] message in self?.fail(message) }
        watcher.onLearn = { [weak self] correction in
            guard let self, prefs.learnFromEdits else { return }
            let message: String? = switch prefs.learn(correction) {
            case .added: "Learned \u{201C}\(correction.term)\u{201D}. It\u{2019}ll be spelled your way from now on."
            case .newSpelling: "Learned that \u{201C}\(correction.heard)\u{201D} means \u{201C}\(correction.term)\u{201D}."
            case .listening: "Added \u{201C}\(correction.term)\u{201D}. Fix it once more and \u{201C}\(correction.heard)\u{201D} becomes it automatically."
            case .nothing: nil
            }
            if let message, !phase.busy { flash(.success, message) }
        }

        prefs.$trigger.sink { [weak self] in self?.hotkey.setKey($0) }.store(in: &bag)
        prefs.$microphone.sink { [weak self] in self?.recorder.microphone = $0 }.store(in: &bag)
        prefs.$dictionary.map { $0.map(\.term) }.removeDuplicates().sink { [weak self] terms in
            guard let self else { return }
            recorder.vocabulary = terms
            if phase == .idle, setup.speech == .ready { Task { try? await self.recorder.warm() } }
        }.store(in: &bag)
        prefs.$keepHistory.dropFirst().sink { [weak self] keep in
            guard let self else { return }
            if keep { HistoryStore.save(history) } else { HistoryStore.erase() }
        }.store(in: &bag)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.cancel() }.store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
    }

    // MARK: Lifecycle

    func launch() {
        refresh()
        prepareSpeech()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval: Duration = setup.ready ? .seconds(3) : .seconds(1)
                try? await Task.sleep(for: interval)
                refresh()
            }
        }
    }

    func shutdown() {
        monitor?.cancel()
        cancel()
        hotkey.stop()
        watcher.stop()
    }

    /// Cheap permission + health check. Also restarts the shortcut if macOS switched it off.
    func refresh() {
        var next = setup
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: next.microphone = .granted
        case .denied, .restricted: next.microphone = .denied
        default: next.microphone = .unknown
        }
        next.accessibility = AXIsProcessTrusted()
        if next.accessibility { next.shortcut = hotkey.ensureRunning() } else { hotkey.stop(); next.shortcut = false }
        switch polisher.availability {
        case .available:
            next.intelligence = true; next.intelligenceDetail = "Ready"
        case .unavailable(.appleIntelligenceNotEnabled):
            next.intelligence = false; next.intelligenceDetail = "Turn on Apple Intelligence in System Settings to polish longer dictations."
        case .unavailable(.modelNotReady):
            next.intelligence = false; next.intelligenceDetail = "Apple Intelligence is still getting ready."
        case .unavailable(.deviceNotEligible):
            next.intelligence = false; next.intelligenceDetail = "This Mac doesn't support Apple Intelligence."
        case .unavailable:
            next.intelligence = false; next.intelligenceDetail = "Apple Intelligence isn't available."
        }
        if next != setup { setup = next }
    }

    func prepareSpeech() {
        guard speechTask == nil else { return }
        if case .failed = setup.speech { setup.speech = .checking }
        speechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { speechTask = nil }
            do {
                try await recorder.installAssets { [weak self] fraction in
                    guard let self, let fraction else { return }
                    setup.speech = .downloading(fraction)
                }
                try await recorder.warm()
                setup.speech = .ready
            } catch {
                setup.speech = .failed(error.localizedDescription)
            }
        }
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refresh() }
        } else {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openSystemSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Shortcut

    private func handle(_ intent: HotkeyIntent) {
        switch intent {
        case .pressed:
            if phase == .idle { pressOwnsSession = true; begin() } else { pressOwnsSession = false }
        case .released(let held):
            if pressOwnsSession {
                pressOwnsSession = false
                if held >= Self.holdThreshold { finish() }
                else if phase == .starting || phase == .listening { handsFree = true }
            } else if phase == .starting || phase == .listening {
                finish()
            }
        case .interrupted:
            if pressOwnsSession { pressOwnsSession = false; discard() }
        case .escape:
            if phase == .starting || phase == .listening { cancel() }
        }
    }

    /// Start or finish from the menu bar or the HUD.
    func toggleFromUI() {
        switch phase {
        case .idle: pressOwnsSession = false; begin(); handsFree = phase.busy
        case .starting, .listening: finish()
        case .finishing: break
        }
    }

    // MARK: Dictation

    private func begin() {
        guard setup.ready else {
            if case .downloading(let fraction) = setup.speech {
                flash(.info, "The English speech model is downloading (\(Int(fraction * 100))%).")
            } else {
                flash(.warning, "Finish setup to start dictating.")
                openSettings?()
            }
            return
        }
        session = UUID()
        let id = session
        phase = .starting
        handsFree = false
        stopRequested = false
        notice = nil
        noticeTask?.cancel()
        watcher.stop()
        listeningSince = .now
        polisher.prewarm(terms: prefs.terms)

        // A short grace period keeps the HUD and sound from flashing when the trigger was part of another shortcut.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, session == id, phase == .starting || phase == .listening else { return }
            hudVisible = true
            if prefs.sounds { sounds.start() }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await recorder.start()
                guard session == id else { return }
                phase = .listening
                if stopRequested { finish() }
            } catch {
                guard session == id else { return }
                fail(error.localizedDescription)
            }
        }
    }

    func finish() {
        if phase == .starting { stopRequested = true; return }
        guard phase == .listening else { return }
        let id = session
        phase = .finishing
        handsFree = false
        if prefs.sounds && hudVisible { sounds.stop() }

        Task { @MainActor [weak self] in
            // Keep listening a beat after release so the last syllable isn't clipped.
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, session == id else { return }
            let recorder = recorder
            let soFar = recorder.partialText
            let transcript = await firstResult(within: .seconds(6)) { try await recorder.finish() }
            let raw = transcript ?? (recorder.isLive ? recorder.partialText : soFar)
            if transcript == nil { await recorder.cancel() }
            guard session == id else { return }
            await deliver(raw, id: id)
        }
    }

    private func deliver(_ raw: String, id: UUID) async {
        let spoken = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            complete()
            flash(.info, "No speech heard. Check that the right microphone is selected.")
            return
        }
        let spokenFor = listeningSince.map { ContinuousClock.now - $0 } ?? .zero
        prefs.countDictation(words: TextPolish.wordCount(spoken),
                             seconds: Double(spokenFor.components.seconds) + Double(spokenFor.components.attoseconds) / 1e18)
        var text = TextPolish.basic(spoken, dictionary: prefs.dictionary)
        if let snippet = Snippet.match(spoken, in: prefs.snippets) {
            text = snippet.text
        } else if prefs.polish == .always || (prefs.polish == .smart && TextPolish.needsModel(text)) {
            if let polished = await polisher.polish(text, terms: prefs.terms) {
                text = TextPolish.applyDictionary(polished, prefs.dictionary)
            }
            guard session == id else { return }
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let result = Inserter.insert(text, smartSpacing: prefs.smartSpacing)
        record(HistoryItem(text: text, raw: spoken, app: app))
        complete()
        switch result {
        case .copied(let reason): flash(.info, reason)
        case .pasted(let context?) where prefs.learnFromEdits:
            watcher.watch(inserted: text, at: context) { [weak self] in self?.prefs.learnedKeys ?? [] }
        case .pasted: break
        }
    }

    private func complete() {
        phase = .idle
        handsFree = false
        hudVisible = false
        Task { try? await recorder.warm() }
    }

    /// A press that turned out to be another shortcut. Leave no trace.
    private func discard() {
        guard phase.busy else { return }
        session = UUID()
        phase = .idle; handsFree = false; hudVisible = false
        Task { await recorder.cancel(); try? await recorder.warm() }
    }

    func cancel() {
        guard phase.busy else { return }
        keepPartial()
        discard()
    }

    private func fail(_ message: String) {
        guard phase.busy else { return }
        keepPartial()
        discard()
        if prefs.sounds { sounds.error() }
        flash(.error, message)
    }

    private func keepPartial() {
        let partial = recorder.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty {
            record(HistoryItem(text: TextPolish.basic(partial, dictionary: prefs.dictionary), raw: partial, app: nil, cancelled: true))
        }
    }

    private func flash(_ kind: Notice.Kind, _ text: String) {
        noticeTask?.cancel()
        notice = Notice(kind: kind, text: text)
        hudVisible = true
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 4 : 3))
            guard let self, !Task.isCancelled else { return }
            notice = nil
            if phase == .idle { hudVisible = false }
        }
    }

    // MARK: History

    private func record(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        if prefs.keepHistory { HistoryStore.save(history) }
    }

    func clearHistory() {
        history = []
        HistoryStore.erase()
    }

    func copy(_ text: String) { Inserter.copy(text) }

    func pasteLast() {
        guard let text = history.first?.text else { return }
        // Let the menu close and focus return to the previous app first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            _ = Inserter.insert(text, smartSpacing: prefs.smartSpacing)
        }
    }

    var statusLine: String {
        switch phase {
        case .starting, .listening: return handsFree ? "Listening hands-free" : "Listening"
        case .finishing: return "Writing"
        case .idle: break
        }
        if !setup.accessibility || setup.microphone != .granted { return "Setup needed" }
        switch setup.speech {
        case .checking: return "Getting ready"
        case .downloading(let f): return "Downloading speech model, \(Int(f * 100))%"
        case .failed: return "Speech model unavailable"
        case .ready: return "Hold \(prefs.trigger.short) to dictate"
        }
    }
}

/// Short, quiet cues. Played on the same frame the HUD changes.
@MainActor
final class Sounds {
    private let begin = NSSound(named: "Tink")?.copy() as? NSSound
    private let end = NSSound(named: "Pop")?.copy() as? NSSound
    private let problem = NSSound(named: "Funk")?.copy() as? NSSound

    init() { for sound in [begin, end, problem] { sound?.volume = 0.28 } }

    func start() { play(begin) }
    func stop() { play(end) }
    func error() { play(problem) }

    private func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop(); sound.play()
    }
}
