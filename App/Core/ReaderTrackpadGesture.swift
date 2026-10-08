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

/// Finger-driven strokes commit on release; peeking and reversal stay provisional.
struct ReaderTrackpadInteraction {
    struct Update { let phase: String; let translation: Double; let velocity: Double; let commit: Bool }
    private var x = 0.0, y = 0.0, time = 0.0, velocity = 0.0
    private var horizontal = false, vertical = false, started = false, ended = false
    private var direction = 0.0
    mutating func reset() { self = Self() }
    mutating func update(x dx: Double, y dy: Double, timestamp: Double, width: Double,
                         phase: ReaderTrackpadGesture.Phase) -> (consume: Bool, update: Update?) {
        if phase == .began { reset() }
        if phase == .momentum { return (horizontal, nil) }
        guard dx.isFinite, dy.isFinite, timestamp.isFinite, width > 0 else { reset(); return (false, nil) }
        if ended { return (horizontal, nil) }
        let scaled = dx * 3
        x += scaled; y += dy * 3
        if time > 0 && timestamp > time {
            if phase != .ended || scaled != 0 { velocity = scaled / max(0.008, timestamp - time) }
            else if timestamp - time > 0.12 { velocity = 0 }
        }
        time = timestamp
        if !horizontal && !vertical {
            if abs(x) >= 24 && abs(x) > abs(y) * 1.5 { horizontal = true; direction = x < 0 ? -1 : 1 }
            else if abs(y) >= 36 && abs(y) > abs(x) * 1.5 { vertical = true }
        }
        guard horizontal else { return (false, nil) }
        let displacement = direction * max(0, min(width, x * direction))
        if phase == .cancelled || phase == .ended {
            ended = true
            let commit = phase != .cancelled && (x * direction >= width * 0.18 || (x * direction > 24 && velocity * direction > 650))
            return (true, Update(phase: "end", translation: displacement, velocity: velocity, commit: commit))
        }
        let name = started ? "change" : "begin"; started = true
        return (true, Update(phase: name, translation: displacement, velocity: velocity, commit: false))
    }
}
