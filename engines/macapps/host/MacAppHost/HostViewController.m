// SPDX-License-Identifier: GPL-3.0-or-later
// HostViewController: dlopens libShim_AppKit.dylib and the retagged macOS testapp,
// registers this UIWindow / container view with the shim, locates LC_MAIN (or main),
// and starts the macOS guest inside the running iOS app.

#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*ShimHostRegisterFn)(UIWindow *, UIViewController *, UIView *, NSString *);
typedef int (*GuestMainFn)(int, const char **);

@interface HostViewController : UIViewController
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *guestContainer;
@property (nonatomic, assign) BOOL guestStarted;
@end

@implementation HostViewController

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:1.0];

    UILabel *banner = [UILabel new];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.text = @"MacAppHost • Retagged arm64 Guest";
    banner.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    banner.textColor = [UIColor colorWithRed:0.65 green:0.78 blue:0.98 alpha:1.0];
    banner.textAlignment = NSTextAlignmentCenter;
    banner.accessibilityIdentifier = @"host-banner";
    [self.view addSubview:banner];

    _statusLabel = [UILabel new];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.text = @"Initializing guest...";
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    _statusLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.accessibilityIdentifier = @"host-status";
    [self.view addSubview:_statusLabel];

    _guestContainer = [UIView new];
    _guestContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _guestContainer.backgroundColor = UIColor.clearColor;
    _guestContainer.accessibilityIdentifier = @"mac-window-container";
    [self.view addSubview:_guestContainer];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [banner.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6.0],
        [banner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
        [banner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],

        [_statusLabel.topAnchor constraintEqualToAnchor:banner.bottomAnchor constant:2.0],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],

        [_guestContainer.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:10.0],
        [_guestContainer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [_guestContainer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [_guestContainer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12.0],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_guestStarted) return;
    _guestStarted = YES;

    // Launch via NSTimer (not dispatch_async on main queue) so guest CFRunLoopRun()
    // never stalls serial main-queue dispatch deliveries.
    [NSTimer scheduledTimerWithTimeInterval:0.05
                                     target:self
                                   selector:@selector(launchGuest)
                                   userInfo:nil
                                    repeats:NO];
}

// Locate LC_MAIN (entryoff) for the dlopened guest Mach-O so even stripped binaries work.
static GuestMainFn FindGuestEntryPoint(const char *guestPath, void *guestHandle) {
    char resolvedTarget[PATH_MAX];
    const char *target = realpath(guestPath, resolvedTarget) ? resolvedTarget : guestPath;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = count; i > 0; i--) {
        uint32_t idx = i - 1;
        const char *imgName = _dyld_get_image_name(idx);
        if (!imgName) continue;
        char resolvedImg[PATH_MAX];
        const char *cmpImg = realpath(imgName, resolvedImg) ? resolvedImg : imgName;
        if (strcmp(cmpImg, target) != 0) continue;

        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(idx);
        if (!mh || mh->magic != MH_MAGIC_64) break;
        const uint8_t *ptr = (const uint8_t *)(mh + 1);
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)ptr;
            if (lc->cmd == LC_MAIN && lc->cmdsize >= sizeof(struct entry_point_command)) {
                const struct entry_point_command *ep = (const struct entry_point_command *)ptr;
                return (GuestMainFn)((uintptr_t)mh + (uintptr_t)ep->entryoff);
            }
            ptr += lc->cmdsize;
        }
    }
    return (GuestMainFn)dlsym(guestHandle, "main");
}

- (void)failWithMessage:(NSString *)msg {
    _statusLabel.text = msg;
    _statusLabel.textColor = UIColor.systemRedColor;
    fprintf(stderr, "MacAppHost ERROR: %s\n", msg.UTF8String);
    fflush(stderr);
}

- (void)launchGuest {
    [self.view layoutIfNeeded];

    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *shimPath = [bundlePath stringByAppendingPathComponent:@"Frameworks/libShim_AppKit.dylib"];
    const char *envRoot = getenv("MACAPP_GUEST_ROOT");
    NSString *macGuestRoot = (envRoot && envRoot[0] != '\0')
        ? [NSString stringWithUTF8String:envRoot]
        : [bundlePath stringByAppendingPathComponent:@"MacGuest"];
    const char *envBin = getenv("MACAPP_GUEST_BIN");
    NSString *guestBinPath = nil;
    if (envBin && envBin[0] != '\0') {
        guestBinPath = [NSString stringWithUTF8String:envBin];
    } else {
        NSString *guestPlistPath = [macGuestRoot stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *guestInfo = [NSDictionary dictionaryWithContentsOfFile:guestPlistPath];
        NSString *execName = guestInfo[@"CFBundleExecutable"];
        if (execName.length > 0) {
            guestBinPath = [[macGuestRoot stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:execName];
        } else {
            guestBinPath = [macGuestRoot stringByAppendingPathComponent:@"Contents/MacOS/TestMacApp"];
        }
    }

    fprintf(stderr, "MacAppHost: dlopen shim %s\n", shimPath.UTF8String);
    fflush(stderr);
    void *shimHandle = dlopen(shimPath.fileSystemRepresentation, RTLD_GLOBAL | RTLD_NOW);
    if (!shimHandle) {
        [self failWithMessage:[NSString stringWithFormat:@"dlopen shim failed: %s", dlerror() ?: "unknown"]];
        return;
    }
    NSString *fwDir = shimPath.stringByDeletingLastPathComponent;
    for (NSString *extraShim in @[@"libShim_MacShims.dylib", @"libShim_SwiftUI.dylib", @"libShim_Cocoa.dylib"]) {
        NSString *p = [fwDir stringByAppendingPathComponent:extraShim];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            dlopen(p.fileSystemRepresentation, RTLD_GLOBAL | RTLD_NOW);
        }
    }

    ShimHostRegisterFn registerFn = (ShimHostRegisterFn)dlsym(shimHandle, "ShimHostRegister");
    if (!registerFn) {
        [self failWithMessage:@"ShimHostRegister symbol not found in libShim_AppKit.dylib"];
        return;
    }
    registerFn(self.view.window, self, _guestContainer, macGuestRoot);

    fprintf(stderr, "MacAppHost: dlopen guest %s\n", guestBinPath.UTF8String);
    fflush(stderr);
    void *guestHandle = dlopen(guestBinPath.fileSystemRepresentation, RTLD_NOW);
    if (!guestHandle) {
        [self failWithMessage:[NSString stringWithFormat:@"dlopen guest failed: %s", dlerror() ?: "unknown"]];
        return;
    }

    GuestMainFn guestMain = FindGuestEntryPoint(guestBinPath.fileSystemRepresentation, guestHandle);
    if (!guestMain) {
        [self failWithMessage:@"Could not find LC_MAIN or _main in guest binary"];
        return;
    }

    _statusLabel.text = [NSString stringWithFormat:@"Running %@ (dlopen + LC_MAIN)", guestBinPath.lastPathComponent];
    [self.view layoutIfNeeded];

    fprintf(stderr, "MacAppHost: invoking guest entry at %p\n", (void *)guestMain);
    fflush(stderr);
    const char *argv[] = { guestBinPath.fileSystemRepresentation, NULL };
    int rc = guestMain(1, argv);
    fprintf(stderr, "MacAppHost: guest main exited with %d\n", rc);
    fflush(stderr);
}

@end
