import Foundation

/// One deliberate horizontal finger stroke produces one turn. Momentum never
/// advances another page, and a vertical stroke stays available for scrolling.
struct ReaderTrackpadGesture {
    enum Phase { case began, changed, ended, cancelled, momentum }
    private var x = 0.0
    private var y = 0.0
    private var horizontal = false
    private var vertical = false
    private var committed = false
    mutating func reset() { self = Self() }
    mutating func update(x dx: Double, y dy: Double, phase: Phase) -> (consume: Bool, direction: String?) {
        if phase == .began { reset() }
        if phase == .momentum { return (horizontal, nil) }
        if phase == .cancelled { let consumed = horizontal; reset(); return (consumed, nil) }
        guard dx.isFinite, dy.isFinite else { reset(); return (false, nil) }
        x += dx; y += dy
        if !horizontal && !vertical {
            if abs(x) >= 8 && abs(x) > abs(y) * 1.5 { horizontal = true }
            else if abs(y) >= 12 && abs(y) > abs(x) * 1.5 { vertical = true }
        }
        var direction: String?
        if horizontal && !committed && abs(x) >= 60 {
            committed = true; direction = x < 0 ? "next" : "previous"
        }
        return (horizontal, direction)
    }
}
