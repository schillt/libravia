// swiftc App/Core/ReaderTrackpadGesture.swift scripts/test_reader_trackpad.swift -o /tmp/libravia-trackpad && /tmp/libravia-trackpad
import Foundation
@main struct TrackpadChecks {
    static func main() {
        var gesture = ReaderTrackpadGesture()
        assert(gesture.update(x: -10, y: 0, phase: .began).consume)
        assert(gesture.update(x: -55, y: 1, phase: .changed).direction == "next")
        assert(gesture.update(x: -100, y: 0, phase: .changed).direction == nil)
        assert(gesture.update(x: -100, y: 0, phase: .momentum).direction == nil)
        assert(gesture.update(x: 70, y: 0, phase: .began).direction == "previous")
        gesture.reset()
        assert(!gesture.update(x: 1, y: 20, phase: .began).consume)
        assert(!gesture.update(x: 100, y: 30, phase: .changed).consume)
        gesture.reset()
        assert(gesture.update(x: -25, y: 0, phase: .began).direction == nil)
        assert(gesture.update(x: 0, y: 0, phase: .cancelled).direction == nil)
        assert(!gesture.update(x: 0, y: 0, phase: .momentum).consume)
        gesture.reset()
        assert(!gesture.update(x: .nan, y: 0, phase: .began).consume)
        print("PASS: deliberate strokes, one turn per gesture, momentum suppression, vertical scrolling and cancellation")
    }
}
