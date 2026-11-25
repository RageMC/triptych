// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ObjectiveC

/// StikJIT allows exactly one JIT script per app, so Triptych bundles only triptych-jit.js (Madeira's superset of
/// Henge's protocol). Henge's JITBootstrap looks the script up as "henge-jit.js" in the main bundle; this makes that
/// lookup resolve to triptych-jit.js instead of shipping a second copy (a resource alias that avoids editing upstream).
enum JITScriptAlias {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = Bundle.self
        swap(cls, #selector(Bundle.path(forResource:ofType:)), #selector(Bundle.tp_path(forResource:ofType:)))
        swap(cls, #selector(Bundle.path(forResource:ofType:inDirectory:)), #selector(Bundle.tp_path(forResource:ofType:inDirectory:)))
    }

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let m1 = class_getInstanceMethod(cls, a), let m2 = class_getInstanceMethod(cls, b) else { return }
        method_exchangeImplementations(m1, m2)
    }
}

extension Bundle {
    private static func aliased(_ name: String?, _ ext: String?) -> String? {
        name == "henge-jit" && ext == "js" ? "triptych-jit" : name
    }
    // After the exchange these names call the original implementations.
    @objc func tp_path(forResource name: String?, ofType ext: String?) -> String? {
        tp_path(forResource: Bundle.aliased(name, ext), ofType: ext)
    }
    @objc func tp_path(forResource name: String?, ofType ext: String?, inDirectory dir: String?) -> String? {
        tp_path(forResource: Bundle.aliased(name, ext), ofType: ext, inDirectory: dir)
    }
}
