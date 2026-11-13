import XCTest
final class CurlTests: XCTestCase {
 func testColdPreviewSwipe() {
   let app = XCUIApplication(); app.launchArguments = ["interactive", "rapid", "cold"]; app.launch()
   XCTAssertTrue(app.staticTexts["Page 0 front"].waitForExistence(timeout: 10))
   let root = app.windows.firstMatch
   root.tap()
   XCTAssertTrue(app.staticTexts["Page 0 front"].exists, "tap does not turn")
   root.swipeUp()
   XCTAssertTrue(app.staticTexts["Page 0 front"].exists, "vertical motion does not turn")
   root.swipeLeft()
   XCTAssertTrue(app.staticTexts["drained"].waitForExistence(timeout: 12))
   XCTAssertTrue(app.staticTexts["Page 2 front"].waitForExistence(timeout: 5), "cold preview must not drop the swipe")
 }
 func testRapidDuringNativeSettle() {
   let app = XCUIApplication(); app.launchArguments = ["interactive", "rapid"]; app.launch()
   XCTAssertTrue(app.staticTexts["Page 0 front"].waitForExistence(timeout: 10))
   let root = app.windows.firstMatch
   root.swipeLeft()
   let start = root.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.5))
   let short = root.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
   start.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.2)
   root.swipeRight()
   root.swipeRight()
   root.swipeLeft()
   XCTAssertTrue(app.staticTexts["queued 3"].waitForExistence(timeout: 2), "cancelled short drag must not queue; three full swipes must queue")
   XCTAssertTrue(app.staticTexts["drained"].waitForExistence(timeout: 20), "wait for the complete FIFO to drain")
   XCTAssertTrue(app.staticTexts["Page 2 front"].waitForExistence(timeout: 5), "ordered reverse, boundary, forward must finish on page 2")
 }
 func testInteractiveCurlAndCancellation() {
   let app = XCUIApplication(); app.launchArguments = ["interactive"]; app.launch()
   XCTAssertTrue(app.staticTexts["Page 0 front"].waitForExistence(timeout: 10))
   let root = app.windows.firstMatch
   let start = root.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.5))
   let short = root.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5))
   start.press(forDuration: 0.2, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.8)
   XCTAssertTrue(app.staticTexts["transition cancelled"].waitForExistence(timeout: 5), "UIKit must report actual cancellation")
   XCTAssertTrue(app.staticTexts["Page 0 front"].waitForExistence(timeout: 5), "cancel preserves current page")
   root.swipeLeft()
   XCTAssertTrue(app.staticTexts["Page 2 front"].waitForExistence(timeout: 5), "forward reaches next front")
   root.swipeRight()
   XCTAssertTrue(app.staticTexts["Page 0 front"].waitForExistence(timeout: 5), "reverse returns to origin")
 }
}
