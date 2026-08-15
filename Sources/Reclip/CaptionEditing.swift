import Foundation

/// A single timed word within a caption cue — the unit karaoke-style word highlighting
/// animates. Times are in milliseconds; `leadingSpace` records whether the word was
/// preceded by a space (so the cue text can be reconstructed).
struct CaptionWord: Equatable {
    var text: String
    var startMs: Int
    var endMs: Int
    var leadingSpace: Bool
}

/// Caption text/word editing — a port of Recordly's `captionEditing.ts`. `normalizeText`
/// trims and collapses whitespace; `buildWords` distributes a cue's tokens evenly across
/// its time range with monotonic, non-overlapping per-word timings.
enum CaptionEditing {
    /// Trims surrounding whitespace and collapses internal runs to single spaces.
    static func normalizeText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Splits `text` into per-word cues spread across [startMs, endMs]. Each word gets at
    /// least 1ms, words never overlap, and the last word ends exactly at `endMs`.
    static func buildWords(text: String, startMs: Double, endMs: Double) -> [CaptionWord] {
        let tokens = normalizeText(text).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let start = max(0, startMs.rounded())
        let end = max(start + 1, endMs.rounded())
        let duration = end - start
        let n = Double(tokens.count)
        return tokens.enumerated().map { index, token in
            let i = Double(index)
            let wordStart = min(end - 1, max(start, (start + duration * i / n).rounded()))
            let nextBoundary = index == tokens.count - 1
                ? end
                : (start + duration * (i + 1) / n).rounded()
            let wordEnd = min(end, max(wordStart + 1, nextBoundary))
            return CaptionWord(text: token, startMs: Int(wordStart),
                               endMs: Int(wordEnd), leadingSpace: index > 0)
        }
    }
}
