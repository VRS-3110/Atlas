import Foundation

/// Scores how well a typed query matches a title, for the command palette. The characters
/// of the query must appear in order; matches at word starts, runs of consecutive letters
/// and whole-substring matches score higher. Case and accents are ignored.
public enum FuzzyMatch {

    /// Higher is better; nil when the query does not match.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(fold(candidate))
        // Word starts are read from the original text, unless folding changed its length.
        let shape = Array(candidate)
        let original = shape.count == c.count ? shape : c
        guard q.count <= c.count else { return nil }

        // The latest position each query character can take and still leave room for the
        // rest, found by matching backwards. Forward matching may then prefer word starts
        // without ever running out of candidate.
        var latest = [Int](repeating: 0, count: q.count)
        var cursor = c.count - 1
        for i in stride(from: q.count - 1, through: 0, by: -1) {
            while cursor >= 0, c[cursor] != q[i] { cursor -= 1 }
            guard cursor >= 0 else { return nil }
            latest[i] = cursor
            cursor -= 1
        }

        var score = 0
        var previous = -1
        var position = 0
        for i in q.indices {
            var chosen: Int?
            var firstMatch: Int?
            var p = position
            while p <= latest[i] {
                if c[p] == q[i] {
                    if firstMatch == nil { firstMatch = p }
                    // Keep a run going if possible, otherwise look for a word start.
                    if p == previous + 1 && previous >= 0 { chosen = p; break }
                    if isWordStart(original, p) { chosen = p; break }
                }
                p += 1
            }
            guard let match = chosen ?? firstMatch else { return nil }
            score += 10
            if isWordStart(original, match) { score += 18 }
            if previous >= 0, match == previous + 1 { score += 12 }
            if match == 0 { score += 12 }
            if previous >= 0 { score -= min(match - previous - 1, 12) }
            previous = match
            position = match + 1
        }

        let foldedQuery = fold(query).trimmingCharacters(in: .whitespaces)
        let foldedCandidate = String(c)
        if foldedCandidate == foldedQuery {
            score += 200
        } else if foldedCandidate.hasPrefix(foldedQuery) {
            score += 80
        } else if foldedCandidate.contains(foldedQuery) {
            score += 40
        }
        // Prefer shorter titles when everything else is equal.
        score -= c.count / 8
        return score
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = text[index - 1]
        let here = text[index]
        if !before.isLetter && !before.isNumber { return true }
        // camelCase and digits after letters also start a word.
        if before.isLowercase && here.isUppercase { return true }
        return before.isLetter && here.isNumber
    }
}
