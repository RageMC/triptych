// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Triptych

final class RelaunchTests: XCTestCase {
    private let key = "triptych.relaunch.open"
    private var savedLC: String?

    override func setUp() {
        savedLC = getenv("LC_HOME_PATH").map { String(cString: $0) }
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let s = savedLC { setenv("LC_HOME_PATH", s, 1) } else { unsetenv("LC_HOME_PATH") }
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testTakePendingReturnsKindOnce() {
        UserDefaults.standard.set(EngineKind.linux.rawValue, forKey: key)
        XCTAssertEqual(Relaunch.takePending(), .linux)
        XCTAssertNil(Relaunch.takePending())
    }

    func testTakePendingIgnoresUnknownValue() {
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertNil(Relaunch.takePending())
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testRelaunchURLInLiveContainer() throws {
        setenv("LC_HOME_PATH", "/tmp/lc", 1)
        let url = try XCTUnwrap(Relaunch.relaunchURL)
        XCTAssertEqual(url.scheme, "livecontainer")
        XCTAssertEqual(url.host, "livecontainer-launch")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first?.name, "bundle-name")
        XCTAssertEqual(items?.first?.value, Relaunch.bundleFolderName)
    }

    func testRelaunchURLOutsideLiveContainerUsesStikDebug() throws {
        unsetenv("LC_HOME_PATH")
        let url = try XCTUnwrap(Relaunch.relaunchURL)
        XCTAssertEqual(url.scheme, "stikdebug")
        XCTAssertEqual(url.host, "enable-jit")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first?.name, "bundle-id")
        XCTAssertEqual(items?.first?.value, Relaunch.bundleID)
    }
}
