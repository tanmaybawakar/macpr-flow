import AppKit
import ApplicationServices

/// Finds words you corrected by hand in text Macpr Flow just inserted.
enum CorrectionLearner {
    struct Correction: Equatable, Hashable {
        let heard: String
        let term: String
        /// The heard form is an everyday word ("cloud" → "Claude"), so it must be corrected twice
        /// before every future "cloud" is rewritten. The term still joins the recognizer's vocabulary at once.
        var needsConfirmation = false

        var key: String { "\(heard)→\(term.lowercased())" }
    }

    /// `known` holds `Correction.key`s already in the dictionary, so a fix is learned once.
    /// `isCommonWord` keeps ordinary rewrites ("their" → "there") out of the dictionary.
    static func corrections(inserted: String, edited: String, known: Set<String>,
                            isCommonWord: (String) -> Bool) -> [Correction] {
        let a = tokens(inserted), b = tokens(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var found: [Correction] = []
        for block in substitutions(a, b) {
            guard (1...3).contains(block.removed.count) else { continue }
            let heard = block.removed.joined(separator: " ")
            // The replacement can be one word or a short phrase ("macro flow" → "Macpr Flow").
            var candidates: [String] = []
            for start in block.added.indices {
                for length in 1...3 where start + length <= block.added.count {
                    candidates.append(block.added[start..<start + length].joined(separator: " "))
                }
            }
            let best = candidates.map { ($0, similarity(squash(heard), squash($0))) }.max { $0.1 < $1.1 }
            guard let (term, score) = best, term.count >= 2, term.contains(where: \.isLetter) else { continue }
            let words = term.split(separator: " ").map(String.init)
            let innerCaps = words.contains { $0.dropFirst().contains(where: \.isUppercase) }
            let caseOnly = heard.lowercased() == term.lowercased() && heard != term
            let properNoun = term.first?.isUppercase == true && heard.first?.isLowercase == true
            let unusual = words.contains { !isCommonWord($0.lowercased()) }
            if caseOnly {
                guard innerCaps || unusual || words.count > 1 else { continue }
            } else {
                guard score >= 0.45, innerCaps || properNoun || unusual else { continue }
            }
            let heardIsCommon = !caseOnly && block.removed.count == 1 && isCommonWord(heard.lowercased())
            let correction = Correction(heard: heard.lowercased(), term: term, needsConfirmation: heardIsCommon)
            guard !known.contains(correction.key) else { continue }
            found.append(correction)
        }
        return found
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    private struct Block { var removed: [String] = []; var added: [String] = [] }

    /// Word-level diff (LCS), grouped into runs of removed and added words between unchanged ones.
    private static func substitutions(_ a: [String], _ b: [String]) -> [Block] {
        let la = a.map { $0.lowercased() }, lb = b.map { $0.lowercased() }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: lb.count + 1), count: la.count + 1)
        for i in stride(from: la.count - 1, through: 0, by: -1) {
            for j in stride(from: lb.count - 1, through: 0, by: -1) {
                dp[i][j] = la[i] == lb[j] && a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var blocks: [Block] = []
        var current = Block()
        var i = 0, j = 0
        func flush() {
            if !current.removed.isEmpty && !current.added.isEmpty { blocks.append(current) }
            current = Block()
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                current.added.append(b[j]); j += 1
            } else {
                current.removed.append(a[i]); i += 1
            }
        }
        flush()
        return blocks
    }

    static func similarity(_ x: String, _ y: String) -> Double {
        let a = Array(x), b = Array(y)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let saved = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = saved
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }
}

/// After a paste, watches that text field briefly. A correction that holds still for two looks is learned.
@MainActor
final class CorrectionWatcher {
    var onLearn: ((CorrectionLearner.Correction) -> Void)?
    private var task: Task<Void, Never>?

    func stop() { task?.cancel(); task = nil }

    func watch(inserted: String, at context: CaretContext, known: @escaping @MainActor () -> Set<String>) {
        stop()
        let length = inserted.utf16.count
        task = Task { @MainActor [weak self] in
            var lastSeen: Set<CorrectionLearner.Correction> = []
            var learned: Set<String> = []  // keys
            for _ in 0..<40 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let value = Inserter.text(of: context.element) else { return }
                let window = Self.window(of: value, from: context.location, length: length)
                let found = Set(CorrectionLearner.corrections(inserted: inserted, edited: window, known: known(),
                                                              isCommonWord: Self.isCommonWord))
                for correction in found.intersection(lastSeen) where !learned.contains(correction.key) {
                    learned.insert(correction.key)
                    self?.onLearn?(correction)
                }
                lastSeen = found
            }
        }
    }

    /// The edited region: where the paste started, a little past where it ended.
    private static func window(of value: String, from location: Int, length: Int) -> String {
        let utf16 = value.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: max(0, location), limitedBy: utf16.endIndex) else { return "" }
        let end = utf16.index(start, offsetBy: length + 60, limitedBy: utf16.endIndex) ?? utf16.endIndex
        return String(value[start..<end])
    }

    static func isCommonWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
}
