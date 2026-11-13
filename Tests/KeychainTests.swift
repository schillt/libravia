import XCTest
import Security
@testable import BookCore

final class KeychainTests: XCTestCase {
    private final class Fake {
        var calls: [(String, [String: Any])] = []
        var data: Data?
        var copyStatus: OSStatus = errSecItemNotFound
        var updateStatus: OSStatus = errSecItemNotFound
        var addStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        var updated: [String: Any] = [:]
        var backend: CredentialKeychainBackend {
            CredentialKeychainBackend(copy: { [self] query in
                calls.append(("copy", query)); return (copyStatus, data as CFTypeRef?)
            }, update: { [self] query, attributes in
                calls.append(("update", query)); updated = attributes; return updateStatus
            }, add: { [self] query in calls.append(("add", query)); return addStatus },
               delete: { [self] query in calls.append(("delete", query)); return deleteStatus })
        }
    }
    private let account = Account(server: URL(string: "https://example.invalid")!, userID: "user", serverID: "server", username: "Synthetic", token: "synthetic")
    private func assertProtected(_ query: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true, file: file, line: line)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, file: file, line: line)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "JellyfinBooks.account", file: file, line: line)
    }
    func testMissingModernCredentialDoesNotReadOrChangeLegacyItems() throws {
        let fake = Fake()
        XCTAssertNil(try CredentialStore.load(using: fake.backend))
        XCTAssertEqual(fake.calls.map(\.0), ["copy"])
        assertProtected(fake.calls[0].1)
    }
    func testRestoreReadsModernCredentialWithoutRewritingIt() throws {
        let fake = Fake(); fake.copyStatus = errSecSuccess; fake.data = try JSONEncoder().encode(account)
        let result = try XCTUnwrap(CredentialStore.load(using: fake.backend))
        XCTAssertEqual(result.namespace, account.namespace)
        XCTAssertEqual(result.token, account.token)
        XCTAssertEqual(fake.calls.map(\.0), ["copy"])
        assertProtected(fake.calls[0].1)
    }
    func testReadFailuresDoNotFallBackOrWrite() throws {
        for status in [errSecInteractionNotAllowed, errSecMissingEntitlement] {
            let fake = Fake(); fake.copyStatus = status
            XCTAssertThrowsError(try CredentialStore.load(using: fake.backend))
            XCTAssertEqual(fake.calls.map(\.0), ["copy"]); assertProtected(fake.calls[0].1)
        }
        let corrupt = Fake(); corrupt.copyStatus = errSecSuccess; corrupt.data = Data("bad".utf8)
        XCTAssertThrowsError(try CredentialStore.load(using: corrupt.backend))
        XCTAssertEqual(corrupt.calls.map(\.0), ["copy"])
    }
    func testSaveUpdatesOrAddsOnlyProtectedDeviceLocalCredential() throws {
        let existing = Fake(); existing.updateStatus = errSecSuccess
        try CredentialStore.save(account, using: existing.backend)
        XCTAssertEqual(existing.calls.map(\.0), ["update"]); assertProtected(existing.calls[0].1)
        XCTAssertEqual(existing.updated[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let fresh = Fake(); try CredentialStore.save(account, using: fresh.backend)
        XCTAssertEqual(fresh.calls.map(\.0), ["update", "add"])
        for call in fresh.calls { assertProtected(call.1) }
        XCTAssertEqual(fresh.calls[1].1[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let denied = Fake(); denied.updateStatus = errSecMissingEntitlement
        XCTAssertThrowsError(try CredentialStore.save(account, using: denied.backend))
        XCTAssertEqual(denied.calls.map(\.0), ["update"])
    }
    func testDeleteOnlyTargetsModernStoreAndReportsErrors() throws {
        let fake = Fake(); try CredentialStore.delete(using: fake.backend)
        XCTAssertEqual(fake.calls.map(\.0), ["delete"]); assertProtected(fake.calls[0].1)
        let denied = Fake(); denied.deleteStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try CredentialStore.delete(using: denied.backend))
        XCTAssertEqual(denied.calls.map(\.0), ["delete"]); assertProtected(denied.calls[0].1)
    }
}
