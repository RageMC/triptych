// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// One JIT method and one script for the whole app (StikJIT's integration
/// rules: exactly one developer-defined script per app, no silent fallback).
/// The script is Madeira's, a superset of Henge's protocol:
/// brk #0xf00d with x16 = 0 (detach), 1 (prepare RX region), 2 (map page zero).
enum JIT {
    static var isEnabled: Bool { tp_process_is_debugged() }

    static var scriptBase64: String? {
        guard let url = Bundle.main.url(forResource: "triptych-jit", withExtension: "js"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }

    /// Opens StikDebug's canonical enable-jit URL for this process.
    static func requestFromStikDebug() {
        var c = URLComponents()
        c.scheme = "stikdebug"; c.host = "enable-jit"
        var q = [URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier),
                 URLQueryItem(name: "pid", value: String(getpid()))]
        if let s = scriptBase64 { q.append(URLQueryItem(name: "script-data", value: s)) }
        c.queryItems = q
        if let url = c.url { UIApplication.shared.open(url) }
    }

    static var isInLiveContainer: Bool { getenv("LC_HOME_PATH") != nil }
}
