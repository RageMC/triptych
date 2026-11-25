// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

final class MacAppHostUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHostedMacAppLaunchesAndHandlesTaps() throws {
        let app = XCUIApplication()
        app.launch()
        verifyAndTap(app: app)
    }

    /// Attaches to an already-running MacAppHost instance (e.g. launched via `xcrun simctl launch --console`)
    /// so stderr output from the running process can be observed directly on the console.
    func testTapRunningMacAppHost() throws {
        let app = XCUIApplication(bundleIdentifier: "app.triptych.MacAppHost")
        app.activate()
        verifyAndTap(app: app)
    }

    private func verifyAndTap(app: XCUIApplication) {
        let windowTitle = app.staticTexts["NSWindowTitle"]
        XCTAssertTrue(windowTitle.waitForExistence(timeout: 15), "NSWindow title should appear")
        XCTAssertEqual(windowTitle.label, "TestMacApp")

        let status = app.staticTexts["host-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Running TestMacApp"), "Unexpected status: \(status.label)")

        let button = app.buttons["NSButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "NSButton should appear")
        XCTAssertTrue(button.label.contains("Click Me"), "Unexpected button label: \(button.label)")

        button.tap()
        let clickedPredicate = NSPredicate(format: "label CONTAINS 'Click Me (1)' OR label CONTAINS 'Click Me ('")
        let exp = XCTNSPredicateExpectation(predicate: clickedPredicate, object: button)
        wait(for: [exp], timeout: 5)
        XCTAssertFalse(button.label == "Click Me (0)", "Button count should increment after tap, got: \(button.label)")

        // Tap the Metal triangle view area inside the NSWindow to trigger mouseDown:.
        let container = app.otherElements["mac-window-container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        let metalPoint = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        metalPoint.tap()
        sleep(1)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "macapphost-after-taps"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
