# Native curl fixture

This disposable UIKit app uses synthetic pages and no book or account data. Its XCTest disables native tap-to-turn recognizers, asserts that a partial drag produces a delegate-reported cancellation, then checks forward and reverse front-page navigation. The odd-numbered pages are colored backs; the even-numbered pages are fronts. It does not exercise live WebKit ownership, rapid overlapping gestures, or a physical device.

Run on an iOS simulator using Xcode, replacing the destination ID with an available simulator:

```sh
xcodebuild -project scripts/native-curl-fixture/CurlFixture.xcodeproj -scheme CurlFixture \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/libravia-native-curl-fixture -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

The fixture initializes an edge-spine, double-sided controller with one unanimated front page. Its optional launch argument `two` instead tries two initial unanimated pages; on iOS 27.0 this raised an invalid-argument exception demanding one. Default (non-test) startup follows initial setup with animated forward and reverse calls using front/back pairs. Optional `slow` slows that animation for screenshot inspection. These findings are scoped to the tested runtime; Apple documents a front/back pair for animated double-sided edge-spine transitions.

The fixture also models an exclusive catch-up recognizer after the native pan ends. It slows native animation only in that diagnostic mode, checks that three rapid reverse/boundary/forward requests enter the queue while a short cancelled drag does not, waits for the queue to drain, and verifies the final page. A separate cold-preview case exercises the fallback path. These are synthetic ownership tests; the fixture does not exercise the production WebKit guard, renderer acknowledgements, or actual reader visuals.

Before running XCTest, check that its copied `ReaderCurlCatchUpPan` remains identical to production:

```sh
python3 scripts/native-curl-fixture/check-recognizer.py
```

The fixture mirrors the ownership release policy, but not EPUB WebKit guard and acknowledgement behavior. It also checks a quick tap and vertical gesture before a cold horizontal swipe; neither non-horizontal input should turn a page.
