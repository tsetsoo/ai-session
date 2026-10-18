import Foundation

/// Fuzzy match for the command palette.
public enum PaletteMatcher {
    /// Case- and diacritic-insensitive subsequence match; higher is better, `nil` is no match.
    /// Rewards a prefix, word starts and consecutive characters, and penalises gaps.
    public static func score(query: String, candidate: String) -> Int? {
        let q = Array(fold(query))
        let c = Array(fold(candidate))
        guard !q.isEmpty else { return 0 }
        var score = 0
        var ci = 0
        var previous = -2
        for ch in q {
            guard let hit = c[ci...].firstIndex(of: ch) else { return nil }
            if hit == 0 { score += 30 }
            else if !c[hit - 1].isLetter && !c[hit - 1].isNumber { score += 10 }
            if hit == previous + 1 { score += 15 }
            score -= hit - ci
            previous = hit
            ci = hit + 1
        }
        return score
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
