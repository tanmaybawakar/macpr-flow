import AppKit
import ApplicationServices

/// Finds words you corrected by hand in text Macpr Flow just inserted.
enum CorrectionLearner {
    struct Correction: Equatable, Hashable {
        let heard: String
        let term: String
    }

    /// `isCommonWord` keeps ordinary rewrites ("their" → "there") out of the dictionary.
    static func corrections(inserted: String, edited: String, known: Set<String>,
                            isCommonWord: (String) -> Bool) -> [Correction] {
        let a = tokens(inserted), b = tokens(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var found: [Correction] = []
        for block in substitutions(a, b) {
            let heard = block.removed.joined(separator: " ")
            guard (1...3).contains(block.removed.count) else { continue }
            let squashed = heard.lowercased().filter { $0.isLetter || $0.isNumber }
            let best = block.added
                .map { ($0, similarity(squashed, $0.lowercased().filter { $0.isLetter || $0.isNumber })) }
                .max { $0.1 < $1.1 }
            guard let (term, score) = best, term.count >= 2, term.contains(where: \.isLetter) else { continue }
            let caseOnly = heard.lowercased() == term.lowercased() && heard != term
            guard caseOnly || score >= 0.5, heard.lowercased() != term.lowercased() || caseOnly else { continue }
            let innerCaps = term.dropFirst().contains(where: \.isUppercase)
            guard innerCaps || !isCommonWord(term.lowercased()) else { continue }
            guard !known.contains(term.lowercased()) else { continue }
            found.append(Correction(heard: heard.lowercased(), term: term))
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
            var learned: Set<String> = []
            for _ in 0..<12 {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let value = Inserter.text(of: context.element) else { return }
                let window = Self.window(of: value, from: context.location, length: length)
                let found = Set(CorrectionLearner.corrections(inserted: inserted, edited: window, known: known(),
                                                              isCommonWord: Self.isCommonWord))
                for correction in found.intersection(lastSeen) where !learned.contains(correction.term) {
                    learned.insert(correction.term)
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
