import Foundation

/// Undo/redo stack for the editor — a port of Recordly's `editorHistory.ts`. Holds a
/// `past` list, the `current` snapshot, and a `future` (redo) list. `record` pushes the
/// previous current onto `past` and clears the redo list; `undo`/`redo` move snapshots
/// between the lists. Bounded to `maxEntries` (oldest dropped), matching Recordly's 100.
struct EditorHistory<Snapshot: Equatable> {
    static var maxEntries: Int { 100 }

    enum RecordResult: Equatable { case initialized, applied, recorded, unchanged }

    private(set) var past: [Snapshot] = []
    private(set) var current: Snapshot?
    private(set) var future: [Snapshot] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    mutating func reset() { past = []; current = nil; future = [] }

    /// Records a new snapshot. Returns how it was handled (mirrors Recordly's result enum):
    /// `initialized` (first ever), `applied` (during undo/redo replay), `unchanged`
    /// (identical to current), or `recorded` (a real new edit).
    @discardableResult
    mutating func record(_ snapshot: Snapshot,
                         applyingHistory: Bool = false,
                         maxEntries: Int = EditorHistory.maxEntries) -> RecordResult {
        guard let cur = current else { current = snapshot; return .initialized }
        if applyingHistory { current = snapshot; return .applied }
        if cur == snapshot { return .unchanged }
        past.append(cur)
        if past.count > maxEntries { past.removeFirst() }
        current = snapshot
        future = []
        return .recorded
    }

    /// Steps back one snapshot, moving the current onto the redo list. Nil if nothing to undo.
    mutating func undo(fallbackCurrent: Snapshot) -> Snapshot? {
        guard !past.isEmpty else { return nil }
        let cur = current ?? fallbackCurrent
        let previous = past.removeLast()
        future.append(cur)
        current = previous
        return previous
    }

    /// Steps forward one snapshot, moving the current onto the past list. Nil if nothing to redo.
    mutating func redo(fallbackCurrent: Snapshot) -> Snapshot? {
        guard !future.isEmpty else { return nil }
        let cur = current ?? fallbackCurrent
        let next = future.removeLast()
        past.append(cur)
        current = next
        return next
    }
}
