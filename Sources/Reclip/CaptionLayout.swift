import Foundation

/// Word-level caption layout for karaoke highlighting + line wrapping — a port of
/// Recordly's `captionLayout.ts` (`buildActiveCaptionLayout`). Each word is tagged with a
/// state relative to the current time (already-spoken / currently-active / upcoming), and
/// the words are wrapped into lines, returning a rolling window of up to `maxRows` lines
/// centered on the active word (so long captions scroll rather than overflow).
enum CaptionWordState: Equatable { case spoken, active, upcoming }

struct LaidOutWord: Equatable {
    var text: String
    var startMs: Int
    var endMs: Int
    var state: CaptionWordState
}

struct CaptionLine: Equatable {
    var words: [LaidOutWord]
    var text: String { words.map(\.text).joined(separator: " ") }
}

enum CaptionLayout {
    /// Index of the word active at `timeMs`; if none is active, the last word that has
    /// already started (Recordly's fallback), or -1 when there are no words.
    static func activeWordIndex(_ words: [CaptionWord], timeMs: Int) -> Int {
        guard !words.isEmpty else { return -1 }
        if let i = words.firstIndex(where: { timeMs >= $0.startMs && timeMs < $0.endMs }) { return i }
        if let next = words.firstIndex(where: { timeMs < $0.startMs }) {
            return max(0, min(next - 1, words.count - 1))
        }
        return words.count - 1
    }

    static func build(words: [CaptionWord], timeMs: Int,
                      maxCharsPerLine: Int = 42, maxRows: Int = 2) -> [CaptionLine] {
        guard !words.isEmpty else { return [] }
        let maxChars = max(1, maxCharsPerLine)
        let rows = max(1, maxRows)
        let active = activeWordIndex(words, timeMs: timeMs)

        let laid: [LaidOutWord] = words.enumerated().map { i, w in
            let state: CaptionWordState = i < active ? .spoken : (i == active ? .active : .upcoming)
            return LaidOutWord(text: w.text, startMs: w.startMs, endMs: w.endMs, state: state)
        }

        // Greedy wrap by character count.
        var lines: [CaptionLine] = []
        var current: [LaidOutWord] = []
        var len = 0
        for w in laid {
            let add = w.text.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty, len + add > maxChars {
                lines.append(CaptionLine(words: current)); current = []; len = 0
            }
            current.append(w); len += w.text.count + (current.count > 1 ? 1 : 0)
        }
        if !current.isEmpty { lines.append(CaptionLine(words: current)) }

        // Rolling window of `rows` lines centered on the active word's line.
        guard lines.count > rows else { return lines }
        var activeLine = 0
        outer: for (li, line) in lines.enumerated() {
            for w in line.words where w.state == .active { activeLine = li; break outer }
        }
        let start = max(0, min(activeLine - rows / 2, lines.count - rows))
        return Array(lines[start..<start + rows])
    }
}
