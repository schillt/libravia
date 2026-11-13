import XCTest
@testable import BookCore

@MainActor final class DownloadQueueTests: XCTestCase {
    func testRemovalReservationsBlockConflictingOperationsAndReleaseSafely() throws {
        let reservations = OfflineOperationReservations()
        let first = try XCTUnwrap(reservations.beginRemoval("book", scope: .server))
        XCTAssertFalse(reservations.permitsAccess("book", scope: .server))
        XCTAssertTrue(reservations.permitsAccess("book", scope: .local))
        XCTAssertNil(reservations.beginRemoval("book", scope: .server))
        reservations.clearServer()
        let next = try XCTUnwrap(reservations.beginRemoval("book", scope: .server))
        reservations.endRemoval("book", scope: .server, token: first)
        XCTAssertFalse(reservations.permitsAccess("book", scope: .server), "An old session cannot release the new reservation")
        reservations.endRemoval("book", scope: .server, token: next)
        XCTAssertTrue(reservations.permitsAccess("book", scope: .server))

        let importing = try XCTUnwrap(reservations.beginLocalImport())
        XCTAssertNil(reservations.beginRemoval("book", scope: .local))
        reservations.endLocalImport(importing)
        let removal = try XCTUnwrap(reservations.beginRemoval("book", scope: .local))
        XCTAssertNil(reservations.beginLocalImport())
        XCTAssertFalse(reservations.permitsAccess("book", scope: .local))
        reservations.endRemoval("book", scope: .local, token: removal)
        XCTAssertTrue(reservations.permitsAccess("book", scope: .local))
        XCTAssertNotNil(reservations.beginLocalImport())
    }
    private func fixture(_ id: String) -> Book {
        Book(id: id, title: "Book \(id)", author: "Author", summary: "", format: .pdf, isFolder: false, imageTag: nil, ticks: 0)
    }

    func testRestartRequeuesInFlightAndRetainsCancellation() throws {
        let namespace = "queue-test-\(UUID())"
        let queue = try OfflineDownloadJournal(namespace: namespace)
        defer { try? FileManager.default.removeItem(at: queue.root) }
        try queue.enqueue(fixture("first")); try queue.enqueue(fixture("second"))
        try queue.set("first", state: .downloading, progress: 0.5)
        try queue.set("second", state: .cancelled)
        let restored = try OfflineDownloadJournal(namespace: namespace)
        XCTAssertEqual(restored.entries.map(\.state), [.queued, .cancelled])
        XCTAssertNil(restored.entries[0].progress)
        try restored.enqueue(fixture("second"))
        XCTAssertEqual(restored.entries.map(\.state), [.queued, .queued])
        try restored.enqueue(fixture("second"))
        XCTAssertEqual(restored.entries.count, 2)
    }

    func testQueueIsSourceScopedAndDoesNotClaimPartialContent() throws {
        let first = try OfflineDownloadJournal(namespace: "queue-test-\(UUID())")
        let second = try OfflineDownloadJournal(namespace: "queue-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: first.root); try? FileManager.default.removeItem(at: second.root) }
        try first.enqueue(fixture("same-id"))
        try first.set("same-id", state: .downloading, progress: 0.73)
        XCTAssertTrue(second.entries.isEmpty)
        XCTAssertNotEqual(first.entries[0].state, .available)
        try first.set("same-id", state: .failed, failure: "Could not connect securely to the server.")
        let restored = try OfflineDownloadJournal(namespace: "unused-\(UUID())")
        defer { try? FileManager.default.removeItem(at: restored.root) }
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertEqual(first.entries[0].failure, "Could not connect securely to the server.")
        try first.remove("same-id")
        XCTAssertTrue(first.entries.isEmpty)
    }

    func testSignOutCanRemoveOnlyItsOwnDownloadJournal() throws {
        let first = try OfflineDownloadJournal(namespace: "queue-test-\(UUID())")
        let other = try OfflineDownloadJournal(namespace: "queue-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: first.root); try? FileManager.default.removeItem(at: other.root) }
        try first.enqueue(fixture("first")); try other.enqueue(fixture("other"))
        try first.delete(); try first.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.root.path))
        XCTAssertTrue(first.entries.isEmpty)
        XCTAssertEqual(other.entries.map(\.id), ["other"])
    }

    func testStaleAvailabilityCheckCannotOverwriteNewCompletion() async throws {
        let queue = try OfflineDownloadJournal(namespace: "queue-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: queue.root) }
        try queue.enqueue(fixture("same")); try queue.set("same", state: .available, progress: 1)
        var continuation: CheckedContinuation<Bool, Never>?
        let checking = Task {
            try await queue.reconcileAvailable(isAvailable: { _ in
                await withCheckedContinuation { continuation = $0 }
            }, stillCurrent: { true })
        }
        while continuation == nil { await Task.yield() }
        try queue.set("same", state: .downloading, progress: 0)
        try queue.set("same", state: .available, progress: 1)
        continuation?.resume(returning: false)
        try await checking.value
        XCTAssertEqual(queue.entries.first?.state, .available)
        try await queue.reconcileAvailable(isAvailable: { _ in false }, stillCurrent: { true })
        XCTAssertEqual(queue.entries.first?.state, .failed)
    }

    func testAccountSwitchStopsRemainingRemovalSteps() async throws {
        var current = true, removedCache = false, removedJournal = false
        var continuation: CheckedContinuation<Void, Never>?
        let removal = Task {
            try await removeAccountDeviceCopy(stillCurrent: { current },
                                              removeSaved: { await withCheckedContinuation { continuation = $0 } },
                                              removeCached: { removedCache = true },
                                              removeJournal: { removedJournal = true })
        }
        while continuation == nil { await Task.yield() }
        current = false
        continuation?.resume()
        let completed = try await removal.value
        XCTAssertFalse(completed)
        XCTAssertFalse(removedCache)
        XCTAssertFalse(removedJournal)
    }

    func testAvailabilityCheckIsDiscardedAfterAccountChange() async throws {
        let queue = try OfflineDownloadJournal(namespace: "queue-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: queue.root) }
        try queue.enqueue(fixture("same")); try queue.set("same", state: .available, progress: 1)
        var current = true
        var continuation: CheckedContinuation<Bool, Never>?
        let checking = Task {
            try await queue.reconcileAvailable(isAvailable: { _ in
                await withCheckedContinuation { continuation = $0 }
            }, stillCurrent: { current })
        }
        while continuation == nil { await Task.yield() }
        current = false
        continuation?.resume(returning: false)
        try await checking.value
        XCTAssertEqual(queue.entries.first?.state, .available)
    }
}
