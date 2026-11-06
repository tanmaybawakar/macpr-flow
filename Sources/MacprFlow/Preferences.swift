import Foundation
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var trigger: TriggerKey { didSet { defaults.set(trigger.rawValue, forKey: "trigger") } }
    @Published var polish: PolishMode { didSet { defaults.set(polish.rawValue, forKey: "polish") } }
    @Published var microphone: String { didSet { defaults.set(microphone, forKey: "microphone") } }
    @Published var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: "smartSpacing") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    @Published var dictionary: [DictionaryEntry] {
        didSet { defaults.set(try? JSONEncoder().encode(dictionary), forKey: "dictionary") }
    }
    @Published var snippets: [Snippet] {
        didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets") }
    }
    @Published var orbStyle: OrbStyle { didSet { defaults.set(orbStyle.rawValue, forKey: "orbStyle") } }
    @Published var orbSensitivity: Double { didSet { defaults.set(orbSensitivity, forKey: "orbSensitivity") } }
    @Published var learnFromEdits: Bool { didSet { defaults.set(learnFromEdits, forKey: "learnFromEdits") } }
    @Published private(set) var wordsDictated: Int { didSet { defaults.set(wordsDictated, forKey: "wordsDictated") } }
    @Published private(set) var secondsSpeaking: Double { didSet { defaults.set(secondsSpeaking, forKey: "secondsSpeaking") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        trigger = defaults.string(forKey: "trigger").flatMap(TriggerKey.init) ?? .controlCommand
        polish = defaults.string(forKey: "polish").flatMap(PolishMode.init) ?? .smart
        let savedMicrophone = defaults.string(forKey: "microphone") ?? AudioDevices.automatic
        // Earlier builds listed macOS's private engine aggregate as a mic. It always meant "the system default".
        microphone = savedMicrophone.hasPrefix("CADefaultDeviceAggregate") ? AudioDevices.systemDefault : savedMicrophone
        smartSpacing = defaults.object(forKey: "smartSpacing") as? Bool ?? true
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        keepHistory = defaults.bool(forKey: "keepHistory")
        dictionary = defaults.data(forKey: "dictionary").flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) } ?? []
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        learnFromEdits = defaults.object(forKey: "learnFromEdits") as? Bool ?? true
        orbStyle = defaults.string(forKey: "orbStyle").flatMap(OrbStyle.init) ?? .ember
        orbSensitivity = defaults.object(forKey: "orbSensitivity") as? Double ?? 1.6
        wordsDictated = defaults.integer(forKey: "wordsDictated")
        secondsSpeaking = defaults.double(forKey: "secondsSpeaking")
    }

    func countDictation(words: Int, seconds: Double) {
        wordsDictated += words
        secondsSpeaking += max(0, seconds)
    }

    /// Words per minute while speaking, once there's enough to say something honest.
    var wordsPerMinute: Int? {
        guard secondsSpeaking >= 30, wordsDictated >= 50 else { return nil }
        return Int((Double(wordsDictated) / (secondsSpeaking / 60)).rounded())
    }

    /// Minutes saved against typing at 40 words a minute.
    var minutesSaved: Int {
        max(0, Int((Double(wordsDictated) / 40 - secondsSpeaking / 60).rounded()))
    }

    func learn(term: String, heardAs: String) {
        guard !dictionary.contains(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        dictionary.insert(DictionaryEntry(term: term, heardAs: heardAs, learned: true), at: 0)
    }

    var terms: [String] { dictionary.map(\.term) }

    /// Registers the login item once, the first time this version launches from a real install location.
    func enableLoginItemOnFirstRun() {
        guard !defaults.bool(forKey: "loginItemOffered"), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        defaults.set(true, forKey: "loginItemOffered")
        try? SMAppService.mainApp.register()
    }
}

enum HistoryStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Macpr Flow", directoryHint: .isDirectory).appending(path: "history.json")
    }

    static func load() -> [HistoryItem] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([HistoryItem].self, from: $0) } ?? []
    }

    static func save(_ items: [HistoryItem]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func erase() { try? FileManager.default.removeItem(at: url) }
}
