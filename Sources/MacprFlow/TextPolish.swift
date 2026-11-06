import Foundation

/// Deterministic text cleanup. Runs in microseconds, so short dictations never wait on a model.
enum TextPolish {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "hm", "mm", "mmm"]
    /// Words that are almost never repeated on purpose. "had had" and "that that" are left alone.
    static let stutterable: Set<String> = ["i", "the", "a", "an", "to", "and", "we", "it", "so", "is", "you",
                                           "my", "in", "on", "of", "for", "but", "this", "i'm", "it's"]

    static func basic(_ input: String, dictionary: [DictionaryEntry] = []) -> String {
        var text = spokenBreaks(input)
        text = text.components(separatedBy: "\n").map(disfluencies).joined(separator: "\n")
        text = SelfCorrection.resolve(text)
        text = applyDictionary(text, dictionary)
        return finalize(text)
    }

    // MARK: Spoken line and paragraph breaks

    nonisolated(unsafe) private static let paragraphCommand = try! NSRegularExpression(
        pattern: #"(^|[.!?,;:]\s*|\s)(?:new|next) paragraph(?:[.!?,;:]+|(?=\s)|$)"#, options: [.caseInsensitive])
    nonisolated(unsafe) private static let lineCommand = try! NSRegularExpression(
        pattern: #"(^|[.!?,;:]\s*)(?:new ?line|next line)(?:[.!?,;:]+|$)"#, options: [.caseInsensitive])

    /// "new paragraph" almost always means a break. "new line" converts only when said as its own phrase,
    /// so "a new line of products" stays literal.
    static func spokenBreaks(_ text: String) -> String {
        var s = replace(paragraphCommand, in: text, with: "$1\u{2029}")
        s = replace(lineCommand, in: s, with: "$1\u{2028}")
        guard s.contains("\u{2029}") || s.contains("\u{2028}") else { return text }
        var out = ""
        var pendingCap = false
        for ch in s {
            if ch == "\u{2029}" || ch == "\u{2028}" {
                while out.last == " " { out.removeLast() }
                if out.last == "," { out.removeLast(); out.append(".") }
                out.append(ch == "\u{2029}" ? "\n\n" : "\n")
                pendingCap = true
            } else if pendingCap && ch == " " {
                continue
            } else {
                out.append(pendingCap ? Character(String(ch).uppercased()) : ch)
                pendingCap = false
            }
        }
        return out
    }

    // MARK: Fillers and stutters

    static func disfluencies(_ line: String) -> String {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [String] = []
        var capitalizeNext = false
        for token in tokens {
            let core = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let trailing = String(token.reversed().prefix { ",.!?;:…".contains($0) }.reversed())
            if fillers.contains(core) {
                let sentenceStart = out.last.map { endsSentence($0) } ?? true
                if sentenceStart { capitalizeNext = true }
                if let end = trailing.first(where: { ".!?".contains($0) }), let last = out.last, !endsSentence(last) {
                    var previous = last
                    while let c = previous.last, ",;:".contains(c) { previous.removeLast() }
                    out[out.count - 1] = previous + String(end)
                    capitalizeNext = true
                } else if trailing.contains(","), let last = out.last, last.hasSuffix(",") {
                    out[out.count - 1].removeLast()
                }
                continue
            }
            if let previous = out.last, previous.rangeOfCharacter(from: .punctuationCharacters) == nil,
               previous.lowercased() == core, stutterable.contains(core),
               token.lowercased().hasPrefix(core) {
                let keepCase = previous.first?.isUppercase == true
                out[out.count - 1] = keepCase ? capitalizedFirst(token) : token
                continue
            }
            out.append(capitalizeNext ? capitalizedFirst(token) : token)
            capitalizeNext = false
        }
        return out.joined(separator: " ")
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return ".!?".contains(last)
    }

    /// Capitalises only all-lowercase words, so "iPhone" and "eBay" survive.
    static func capitalizedFirst(_ word: String) -> String {
        guard let first = word.first, first.isLowercase, !word.dropFirst().contains(where: \.isUppercase) else { return word }
        return first.uppercased() + word.dropFirst()
    }

    // MARK: Personal dictionary

    static func applyDictionary(_ text: String, _ entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty else { return text }
        let pairs = entries.flatMap { entry in
            ([entry.term] + entry.variants).map { ($0.trimmingCharacters(in: .whitespaces), entry.term) }
        }.filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
        var result = text
        for (spoken, term) in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            guard let regex = try? NSRegularExpression(pattern: #"(?<![\w])"# + escaped + #"(?![\w])"#, options: [.caseInsensitive]) else { continue }
            result = replace(regex, in: result, with: NSRegularExpression.escapedTemplate(for: term))
        }
        return result
    }

    // MARK: Final tidy

    static func finalize(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var s = line
            while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
            for mark in [",", ".", "!", "?", ";", ":"] { s = s.replacingOccurrences(of: " " + mark, with: mark) }
            s = s.trimmingCharacters(in: .whitespaces)
            if let firstWord = s.split(separator: " ").first {
                s = capitalizedFirst(String(firstWord)) + s.dropFirst(firstWord.count)
            }
            return s
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: When the language model earns its latency

    nonisolated(unsafe) private static let cues = try! NSRegularExpression(pattern: [
        #"\bactually\b"#, #"\bi mean\b"#, #"\bscratch that\b"#, #"\bno,? wait\b"#, #"\bwait,? no\b"#,
        #"\bsorry\b"#, #"\bor rather\b"#, #"\bmake (that|it)\b"#, #"\bcorrection\b"#, #"\bdelete that\b"#,
        #"\blet me rephrase\b"#, #"\bnew ?line\b"#, #"\bbullet( point)?\b"#, #"\bnumber (one|two|1|2)\b"#,
        #"\b(comma|full stop|question mark|exclamation (point|mark)|semicolon|open quote|close quote)\b"#,
        #"\bfirst(ly)?\b.*\bsecond(ly)?\b"#, #"\bone\b.*\btwo\b.*\bthree\b"#
    ].joined(separator: "|"), options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func needsModel(_ text: String) -> Bool {
        if wordCount(text) >= 45 { return true }
        let range = NSRange(text.startIndex..., in: text)
        return cues.firstMatch(in: text, range: range) != nil
    }

    // MARK: Guard against a model that answers, summarises or invents

    nonisolated(unsafe) private static let preface = try! NSRegularExpression(
        pattern: #"^(here('s| is)[^:\n]{0,60}:|sure[^:\n]{0,40}:|edited( dictation| text)?:|output:|result:)\s*"#,
        options: [.caseInsensitive])

    static func vetted(original: String, candidate: String) -> String? {
        var c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix("```") {
            c = c.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if c.hasSuffix("```") { c.removeLast(3) }
            c = c.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !original.lowercased().hasPrefix("here"), !original.lowercased().hasPrefix("sure") {
            c = replace(preface, in: c, with: "")
        }
        for (open, close) in [("\"", "\""), ("“", "”")] where c.count > 2 && c.hasPrefix(open) && c.hasSuffix(close) && !original.hasPrefix(open) {
            c = String(c.dropFirst().dropLast())
        }
        c = c.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return nil }

        let inWords = words(original), outWords = words(c)
        guard !outWords.isEmpty else { return nil }
        if outWords.count > Int(Double(inWords.count) * 1.35) + 4 { return nil }
        if inWords.count >= 8 && outWords.count * 2 < inWords.count { return nil }
        let known = Set(inWords)
        let free: Set<String> = ["a", "an", "the", "is", "are", "was", "to", "of", "and", "i", "it", "that",
                                 "s", "m", "re", "ve", "ll", "d", "t", "be", "will", "do", "does"]
        let novel = outWords.filter { !known.contains($0) && !free.contains($0) && Int($0) == nil }
        if Double(novel.count) > max(2, Double(outWords.count) * 0.2) { return nil }
        // Editing never introduces a new name. "The capital of France is Paris" is an answer, not an edit.
        let novelSet = Set(novel)
        let introducesName = c.split { !$0.isLetter && !$0.isNumber }.contains { word in
            word.first?.isUppercase == true && novelSet.contains(word.lowercased())
        }
        if introducesName { return nil }
        return c
    }

    private static let numberWords = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                      "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber }
            .map { numberWords[String($0)] ?? String($0) }
    }

    static func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Adds the space a person would type between what is already there and the new text.
enum Spacing {
    static func adjust(_ text: String, after previous: Character?) -> String {
        guard let previous, let first = text.first else { return text }
        if previous.isWhitespace || "([{\"'“‘/-".contains(previous) { return text }
        if ".,!?;:)]}".contains(first) || first.isWhitespace { return text }
        return " " + text
    }
}
