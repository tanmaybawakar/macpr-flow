import Foundation

/// Applies the corrections people make out loud, instantly and on device:
/// "meet at 3, sorry, 4 pm" → "meet at 4 pm", "send it to John. Sorry, not John, Mike" → "send it to Mike",
/// "buy milk and eggs. Scratch that. Just milk" → "Just milk".
///
/// It only acts when the repair is unambiguous; anything else is left for Apple Intelligence.
enum SelfCorrection {
    nonisolated(unsafe) private static let marker = try! NSRegularExpression(
        pattern: #"(?<=^|[\s,.;:!?])(sorry|i mean|no wait|wait no|no no|or rather|make that|correction|let me rephrase|scratch that|delete that|never mind|forget that)(?=[\s,.;:!?]|$)[,.;:!?]*"#,
        options: [.caseInsensitive])

    private static let erasers: Set<String> = ["scratch that", "delete that", "never mind", "forget that"]
    /// "I'm sorry", "so sorry", "feel sorry": an apology, not a correction.
    private static let apologyLead: Set<String> = ["i'm", "im", "am", "so", "very", "really", "be", "feel", "felt",
                                                   "say", "said", "was", "were", "are", "is", "i", "too", "terribly", "awfully"]
    private static let numberWords: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                                   "nine", "ten", "eleven", "twelve", "fifteen", "twenty", "thirty", "forty",
                                                   "fifty", "hundred", "half", "noon", "midnight"]

    static func resolve(_ text: String) -> String {
        var current = text
        for _ in 0..<6 {
            guard let next = resolveFirst(current) else { break }
            current = next
        }
        return current
    }

    private static func resolveFirst(_ text: String) -> String? {
        let ns = text as NSString
        for match in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range(at: 1)).lowercased()
            let before = ns.substring(to: match.range.location)
            let after = ns.substring(from: match.range.location + match.range.length)
            if let repaired = repair(marker: word, before: before, after: after) { return repaired }
        }
        return nil
    }

    private static func repair(marker: String, before: String, after: String) -> String? {
        // Split what came before into the finished text and the sentence being corrected.
        var head = before.trimmingCharacters(in: .whitespaces)
        while let last = head.last, ",;:—-".contains(last) { head.removeLast(); head = head.trimmingCharacters(in: .whitespaces) }
        if let last = head.last, ".!?".contains(last) { head.removeLast() }
        guard !head.isEmpty else { return nil }
        let boundary = head.lastIndex(where: { ".!?\n".contains($0) })
        let prefix = boundary.map { String(head[...$0]) + (head[$0] == "\n" ? "" : " ") } ?? ""
        let sentence = String(boundary.map { head[head.index(after: $0)...] } ?? head[...]).trimmingCharacters(in: .whitespaces)
        var left = sentence.split(separator: " ").map(String.init)
        guard !left.isEmpty else { return nil }

        if marker == "sorry" || marker == "i mean" {
            if let lead = left.last.map(core), apologyLead.contains(lead) { return nil }
        }

        // What came after: the replacement, up to the end of its sentence.
        let tail = after.trimmingCharacters(in: .whitespaces)
        let end = tail.firstIndex(where: { ".!?\n".contains($0) })
        let replacementText = String(end.map { tail[...$0] } ?? tail[...]).trimmingCharacters(in: .whitespaces)
        let rest = String(end.map { tail[tail.index(after: $0)...] } ?? "").trimmingCharacters(in: .whitespaces)
        let right = replacementText.split(separator: " ").map(String.init)

        if erasers.contains(marker) {
            let kept = right.isEmpty ? "" : capitalized(right).joined(separator: " ")
            return join(prefix, kept, rest)
        }
        guard !right.isEmpty, right.contains(where: { core($0).contains(where: \.isLetter) || core($0).contains(where: \.isNumber) }) else { return nil }

        var result: [String]
        if core(right[0]) == "not", right.count >= 3 {
            // "…John. Sorry, not John, Mike." Drop the negated words, swap them where they appear.
            // The negated words run to the first comma; without one, it's a single word.
            let comma = right[1...].firstIndex { $0.hasSuffix(",") }.map { min($0, right.count - 2) } ?? 1
            let negated = Array(right[1...comma])
            let replacement = Array(right[(comma + 1)...])
            guard !replacement.isEmpty, let at = lastIndex(of: core(negated[0]), in: left) else { return nil }
            let span = min(negated.count, left.count - at)
            left.replaceSubrange(at..<(at + span), with: replacement)
            result = left
        } else if let at = lastIndex(of: core(right[0]), in: left) {
            // Restart: "go with the blue design, sorry, the red design" → from the repeated word on.
            result = Array(left[..<at]) + right
        } else if isNumber(right[0]), let at = left.lastIndex(where: { isNumber($0) }) {
            // "at 3, sorry, 4 pm": the new number takes over from the old one.
            result = Array(left[..<at]) + right
        } else if right.count <= 2, left.count > right.count {
            // "Monday, I mean Tuesday": a short swap replaces the same number of words.
            result = Array(left.dropLast(right.count)) + right
        } else {
            return nil
        }
        if sentence.first?.isUppercase == true { result = capitalized(result) }
        return join(prefix, result.joined(separator: " "), rest)
    }

    private static func join(_ prefix: String, _ middle: String, _ rest: String) -> String {
        var out = prefix + middle
        if !rest.isEmpty { out += (out.isEmpty || out.hasSuffix("\n") ? "" : " ") + rest }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func lastIndex(of word: String, in words: [String]) -> Int? {
        guard !word.isEmpty else { return nil }
        return words.lastIndex { core($0) == word }
    }

    private static func core(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
    }

    private static func isNumber(_ word: String) -> Bool {
        let c = core(word)
        return c.first?.isNumber == true || numberWords.contains(c)
    }

    private static func capitalized(_ words: [String]) -> [String] {
        guard let first = words.first else { return words }
        return [TextPolish.capitalizedFirst(first)] + words.dropFirst()
    }
}
