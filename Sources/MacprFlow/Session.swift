import Foundation

/// One dictation moves through these phases. Anything other than `.idle` blocks a new start.
enum Phase: String, Sendable {
    case idle, starting, listening, finishing
    var busy: Bool { self != .idle }
}

// MARK: - Shortcut

enum TriggerKey: String, CaseIterable, Identifiable, Sendable {
    case fn, rightOption, rightCommand, controlCommand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: "fn (Globe)"
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .controlCommand: "Control ⌃ + Command ⌘"
        }
    }

    /// The keycaps drawn in Settings and spoken in status text.
    var keycaps: [String] {
        switch self {
        case .fn: ["fn"]
        case .rightOption: ["right ⌥"]
        case .rightCommand: ["right ⌘"]
        case .controlCommand: ["⌃", "⌘"]
        }
    }

    var short: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .controlCommand: "⌃⌘"
        }
    }
}

/// Which modifier keys are physically down, decoded from CGEventFlags (device-dependent bits included).
struct ModifierState: Equatable, Sendable {
    var shift = false, control = false, fn = false
    var leftOption = false, rightOption = false
    var leftCommand = false, rightCommand = false

    init(shift: Bool = false, control: Bool = false, fn: Bool = false,
         leftOption: Bool = false, rightOption: Bool = false,
         leftCommand: Bool = false, rightCommand: Bool = false) {
        self.shift = shift; self.control = control; self.fn = fn
        self.leftOption = leftOption; self.rightOption = rightOption
        self.leftCommand = leftCommand; self.rightCommand = rightCommand
    }

    init(flags: UInt64) {
        shift = flags & 0x0002_0000 != 0
        control = flags & 0x0004_0000 != 0
        fn = flags & 0x0080_0000 != 0
        let option = flags & 0x0008_0000 != 0
        let command = flags & 0x0010_0000 != 0
        // NX_DEVICE* bits tell left from right. Some remappers omit them; treat those as left.
        rightOption = option && flags & 0x40 != 0
        leftOption = option && !rightOption
        rightCommand = command && flags & 0x10 != 0
        leftCommand = command && (flags & 0x08 != 0 || !rightCommand)
    }

    var option: Bool { leftOption || rightOption }
    var command: Bool { leftCommand || rightCommand }

    func isDown(_ key: TriggerKey) -> Bool {
        switch key {
        case .fn: fn
        case .rightOption: rightOption
        case .rightCommand: rightCommand
        case .controlCommand: control && command
        }
    }

    /// Modifiers that are not part of the trigger. Holding any of them means the user is typing a shortcut.
    func othersHeld(for key: TriggerKey) -> Bool {
        switch key {
        case .fn: shift || control || option || command
        case .rightOption: shift || control || fn || leftOption || command
        case .rightCommand: shift || control || fn || option || leftCommand
        case .controlCommand: shift || fn || option
        }
    }
}

enum HotkeyIntent: Equatable, Sendable {
    case pressed
    case released(held: Double)
    /// The press turned out to be part of another shortcut. Drop anything it started, silently.
    case interrupted
    case escape
}

/// Pure state machine for the trigger. It runs on the event-tap thread, so it never blocks or allocates much.
struct TriggerMachine: Sendable {
    let key: TriggerKey
    /// A key pressed within this window after the trigger means "this was a shortcut", not dictation.
    static let spoilWindow = 0.5
    private(set) var down = false
    private var blocked = false
    private var spoiled = false
    private var downAt = 0.0

    init(key: TriggerKey) { self.key = key }

    mutating func modifiers(_ state: ModifierState, at time: Double) -> HotkeyIntent? {
        guard state.isDown(key) else {
            defer { down = false; blocked = false; spoiled = false }
            return down && !spoiled ? .released(held: time - downAt) : nil
        }
        if blocked { return nil }
        if !down {
            if state.othersHeld(for: key) { blocked = true; return nil }
            down = true; spoiled = false; downAt = time
            return .pressed
        }
        return state.othersHeld(for: key) ? spoil(at: time) : nil
    }

    mutating func keyDown(code: Int64, at time: Double) -> HotkeyIntent? {
        if code == 53 { return .escape }
        return down ? spoil(at: time) : nil
    }

    private mutating func spoil(at time: Double) -> HotkeyIntent? {
        guard !spoiled, time - downAt < Self.spoilWindow else { return nil }
        spoiled = true
        return .interrupted
    }
}

// MARK: - Shared types

struct FlowError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum PolishMode: String, CaseIterable, Identifiable, Sendable {
    case smart, always, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "When needed"
        case .always: "Always"
        case .off: "Off"
        }
    }
}

struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var term: String
    var heardAs: String = ""
    var learned = false

    init(id: UUID = UUID(), term: String, heardAs: String = "", learned: Bool = false) {
        self.id = id; self.term = term; self.heardAs = heardAs; self.learned = learned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        term = try c.decode(String.self, forKey: .term)
        heardAs = try c.decodeIfPresent(String.self, forKey: .heardAs) ?? ""
        learned = try c.decodeIfPresent(Bool.self, forKey: .learned) ?? false
    }

    var variants: [String] {
        heardAs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Say the trigger on its own and the full text is inserted instead.
struct Snippet: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var trigger: String
    var text: String

    static func normalized(_ s: String) -> String {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    static func match(_ spoken: String, in snippets: [Snippet]) -> Snippet? {
        let key = normalized(spoken)
        guard !key.isEmpty else { return nil }
        return snippets.first { normalized($0.trigger) == key }
    }
}

struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date = Date()
    var text: String
    var raw: String
    var app: String?
    var cancelled = false
}

/// Returns the operation's value, or nil if it throws or misses the deadline.
/// Unstructured on purpose: a framework that is slow to honour cancellation can't hold the caller past the deadline.
@MainActor
func firstResult<T: Sendable>(within timeout: Duration, _ operation: @escaping @MainActor () async throws -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = Once(continuation)
        once.timer = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            once.resume(nil)
        }
        once.worker = Task { @MainActor in
            once.resume(try? await operation())
        }
    }
}

@MainActor
private final class Once<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?
    var worker: Task<Void, Never>?
    var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    func resume(_ value: T?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); worker?.cancel()
        continuation.resume(returning: value)
    }
}
