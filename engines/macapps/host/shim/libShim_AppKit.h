// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef LIBSHIM_APPKIT_H
#define LIBSHIM_APPKIT_H

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Register an already-running UIKit host window, root view controller, container view,
/// and guest Mac bundle root (directory containing Contents/Resources) before calling
/// the guest's main() or NSApplicationMain().
__attribute__((visibility("default")))
void ShimHostRegister(UIWindow *window,
                      UIViewController *rootVC,
                      UIView *containerView,
                      NSString *macBundleRoot);

#ifdef __cplusplus
}
#endif

#endif
