// swiftc App/Readers/ReaderScreenAwake.swift scripts/test_reader_idle_timer.swift -o /tmp/libravia-idle-timer && /tmp/libravia-idle-timer
import Foundation

@main struct IdleTimerChecks {
    @MainActor static func main() {
        var changes: [Bool] = []
        let timer = ReaderIdleTimerController { changes.append($0) }
        let first = UUID(), second = UUID()
        timer.setReading(false, for: first)
        assert(changes.isEmpty, "An inactive reader must not touch the idle timer")
        timer.setReading(true, for: first)
        timer.setReading(true, for: first)
        assert(changes == [true], "Duplicate updates must be idempotent")
        timer.setReading(true, for: second)
        timer.setReading(false, for: first)
        assert(changes == [true], "Closing/backgrounding one scene must preserve another active reader")
        timer.setReading(false, for: second)
        assert(changes == [true, false], "The final reader closing or becoming inactive restores Auto-Lock")
        timer.setReading(false, for: second)
        timer.setReading(true, for: first)
        timer.setReading(false, for: first)
        assert(changes == [true, false, true, false], "Foreground resume and preference changes must acquire/release cleanly")
        print("PASS: idle timer ownership, duplicate callbacks, multiple scenes and release/reacquire")
    }
}
