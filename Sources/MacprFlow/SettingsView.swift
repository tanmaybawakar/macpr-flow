import AppKit
import ServiceManagement
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case general, dictionary, snippets, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .history: "History"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct SettingsRoot: View {
    @ObservedObject var controller: FlowController
    @ObservedObject var prefs: Preferences
    @State private var pane: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane(controller: controller, prefs: prefs)
                case .dictionary: DictionaryPane(prefs: prefs)
                case .snippets: SnippetsPane(prefs: prefs)
                case .history: HistoryPane(controller: controller, prefs: prefs)
                }
            }
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 720, minHeight: 540)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var controller: FlowController
    @ObservedObject var prefs: Preferences
    @State private var devices = AudioDevices.inputs()
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var globeConflict = GlobeKey.conflicts

    var body: some View {
        Form {
            if !controller.setup.ready {
                SetupSection(controller: controller)
            }

            Section {
                ShortcutHero(trigger: prefs.trigger, ready: controller.setup.ready)
                Picker("Shortcut", selection: $prefs.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                if prefs.trigger == .fn && globeConflict {
                    LabeledContent {
                        Button("Open Keyboard Settings") {
                            controller.openSystemSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                        }
                    } label: {
                        Text("macOS also uses the Globe key")
                        Text("Set \u{201C}Press Globe key to\u{201D} to \u{201C}Do Nothing\u{201D} so it doesn't open the emoji picker.")
                    }
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold to talk and release to insert. Tap once to keep listening hands-free, then tap again to finish. Press Esc to cancel.")
            }

            Section {
                HStack(spacing: 18) {
                    OrbPreview(style: prefs.orbStyle, sensitivity: prefs.orbSensitivity)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Orb", selection: $prefs.orbStyle) {
                            ForEach(OrbStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Text(prefs.orbStyle == .ember
                             ? "A warm sphere of light that swells and ripples with your voice."
                             : "Glass rings that turn like a gyroscope, with light that travels faster as you speak.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Sensitivity") {
                    Slider(value: $prefs.orbSensitivity, in: 0.5...2.5) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.wave.1").accessibilityLabel("Calm")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3").accessibilityLabel("Reactive")
                    }
                    .frame(maxWidth: 260)
                }
            } header: {
                Text("Listening orb")
            } footer: {
                Text("Higher sensitivity makes the orb react to quieter speech and move more with every syllable.")
            }

            Section {
                Picker("Microphone", selection: $prefs.microphone) {
                    Text("Automatic").tag(AudioDevices.automatic)
                    Text("System default").tag(AudioDevices.systemDefault)
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let active = AudioDevices.activeName(for: prefs.microphone) {
                        Text("Recording from \(active).")
                    }
                    Text("Automatic follows your Mac's input setting, but switches to the built-in mic when Bluetooth headphones are connected, so their audio stays at full quality.")
                }
            }

            Section {
                Picker("Polish with Apple Intelligence", selection: $prefs.polish) {
                    ForEach(PolishMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Add a space before new text when needed", isOn: $prefs.smartSpacing)
            } header: {
                Text("Writing")
            } footer: {
                Text(polishFooter)
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { loginItem }, set: setLoginItem))
                Toggle("Play sounds", isOn: $prefs.sounds)
            }

            Section {
                Text("Speech recognition and polishing run on this Mac. Nothing you say is sent anywhere, and nothing is saved unless you turn on History.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            devices = AudioDevices.inputs()
            loginItem = SMAppService.mainApp.status == .enabled
            globeConflict = GlobeKey.conflicts
        }
    }

    private var polishFooter: String {
        guard controller.setup.intelligence else { return controller.setup.intelligenceDetail + " Fillers and repeated words are still removed instantly." }
        switch prefs.polish {
        case .smart: return "Fillers are removed instantly. Apple Intelligence steps in for corrections like \u{201C}actually, make that Friday\u{201D}, spoken lists and punctuation, and long dictations."
        case .always: return "Every dictation is polished by Apple Intelligence. This adds about a second."
        case .off: return "Text is inserted as transcribed, with fillers and repeated words removed."
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

private enum GlobeKey {
    /// 0 means "Do Nothing". Missing means the macOS default, which opens the emoji picker.
    static var conflicts: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 2) != 0
    }
}

private struct ShortcutHero: View {
    let trigger: TriggerKey
    let ready: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(trigger.keycaps, id: \.self) { Keycap(label: $0) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(ready ? "Hold to dictate" : "Almost ready")
                    .font(.title3.weight(.semibold))
                Text(ready ? "Your words appear wherever the cursor is." : "Finish the steps above, then hold the shortcut and speak.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct Keycap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 40)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.14), radius: 0.5, y: 1)
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
    }
}

private struct SetupSection: View {
    @ObservedObject var controller: FlowController

    var body: some View {
        Section {
            SetupRow(title: "Microphone", detail: "Hear you while you hold the shortcut.",
                     done: controller.setup.microphone == .granted,
                     action: SetupAction(title: "Allow") { controller.requestMicrophone() })
            SetupRow(title: "Accessibility", detail: "Notice the shortcut and paste your text into other apps.",
                     done: controller.setup.accessibility,
                     action: SetupAction(title: "Open Settings") { controller.requestAccessibility() })
            SetupRow(title: "English speech model", detail: speechDetail(controller.setup.speech),
                     done: controller.setup.speech == .ready, progress: speechProgress(controller.setup.speech),
                     action: speechAction(controller.setup.speech))
        } header: {
            Text("Finish setting up")
        } footer: {
            Text("Macpr Flow checks again automatically. You don't need to restart it.")
        }
    }

    private func speechDetail(_ s: SetupStatus.Speech) -> String {
        switch s {
        case .checking: "Checking the on-device model."
        case .downloading(let f): "Downloading from Apple, \(Int(f * 100))%."
        case .ready: "Installed on this Mac."
        case .failed(let message): message
        }
    }
    private func speechProgress(_ s: SetupStatus.Speech) -> Double? {
        if case .downloading(let f) = s { return f }
        if case .checking = s { return -1 }
        return nil
    }
    private func speechAction(_ s: SetupStatus.Speech) -> SetupAction? {
        if case .failed = s { return SetupAction(title: "Try Again") { controller.prepareSpeech() } }
        return nil
    }
}

private struct SetupAction {
    let title: String
    let run: () -> Void
}

private struct SetupRow: View {
    let title: String
    let detail: String
    let done: Bool
    var progress: Double?
    let action: SetupAction?

    var body: some View {
        LabeledContent {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
            } else if let progress {
                if progress < 0 { ProgressView().controlSize(.small) }
                else { ProgressView(value: progress).frame(width: 90) }
            } else if let action {
                Button(action.title, action: action.run)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPane: View {
    @ObservedObject var prefs: Preferences
    @State private var term = ""
    @State private var heardAs = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Word or name", text: $term, prompt: Text("Supabase"))
                    .focused($focused)
                    .onSubmit(add)
                TextField("Sounds like", text: $heardAs, prompt: Text("super base"))
                    .onSubmit(add)
                HStack {
                    Spacer()
                    Button("Add Word", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add a word")
            } footer: {
                Text("Names, brands and jargon you use. Macpr Flow listens for them and spells them your way. \u{201C}Sounds like\u{201D} is optional; separate several with commas.")
            }

            Section {
                Toggle("Learn from your corrections", isOn: $prefs.learnFromEdits)
            } footer: {
                Text("Fix a misheard name or term in the text Macpr Flow typed, and it learns: the word joins your dictionary and the recognizer listens for it. Fixes to everyday words (like \u{201C}cloud\u{201D} → \u{201C}Claude\u{201D}) apply automatically once you've made them twice.")
            }

            Section("Your words") {
                if prefs.dictionary.isEmpty {
                    Text("Words you add appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.dictionary) { entry in
                        LabeledContent {
                            Button {
                                prefs.dictionary.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(entry.term)")
                        } label: {
                            Text(entry.term)
                            if !entry.heardAs.isEmpty {
                                Text(entry.learned ? "Learned from \u{201C}\(entry.heardAs)\u{201D}" : "Sounds like \(entry.heardAs)")
                            } else if entry.learned {
                                Text("Learned from your edit")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let clean = term.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        prefs.dictionary.removeAll { $0.term.caseInsensitiveCompare(clean) == .orderedSame }
        prefs.dictionary.insert(DictionaryEntry(term: clean, heardAs: heardAs.trimmingCharacters(in: .whitespaces)), at: 0)
        term = ""; heardAs = ""
        focused = true
    }
}

// MARK: - History

private struct HistoryPane: View {
    @ObservedObject var controller: FlowController
    @ObservedObject var prefs: Preferences
    @State private var copied: UUID?

    var body: some View {
        Form {
            if prefs.wordsDictated > 0 {
                Section("Your dictation") {
                    LabeledContent("Words dictated", value: prefs.wordsDictated.formatted())
                    if let wpm = prefs.wordsPerMinute {
                        LabeledContent("Speaking speed", value: "\(wpm) words a minute")
                    }
                    if prefs.minutesSaved > 0 {
                        LabeledContent("Time saved", value: "About \(prefs.minutesSaved) min versus typing")
                    }
                }
            }
            Section {
                Toggle("Keep history after quitting", isOn: $prefs.keepHistory)
            } footer: {
                Text("Off by default. When on, recent dictations are saved on this Mac only.")
            }

            Section {
                if controller.history.isEmpty {
                    Text("Your dictations appear here, so you can copy one again.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.history) { item in
                        HistoryRow(item: item, copied: copied == item.id) {
                            controller.copy(item.text)
                            copied = item.id
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    if !controller.history.isEmpty {
                        Button("Clear") { controller.clearHistory() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(copied ? "Copied" : "Copy", action: copy)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var meta: String {
        let time = item.date.formatted(date: Calendar.current.isDateInToday(item.date) ? .omitted : .abbreviated, time: .shortened)
        if item.cancelled { return "\(time), cancelled before inserting" }
        if let app = item.app { return "\(time) in \(app)" }
        return time
    }
}

// MARK: - Snippets

private struct SnippetsPane: View {
    @ObservedObject var prefs: Preferences
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextField("When you say", text: $trigger, prompt: Text("my calendar link"))
                TextField("Insert", text: $text, prompt: Text("https://cal.com/you"), axis: .vertical)
                    .lineLimit(1...6)
                HStack {
                    Spacer()
                    Button("Add Snippet", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Add a snippet")
            } footer: {
                Text("Say the phrase on its own and the full text is inserted: links, addresses, sign-offs, replies you send often.")
            }

            Section("Your snippets") {
                if prefs.snippets.isEmpty {
                    Text("Snippets you add appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.snippets) { snippet in
                        LabeledContent {
                            Button {
                                prefs.snippets.removeAll { $0.id == snippet.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(snippet.trigger)")
                        } label: {
                            Text("\u{201C}\(snippet.trigger)\u{201D}")
                            Text(snippet.text).lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let key = trigger.trimmingCharacters(in: .whitespaces)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !body.isEmpty else { return }
        prefs.snippets.removeAll { Snippet.normalized($0.trigger) == Snippet.normalized(key) }
        prefs.snippets.insert(Snippet(trigger: key, text: body), at: 0)
        trigger = ""; text = ""
    }
}

/// A live orb driven by a synthetic voice, so you can see each style move before choosing it.
private struct OrbPreview: NSViewRepresentable {
    let style: OrbStyle
    let sensitivity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> OrbView {
        let view = OrbView(signal: VoiceSignal())
        view.state = OrbState(visible: true, reduceMotion: reduceMotion, style: style,
                              sensitivity: Float(sensitivity), preview: true)
        return view
    }

    func updateNSView(_ view: OrbView, context: Context) {
        view.state = OrbState(visible: true, reduceMotion: reduceMotion, style: style,
                              sensitivity: Float(sensitivity), preview: true)
    }

    static func dismantleNSView(_ view: OrbView, coordinator: ()) {
        view.state = OrbState()
    }
}
