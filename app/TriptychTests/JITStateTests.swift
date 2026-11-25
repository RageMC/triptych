// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Triptych

/// Settings' JIT Status and the setup sheet read one answer (JITBootstrap.state). The bug it fixes: inside LiveContainer
/// on a TXM iPad a debugger traces Henge from launch, the sheet said "JIT is on. a Mac can start." while Status said Off.
final class JITStateTests: XCTestCase {
    typealias S = JITBootstrap.JITState

    func testTracedOnTXMWithoutRegionIsNotOn() {
        // The device's case: CS_DEBUGGED set, traced (LiveContainer's attach), TXM, region not held yet.
        let s = JITBootstrap.state(ready: false, debugged: true, traced: true, txm: true, failure: nil)
        XCTAssertEqual(s, .claiming)
        XCTAssertNotEqual(JITBootstrap.statusText(s), "On")
        XCTAssertNotEqual(s, .on, "the sheet must not say JIT is on before the region is held")
    }

    func testFailedClaimIsShownEverywhere() {
        let why = "The debugger is attached but is not answering trap requests"
        let s = JITBootstrap.state(ready: false, debugged: true, traced: true, txm: true, failure: why)
        XCTAssertEqual(s, .failed(why))
        XCTAssertTrue(JITBootstrap.statusText(s).hasPrefix("Off"))
    }

    func testHeldRegionIsOn() {
        XCTAssertEqual(JITBootstrap.state(ready: true, debugged: true, traced: false, txm: true, failure: nil), .on)
        XCTAssertEqual(JITBootstrap.statusText(.on), "On")
    }

    func testStaleDebuggedFlagOnTXMIsOff() {
        // CS_DEBUGGED stays set after a debugger lets go; without a tracer nothing can claim the region.
        XCTAssertEqual(JITBootstrap.state(ready: false, debugged: true, traced: false, txm: true, failure: nil), .off)
    }

    func testNothingAttachedIsOff() {
        XCTAssertEqual(JITBootstrap.state(ready: false, debugged: false, traced: false, txm: false, failure: nil), .off)
    }
}

final class LogExportTests: XCTestCase {
    func testLogNames() {
        for n in ["henge.log", "henge-native-prev.log", "madeira-log.txt", "madeira-log.prev.txt", "madeira-summary.txt",
                  "madeira-last-game-log.txt", "serial.log", "serial-prev.log", "stderr.log", "triptych-prev.log", "henge-env.txt"] {
            XCTAssertTrue(LogExport.isLog(n), n)
        }
        for n in ["disk.img", "QEMU_VARS.fd", "notes.txt", "Hello (C)"] { XCTAssertFalse(LogExport.isLog(n), n) }
    }

    func testArchiveHoldsEveryLogAndDeviceInfo() throws {
        TriptychLog.start()
        TriptychLog.log("test", "archive test line")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pc = docs.appendingPathComponent("x86pc", isDirectory: true)
        try FileManager.default.createDirectory(at: pc, withIntermediateDirectories: true)
        try Data("serial line\n".utf8).write(to: pc.appendingPathComponent("serial-prev.log"))
        let names = LogExport.collect().map(\.name)
        XCTAssertTrue(names.contains("Documents__Logs__triptych.log"), "\(names)")
        XCTAssertTrue(names.contains("Documents__x86pc__serial-prev.log"), "\(names)")
        let r = try LogExport.makeArchive()
        XCTAssertEqual(r.zip.pathExtension, "zip")
        let data = try Data(contentsOf: r.zip)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4b], "a zip archive")
        XCTAssertGreaterThanOrEqual(r.files, 3)
    }

    func testRotateKeepsPreviousRun() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("serial.log")
        try Data("run 1".utf8).write(to: f)
        TriptychLog.rotate(f)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertEqual(try String(contentsOf: d.appendingPathComponent("serial-prev.log"), encoding: .utf8), "run 1")
    }
}

final class SessionStateTests: XCTestCase {
    func testWindowsPCAndMacAppsCanStartInEitherOrder() {
        for (first, second): (EngineKind, EngineKind) in [(.winpc, .macapps), (.macapps, .winpc)] {
            let session = SessionState()
            XCTAssertTrue(session.canStart(first))
            session.markStarted(first)
            XCTAssertTrue(session.canStart(second))
            session.markStarted(second)
            XCTAssertEqual(session.activeEngine, first)
            XCTAssertTrue(session.canStart(first))
            XCTAssertTrue(session.canStart(second))
            XCTAssertFalse(session.canStart(.linux))
        }
    }

    func testAnExclusiveSystemBlocksWindowsPCAndMacApps() {
        let session = SessionState()
        session.markStarted(.macos) // the Mac VM shares a launch with nothing
        XCTAssertFalse(session.canStart(.winpc))
        XCTAssertFalse(session.canStart(.macapps))
    }
}
