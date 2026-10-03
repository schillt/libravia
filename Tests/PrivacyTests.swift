import XCTest
@testable import BookCore

private final class PrivacyURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class PrivacyTests: XCTestCase {
    private func provider(server: String = "https://example.invalid/base", authenticated: Bool = true) -> JellyfinProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivacyURLProtocol.self]
        let account = Account(server: URL(string: server)!, userID: "user", serverID: "server", username: "reader", token: "fixture-token")
        return JellyfinProvider(account: authenticated ? account : nil, configuration: config)
    }
    override func tearDown() { PrivacyURLProtocol.handler = nil; super.tearDown() }

    func testUserFacingErrorsNeverRevealSystemOrServerPayloads() {
        let privateError = NSError(domain: NSURLErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "private-path-and-token"])
        XCTAssertFalse(UserFacingError.message(privateError).contains("private-path-and-token"))
        let decodingError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private-response-data"))
        XCTAssertFalse(UserFacingError.message(decodingError).contains("private-response-data"))
        XCTAssertEqual(UserFacingError.message(JellyfinAuthenticationError.unauthorized), JellyfinAuthenticationError.unauthorized.localizedDescription)
        XCTAssertEqual(UserFacingError.message(ReaderError.message("Close this book first.")), "Close this book first.")
    }
    func testAccountIsolationIncludesServerEndpointAndUser() {
        let original = Account(server: URL(string: "https://example.invalid/base")!, userID: "same-user", serverID: "cloned-server", username: "reader", token: "fixture")
        var other = original
        other.server = URL(string: "https://other.invalid/base")!
        XCTAssertNotEqual(original.namespace, other.namespace)
        other.server = URL(string: "https://example.invalid/other-base")!
        XCTAssertNotEqual(original.namespace, other.namespace)
        other = original; other.userID = "another-user"
        XCTAssertNotEqual(original.namespace, other.namespace)
        other = original; other.server = URL(string: "https://EXAMPLE.invalid:443/base/")!
        XCTAssertEqual(original.namespace, other.namespace)
    }
    func testDirectLoginRejectsUnsafeDestinationBeforeTransport() async {
        PrivacyURLProtocol.handler = { _ in XCTFail("Unsafe destination reached transport"); return (500, Data()) }
        for address in ["http://example.invalid", "https://name:secret@example.invalid", "https://example.invalid?api_key=secret", "https://example.invalid/#fragment"] {
            do { _ = try await provider(authenticated: false).login(server: URL(string: address)!, username: "reader", password: "fixture"); XCTFail("Expected validation failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
        }
    }
    func testRestoredUnsafeAccountCannotSendToken() async {
        PrivacyURLProtocol.handler = { _ in XCTFail("Unsafe restored account reached transport"); return (200, Data()) }
        do { try await provider(server: "http://example.invalid").validate(); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Connect")) }
    }
    func testUnauthorizedIsTypedAndDoesNotExposeResponseBody() async {
        PrivacyURLProtocol.handler = { _ in (401, Data("private server detail".utf8)) }
        do { try await provider().validate(); XCTFail("Expected failure") }
        catch {
            XCTAssertTrue(error is JellyfinAuthenticationError)
            XCTAssertFalse(error.localizedDescription.contains("private server detail"))
        }
    }
    func testProfileWithoutImageSkipsImageRequest() async throws {
        var count = 0
        PrivacyURLProtocol.handler = { _ in count += 1; return (200, Data(#"{"Id":"user","Name":"reader"}"#.utf8)) }
        let result = try await provider().profileImage()
        XCTAssertNil(result)
        XCTAssertEqual(count, 1)
    }
    func testProfileImageUsesAuthenticatedSDKEndpoint() async throws {
        PrivacyURLProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=fixture-token") == true)
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
            if request.url!.path.hasSuffix("UserImage") { return (200, Data([1, 2, 3])) }
            return (200, Data(#"{"Id":"user","PrimaryImageTag":"image-tag"}"#.utf8))
        }
        let result = try await provider().profileImage()
        XCTAssertEqual(result, Data([1, 2, 3]))
    }
    func testProfileImageRemovedAfterUserLookupReturnsNil() async throws {
        PrivacyURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("UserImage") { return (404, Data()) }
            return (200, Data(#"{"Id":"user","PrimaryImageTag":"stale-tag"}"#.utf8))
        }
        let result = try await provider().profileImage()
        XCTAssertNil(result)
    }
    func testSignOutUsesOfficialSDKTokenRevocation() async throws {
        var count = 0
        PrivacyURLProtocol.handler = { request in
            count += 1
            XCTAssertEqual(request.httpMethod, "DELETE")
            // SDK 3.1.0 revokes via a token-bearing path: proxy logs need redaction.
            XCTAssertEqual(request.url?.path, "/base/Auth/Keys/fixture-token")
            return (204, Data())
        }
        try await provider().signOut()
        XCTAssertEqual(count, 1)
    }
    func testRedirectDelegateRejectsCredentialForwarding() {
        let original = URL(string: "https://example.invalid")!
        let redirected = URLRequest(url: URL(string: "https://other.invalid")!)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        NoRedirect().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { XCTAssertNil($0) }
        DownloadObserver { _ in }.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { XCTAssertNil($0) }
    }
}
