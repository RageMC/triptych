// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Triptych

final class LaunchSharingTests: XCTestCase {
    func testEveryShareablePairCanStartInEitherOrder() {
        for pair in SessionState.canShareLaunch {
            let kinds = Array(pair)
            XCTAssertEqual(kinds.count, 2)
            for (first, second) in [(kinds[0], kinds[1]), (kinds[1], kinds[0])] {
                let s = SessionState()
                XCTAssertTrue(s.canStart(first))
                s.markStarted(first)
                XCTAssertTrue(s.canStart(second), "\(first) then \(second)")
                s.markStarted(second)
                XCTAssertEqual(s.started, pair)
                XCTAssertEqual(s.activeEngine, first)
            }
        }
    }

    func testUnlistedPairIsRefused() {
        let s = SessionState()
        s.markStarted(.windows)
        XCTAssertFalse(s.canStart(.macos))
        XCTAssertTrue(s.canStart(.windows))
    }

    func testForbiddenTriple() {
        let s = SessionState()
        s.markStarted(.linux)
        s.markStarted(.winpc)
        XCTAssertFalse(s.canStart(.macapps))
        XCTAssertFalse(SessionState.canShareLaunch.contains([.linux, .winpc, .macapps]))
    }
}
