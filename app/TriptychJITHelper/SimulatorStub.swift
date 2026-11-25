// SPDX-License-Identifier: GPL-3.0-or-later
// Simulator-only stand-in for Henge's HengeJITHelper.swift: the prebuilt StikJIT.xcframework has no
// iphonesimulator slice, and built-in JIT is device-only anyway (HengeBuiltInJIT.unavailableReason).
// On a device this file compiles to nothing and the real helper is used.
#if targetEnvironment(simulator)
import Foundation

@objc(HengeJITHelperHandler)
final class HengeJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = NSExtensionItem()
        let response = HengeJITRequest.Response(success: false, message: "Built-in JIT is available only on a physical device.", txmPresent: nil)
        item.userInfo = [HengeJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
#endif
