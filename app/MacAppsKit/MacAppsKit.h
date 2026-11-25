// SPDX-License-Identifier: GPL-3.0-or-later
// MacAppsKit: Triptych's Mac-apps layer. Imports .dmg/.pkg/.zip files with engines/macapps (macpkg), keeps the
// installed .app bundles in Application Support/MacApps, and runs an arm64 Mac app in-process on the UIKit AppKit shim
// (via Gesso's tl_loader inside the JIT region on device, or dlopen in the Simulator).
#import <UIKit/UIKit.h>
#import "MacRetag.h"
#import "MacProcessShim.h"
#import "PaneWineCommand.h"
#import "PerlCommand.h"

NS_ASSUME_NONNULL_BEGIN

/// One installed .app bundle.
@interface MacAppInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy, nullable) NSString *iconPath;
/// Whether the executable is eligible for the active loader.
@property (nonatomic, assign) BOOL launchable;
@end

@interface MacAppLibrary : NSObject
/// Application Support/MacApps
+ (NSString *)libraryPath;
+ (NSArray<MacAppInfo *> *)installedApps;
/// Extracts every .app in a .dmg/.pkg/.zip into the library. Returns the app names, or nil with an error message.
+ (nullable NSArray<NSString *> *)importFileAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)error;
+ (void)removeAppAtPath:(NSString *)path;
/// The sample guest bundled with Triptych (a zip of the retagged TestMacApp), imported through the same macpkg path.
+ (nullable NSString *)bundledSampleZipPath;
/// The same sample as a real Mac would produce it, with its original macOS platform tag.
+ (nullable NSString *)bundledMacBuiltSampleZipPath;
/// Runs an .app with the device loader. Simulator tests opt in with TRIPTYCH_FORCE_TL=1.
/// Returns the guest main exit code, or -1 with *error on failure.
+ (int)runAppWithTLLoaderAtPath:(NSString *)appPath
                     hostWindow:(nullable UIWindow *)window
                 viewController:(nullable UIViewController *)rootVC
                  containerView:(nullable UIView *)container
                          error:(NSString * _Nullable * _Nullable)error;
@end

/// Full-screen host for one app. The guest's main() takes over the run loop, so an app can only be started once per process.
@interface MacAppHostController : UIViewController
- (instancetype)initWithAppPath:(NSString *)appPath;
+ (BOOL)guestHasStarted;
@end

NS_ASSUME_NONNULL_END
