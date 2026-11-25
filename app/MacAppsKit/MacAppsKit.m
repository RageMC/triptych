// SPDX-License-Identifier: GPL-3.0-or-later
// Loader after engines/macapps/host (MacAppHost): load the UIKit-backed AppKit/MacShims/Nib/SwiftUI dylibs,
// register the host view, and run the guest via Gesso's AppKit-free tl_loader inside the bottom of
// henge_ios_jit_get_mapping() on device, or dlopen by default in the Simulator.
#import "MacAppsKit.h"
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <unistd.h>
#include "henge-ios-jit.h"
#include "macpkg.h"
#include "MacRetag.h"
#include "MacProcessShim.h"
#include "tl_loader.h"

@implementation MacAppInfo
@end

typedef void (*ShimHostRegisterFn)(UIWindow *, UIViewController *, UIView *, NSString *);
#if TARGET_OS_SIMULATOR
typedef int (*GuestMainFn)(int, const char **);
#endif
static BOOL gGuestStarted;

static BOOL MacAppsUseTL(void) {
#if TARGET_OS_SIMULATOR
    const char *force = getenv("TRIPTYCH_FORCE_TL");
    return force && strcmp(force, "1") == 0;
#else
    return YES;
#endif
}

// MARK: - Shim dylib handles & tl_loader host callbacks

static NSString *gShimDir;
static void *gShimHandles[8];
static int gNumShimHandles;
static void *gShimAppKit;
static void *gShimMacShims;
static void *gShimNib;
static void *gShimSwiftUI;
static void *gShimCocoa;
static void *gShimSwiftCore;

static void *LoadShimDylib(NSString *fwDir, NSString *name) {
    NSString *p = [fwDir stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:p]) return NULL;
    void *h = dlopen(p.fileSystemRepresentation, RTLD_GLOBAL | RTLD_NOW);
    if (h && gNumShimHandles < (int)(sizeof gShimHandles / sizeof *gShimHandles)) {
        gShimHandles[gNumShimHandles++] = h;
    }
    return h;
}

static BOOL EnsureShimsLoaded(NSString **errOut) {
    static BOOL loaded = NO;
    if (loaded) return YES;
    NSString *fwDir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    // One AppKit per process: Henge's translation layer brings its own NSWindow, NSView, ... (HengeTLLazy.c).
    void *htl = dlopen([fwDir stringByAppendingPathComponent:@"HengeTL.framework/HengeTL"].fileSystemRepresentation, RTLD_NOW | RTLD_NOLOAD);
    if (htl) {
        dlclose(htl);
        if (errOut) *errOut = @"A Mac app ran under Henge in this session. Quit and reopen Triptych to start this one.";
        return NO;
    }
    gShimDir = fwDir;
    gNumShimHandles = 0;
    gShimAppKit = LoadShimDylib(fwDir, @"libShim_AppKit.dylib");
    if (!gShimAppKit) {
        if (errOut) *errOut = [NSString stringWithFormat:@"shim: %s", dlerror() ?: "?"];
        return NO;
    }
    gShimMacShims = LoadShimDylib(fwDir, @"libShim_MacShims.dylib");
    gShimNib = LoadShimDylib(fwDir, @"libShim_Nib.dylib");
    gShimSwiftUI = LoadShimDylib(fwDir, @"libShim_SwiftUI.dylib");
    gShimCocoa = LoadShimDylib(fwDir, @"libShim_Cocoa.dylib");
    gShimSwiftCore = LoadShimDylib(fwDir, @"libShim_swiftCore.dylib");
    LoadShimDylib(fwDir, @"libShim_System.dylib");
    loaded = YES;
    return YES;
}

static const char *MacAppsTlMapInstallName(const char *install_name, char *buf, size_t len) {
    if (!install_name) return NULL;
    if (gShimDir.length) {
        const char *fw = gShimDir.fileSystemRepresentation;
        if (!strncmp(install_name, "@rpath/libShim_", 15)) {
            const char *leaf = strrchr(install_name, '/');
            leaf = leaf ? leaf + 1 : install_name;
            snprintf(buf, len, "%s/%s", fw, leaf);
            if (access(buf, F_OK) == 0) return buf;
            if (gShimMacShims) {
                snprintf(buf, len, "%s/libShim_MacShims.dylib", fw);
                if (access(buf, F_OK) == 0) return buf;
            }
        }
        static const struct { const char *needle; const char *dylib; } kMap[] = {
            {"/AppKit.framework/", "libShim_AppKit.dylib"},
            {"/Cocoa.framework/", "libShim_Cocoa.dylib"},
            {"/SwiftUI.framework/", "libShim_SwiftUI.dylib"},
            {"/CoreFoundation.framework/", "libShim_MacShims.dylib"},
            {"/Foundation.framework/", "libShim_MacShims.dylib"},
            {"/CoreGraphics.framework/", "libShim_MacShims.dylib"},
            {"/CoreServices.framework/", "libShim_MacShims.dylib"},
            {"/Security.framework/", "libShim_MacShims.dylib"},
            {"/SecurityFoundation.framework/", "libShim_MacShims.dylib"},
            {"/DiskArbitration.framework/", "libShim_MacShims.dylib"},
            {"/ServiceManagement.framework/", "libShim_MacShims.dylib"},
            {"/SystemConfiguration.framework/", "libShim_MacShims.dylib"},
            {"/IOKit.framework/", "libShim_MacShims.dylib"},
            {"/libswiftCore.dylib", "libShim_swiftCore.dylib"},
        };
        for (size_t i = 0; i < sizeof kMap / sizeof *kMap; i++) {
            if (strstr(install_name, kMap[i].needle)) {
                snprintf(buf, len, "%s/%s", fw, kMap[i].dylib);
                if (access(buf, F_OK) == 0) return buf;
            }
        }
    }
    return tl_ios_map_install_name(install_name, buf, len);
}

static void *LookupInShimHandles(const char *symName) {
    if (!symName || !*symName) return NULL;
    void *ordered[] = {gShimAppKit, gShimMacShims, gShimNib, gShimSwiftUI, gShimCocoa, gShimSwiftCore};
    for (size_t i = 0; i < sizeof ordered / sizeof *ordered; i++) {
        if (!ordered[i]) continue;
        void *s = dlsym(ordered[i], symName);
        if (s) return s;
    }
    for (int i = 0; i < gNumShimHandles; i++) {
        void *s = dlsym(gShimHandles[i], symName);
        if (s) return s;
    }
    return NULL;
}

static BOOL IsShimmedInstallName(const char *install_name) {
    if (!install_name || !*install_name) return YES;
    if (strstr(install_name, "libShim_")) return YES;
    static const char *const kFrameworks[] = {
        "/AppKit.framework/", "/Cocoa.framework/", "/SwiftUI.framework/",
        "/CoreFoundation.framework/", "/Foundation.framework/", "/CoreGraphics.framework/",
        "/CoreServices.framework/", "/Security.framework/", "/SecurityFoundation.framework/",
        "/DiskArbitration.framework/", "/ServiceManagement.framework/", "/SystemConfiguration.framework/",
        "/IOKit.framework/", "/libswiftCore.dylib", NULL
    };
    for (int i = 0; kFrameworks[i]; i++) {
        if (strstr(install_name, kFrameworks[i])) return YES;
    }
    return NO;
}

static void *MacAppsTlShimLookup(const char *install_name, const char *symbol) {
    if (!symbol) return NULL;
    void *proc = MacProcessShimLookup(symbol);
    if (proc) return proc;
    if (symbol[0] != '_') return NULL;
    const char *cname = symbol + 1;
    // A guest bridge can enumerate classes before it has defined the Objective-C classes
    // referenced by its Swift metadata. Keep discovery from realizing those Swift classes early.
    if (!strcmp(cname, "objc_copyClassList")) {
        void *copyRealizedClasses = dlsym(RTLD_DEFAULT, "objc_copyRealizedClassList");
        if (copyRealizedClasses) return copyRealizedClasses;
    }
    if (install_name && strstr(install_name, "libShim_SwiftUI") && gShimSwiftUI) {
        void *s = dlsym(gShimSwiftUI, cname);
        if (s) return s;
    }
    if (install_name && strstr(install_name, "libShim_Nib") && gShimNib) {
        void *s = dlsym(gShimNib, cname);
        if (s) return s;
    }
    if (install_name && (strstr(install_name, "libShim_AppKit") || strstr(install_name, "libShim_Cocoa"))) {
        void *s = gShimAppKit ? dlsym(gShimAppKit, cname) : NULL;
        if (s) return s;
        if (gShimNib) { s = dlsym(gShimNib, cname); if (s) return s; }
    }
    if (install_name && (strstr(install_name, "libShim_MacShims") ||
                         (strstr(install_name, "libShim_") && !strstr(install_name, "AppKit") && !strstr(install_name, "SwiftUI")))) {
        void *s = gShimMacShims ? dlsym(gShimMacShims, cname) : NULL;
        if (s) return s;
    }
    if (IsShimmedInstallName(install_name)) {
        return LookupInShimHandles(cname);
    }
    return NULL;
}

static void MacAppsTlLog(const char *line) {
    fprintf(stderr, "MacAppsKit(tl): %s\n", line ? line : "");
}

#if !TARGET_OS_SIMULATOR
static int MacAppsReserveBottom(size_t end) {
    typedef bool (*ReserveBottomFn)(size_t);
    static ReserveBottomFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (ReserveBottomFn)dlsym(RTLD_DEFAULT, "henge_ios_jit_reserve_bottom"); });
    return fn ? (fn(end) ? 1 : 0) : 1;
}

static HengeDualMapping *MacAppsGetJITMapping(void) {
    typedef HengeDualMapping *(*GetMappingFn)(void);
    static GetMappingFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (GetMappingFn)dlsym(RTLD_DEFAULT, "henge_ios_jit_get_mapping"); });
    return fn ? fn() : NULL;
}

static int MacAppsTakeHighRoom(void **base, size_t *bytes) {
    typedef int (*TakeHighFn)(void **, size_t *);
    static TakeHighFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (TakeHighFn)dlsym(RTLD_DEFAULT, "henge_ios_take_high_room"); });
    return fn ? fn(base, bytes) : 0;
}

#endif

static int MacAppsTlHelperLauncher(const char *path, char *const argv[], char *const envp[], int *exitStatus) {
    return tl_spawn_guest_helper(path, argv, envp, exitStatus);
}

#if TARGET_OS_SIMULATOR
static GuestMainFn FindGuestEntryPoint(const char *guestPath, void *handle) {
    char rt[PATH_MAX];
    const char *target = realpath(guestPath, rt) ? rt : guestPath;
    for (uint32_t i = _dyld_image_count(); i > 0; i--) {
        const char *name = _dyld_get_image_name(i - 1);
        char ri[PATH_MAX];
        if (!name || strcmp(realpath(name, ri) ? ri : name, target) != 0) continue;
        const struct mach_header_64 *mh = (const void *)_dyld_get_image_header(i - 1);
        if (!mh || mh->magic != MH_MAGIC_64) break;
        const uint8_t *p = (const uint8_t *)(mh + 1);
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const void *)p;
            if (lc->cmd == LC_MAIN) return (GuestMainFn)((uintptr_t)mh + ((const struct entry_point_command *)lc)->entryoff);
            p += lc->cmdsize;
        }
    }
    return (GuestMainFn)dlsym(handle, "main");
}

static int MacAppsDlopenHelperLauncher(const char *path, char *const argv[], char *const envp[], int *exitStatus) {
    (void)envp;
    // A guest loader's executable-wide symbols can describe the address space
    // of a separately exec'd process. Keep them out of the host's global scope.
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "MacAppsKit: dlopen helper %s failed: %s\n", path, dlerror() ?: "?");
        return -1;
    }
    GuestMainFn gmain = FindGuestEntryPoint(path, h);
    if (!gmain) return -1;
    int argc = 0;
    while (argv && argv[argc]) argc++;
    const char *fallback[] = {path, NULL};
    int rc = gmain(argc > 0 ? argc : 1, argc > 0 ? (const char **)argv : fallback);
    if (exitStatus) *exitStatus = rc;
    return 0;
}

#endif

// MARK: - Library

@implementation MacAppLibrary

+ (NSString *)libraryPath {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"MacApps"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

/// Reads LC_BUILD_VERSION: platform 2 (iOS) or 7 (iOS Simulator) means retagged.
static BOOL ExecutableIsRetagged(NSString *exe) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:exe];
    NSData *d = [fh readDataOfLength:65536];
    [fh closeFile];
    if (d.length < sizeof(struct mach_header_64)) return NO;
    const struct mach_header_64 *mh = d.bytes;
    if (mh->magic != MH_MAGIC_64) return NO;
    const uint8_t *p = (const uint8_t *)(mh + 1), *end = (const uint8_t *)d.bytes + d.length;
    for (uint32_t i = 0; i < mh->ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmdsize < sizeof(*lc) || p + lc->cmdsize > end) return NO;
        if (lc->cmd == LC_BUILD_VERSION) {
            uint32_t plat = ((const struct build_version_command *)lc)->platform;
            return plat == PLATFORM_IOS || plat == PLATFORM_IOSSIMULATOR;
        }
        p += lc->cmdsize;
    }
    return NO;
}

+ (NSArray<MacAppInfo *> *)installedApps {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [self libraryPath];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in [[fm contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if (![n.pathExtension isEqualToString:@"app"]) continue;
        NSString *path = [root stringByAppendingPathComponent:n];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
        MacAppInfo *a = [MacAppInfo new];
        NSString *disp = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
        a.name = disp.length ? disp : n.stringByDeletingPathExtension;
        a.path = path;
        NSString *icon = info[@"CFBundleIconFile"];
        if (icon.length) {
            if (!icon.pathExtension.length) icon = [icon stringByAppendingPathExtension:@"icns"];
            NSString *ip = [path stringByAppendingPathComponent:[@"Contents/Resources" stringByAppendingPathComponent:icon]];
            if ([fm fileExistsAtPath:ip]) a.iconPath = ip;
        }
        NSString *exe = info[@"CFBundleExecutable"] ?: n.stringByDeletingPathExtension;
        NSString *binary = [path stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:exe]];
        a.launchable = MacAppsUseTL()
            ? [[NSBundle bundleWithPath:path].executableArchitectures containsObject:@(CPU_TYPE_ARM64)]
            : ExecutableIsRetagged(binary);
        [out addObject:a];
    }
    return out;
}

/// An app from a real Mac still has the macOS platform tag and its Mac signature: retag and sign, in process, every
/// arm64 Mach-O in the bundle (frameworks, dylibs, Python extension modules, helper executables), not only the main
/// executable, so what the app loads later loads too.
+ (void)retagAppIfNeeded:(NSString *)appPath {
    char err[512] = {0};
    MacRetagStats st;
    NSString *exeDir = [appPath stringByAppendingPathComponent:@"Contents/MacOS"];
    int rc = MacRetagBundle(appPath.fileSystemRepresentation, exeDir.fileSystemRepresentation, &st, err, sizeof err);
    NSLog(@"MacAppsKit: retag %@: %u retagged, %u already, %u without arm64 code, %u failed%s%s", appPath.lastPathComponent,
          st.retagged, st.already, st.skipped, st.failed, rc ? " - " : "", err);
}

+ (NSArray<NSString *> *)importFileAtPath:(NSString *)path error:(NSString **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *stage = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];
    char err[512] = {0};
    macpkg_options_t opts = {0};
    macpkg_status_t st = macpkg_extract_file(path.fileSystemRepresentation, stage.fileSystemRepresentation, &opts, err, sizeof err);
    NSMutableArray *names = [NSMutableArray array];
    if (st == MACPKG_OK) {
        for (NSString *n in [fm contentsOfDirectoryAtPath:stage error:nil]) {
            if (![n.pathExtension isEqualToString:@"app"]) continue;
            NSString *dst = [[self libraryPath] stringByAppendingPathComponent:n];
            [fm removeItemAtPath:dst error:nil];
            if (![fm moveItemAtPath:[stage stringByAppendingPathComponent:n] toPath:dst error:nil]) continue;
            [names addObject:n.stringByDeletingPathExtension];
            if (!MacAppsUseTL()) [self retagAppIfNeeded:dst];
        }
        if (!names.count && error) *error = @"No .app bundle found in that file.";
    } else if (error) {
        *error = [NSString stringWithFormat:@"%s%s%s", macpkg_strerror(st), err[0] ? ": " : "", err];
    }
    [fm removeItemAtPath:stage error:nil];
    return names.count ? names : nil;
}

+ (void)removeAppAtPath:(NSString *)path {
    if ([path hasPrefix:[self libraryPath]]) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

+ (NSString *)bundledSampleZipPath {
    return [NSBundle.mainBundle pathForResource:@"TestMacApp" ofType:@"zip"];
}

+ (NSString *)bundledMacBuiltSampleZipPath {
    return [NSBundle.mainBundle pathForResource:@"MacBuiltApp" ofType:@"zip"];
}

// Sparkle (SUFeedURL in Info.plist) asks on first launch whether to check for updates, and later offers to replace
// the app bundle. Neither works for an imported app, so automatic checks are off in both places Sparkle reads them:
// the standard domain (guest main bundle) and the suite named after the guest's bundle identifier.
static void MacAppsQuietSparkle(NSDictionary *info) {
    if (!info[@"SUFeedURL"]) return;
    NSMutableArray<NSUserDefaults *> *domains = [NSMutableArray arrayWithObject:NSUserDefaults.standardUserDefaults];
    NSString *bid = info[@"CFBundleIdentifier"];
    if (bid.length) { NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:bid]; if (d) [domains addObject:d]; }
    for (NSUserDefaults *d in domains) {
        [d setBool:NO forKey:@"SUEnableAutomaticChecks"];
        [d setBool:NO forKey:@"SUAutomaticallyUpdate"];
        [d setBool:YES forKey:@"SUHasLaunchedBefore"];
    }
}

static BOOL PrepareTlHost(TlHost *host, NSString **errOut) {
#if TARGET_OS_SIMULATOR
    if (tl_host_init_split(host, (size_t)64 << 20) != 0) {
        if (errOut) *errOut = @"tl_host_init_split failed";
        return NO;
    }
#else
    HengeDualMapping *jit = MacAppsGetJITMapping();
    if (!jit || !jit->rx_addr || !jit->rw_addr || !jit->size) {
        if (errOut) *errOut = @"Turn on JIT first (Easel / Setup) to run Mac apps on this device.";
        return NO;
    }
    memset(host, 0, sizeof *host);
    tl_host_init_region(host, jit->rx_addr, jit->rw_addr, jit->size);
    host->reserve_region = MacAppsReserveBottom;
    host->high_rooms = MacAppsTakeHighRoom(host->high_room, host->high_room_bytes);
#endif
    host->map_install_name = MacAppsTlMapInstallName;
    host->shim_lookup = MacAppsTlShimLookup;
    host->log = MacAppsTlLog;
    host->soft_missing = 1;
    host->no_processes = 0;
    host->processes_as_threads = 0;
    return YES;
}

static TlImage *LoadTLGuest(NSString *appPath, NSString *guest, ShimHostRegisterFn reg,
                            UIWindow *window, UIViewController *rootVC, UIView *container, NSString **error) {
    static TlHost host;
    if (!PrepareTlHost(&host, error)) return NULL;

    tl_adopt_main_bundle(appPath.fileSystemRepresentation);
    reg(window, rootVC, container, appPath);
    MacProcessShimInstallForBundle(appPath.fileSystemRepresentation);
    PaneWineCommandInstall();
    PerlCommandInstall();
    MacProcessShimSetHelperLauncher(MacAppsTlHelperLauncher);
    MacProcessShimSetExitFallback(tl_guest_exit_from);

    char tlErr[512] = {0};
    TlImage *img = tl_load(&host, guest.fileSystemRepresentation, tlErr, sizeof tlErr);
    if (!img && error) *error = [NSString stringWithFormat:@"tl_load: %s", tlErr[0] ? tlErr : "failed"];
    return img;
}

static int RunTLGuest(TlImage *img, NSString *guest) {
    const char *argv[] = {guest.fileSystemRepresentation, NULL};
    extern char **environ;
    return tl_run_main(img, 1, argv, (const char **)environ);
}

+ (int)runAppWithTLLoaderAtPath:(NSString *)appPath
                    hostWindow:(UIWindow *)window
                viewController:(UIViewController *)rootVC
                 containerView:(UIView *)container
                         error:(NSString **)error {
    if (!MacAppsUseTL()) {
        if (error) *error = @"Set TRIPTYCH_FORCE_TL=1 to run the translation loader in the Simulator.";
        return -1;
    }
    if (!EnsureShimsLoaded(error)) return -1;
    ShimHostRegisterFn reg = (ShimHostRegisterFn)dlsym(gShimAppKit, "ShimHostRegister");
    if (!reg) {
        if (error) *error = @"ShimHostRegister missing";
        return -1;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *exe = info[@"CFBundleExecutable"] ?: appPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *guest = [appPath stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:exe]];
    MacAppsQuietSparkle(info);
    TlImage *img = LoadTLGuest(appPath, guest, reg, window, rootVC, container, error);
    return img ? RunTLGuest(img, guest) : -1;
}

@end

// MARK: - Host View Controller
typedef void (*ShimHostSizeChangedFn)(void);

@implementation MacAppHostController {
    NSString *_appPath;
    UILabel *_status;
    UIView *_container;
    BOOL _launched;
    ShimHostSizeChangedFn _hostSizeChanged;
    CGSize _hostSize;
}

// Once the Mac app draws, the status line must not sit on top of its title bar. It stays in the accessibility
// tree (UI tests read "Running ..."), but is invisible and takes no touches.
- (void)shimHideStatusVisually {
    _status.textColor = UIColor.clearColor;
    _status.backgroundColor = UIColor.clearColor;
    _status.userInteractionEnabled = NO;
}

+ (BOOL)guestHasStarted { return gGuestStarted; }

- (instancetype)initWithAppPath:(NSString *)appPath {
    if ((self = [super init])) _appPath = [appPath copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:1.0];
    _status = [UILabel new];
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    _status.text = @"Starting…";
    _status.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    _status.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.accessibilityIdentifier = @"host-status";
    [self.view addSubview:_status];
    _container = [UIView new];
    _container.translatesAutoresizingMaskIntoConstraints = NO;
    _container.accessibilityIdentifier = @"mac-window-container";
    [self.view insertSubview:_container belowSubview:_status];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_status.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [_status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_status.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_container.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = _container.bounds.size;
    if (_hostSizeChanged && !CGSizeEqualToSize(size, _hostSize)) {
        _hostSize = size;
        _hostSizeChanged();
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_launched) return;
    _launched = YES;
    // A timer, not dispatch_async: the guest's CFRunLoopRun() must not starve main-queue deliveries.
    [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(launchGuest) userInfo:nil repeats:NO];
}

- (void)fail:(NSString *)msg {
    _status.text = msg;
    _status.textColor = UIColor.systemRedColor;
    NSLog(@"MacAppsKit: %@", msg);
}

- (void)redirectGuestOutput {
    // The guest's stdout/stderr (shim logs, Python tracebacks) go to MacApps/<app>.log, next to the app; the
    // one-guest-per-session rule means nothing else needs that output while it runs.
    NSString *logPath = [_appPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"log"];
    int lfd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (lfd >= 0) {
        dup2(lfd, STDOUT_FILENO);
        dup2(lfd, STDERR_FILENO);
        close(lfd);
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
    }
}

- (void)launchGuest {
    if (gGuestStarted) {
        [self fail:@"A Mac app already ran in this session. Quit and reopen Triptych to start another."];
        return;
    }
    NSString *shimErr = nil;
    if (!EnsureShimsLoaded(&shimErr)) {
        [self fail:shimErr ?: @"Failed to load AppKit shims"];
        return;
    }
    ShimHostRegisterFn reg = (ShimHostRegisterFn)dlsym(gShimAppKit, "ShimHostRegisterFullscreen");
    if (!reg) { [self fail:@"ShimHostRegisterFullscreen missing"]; return; }
    _hostSizeChanged = (ShimHostSizeChangedFn)dlsym(gShimAppKit, "ShimHostSizeChanged");

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[_appPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *exe = info[@"CFBundleExecutable"] ?: _appPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *guest = [_appPath stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:exe]];
    MacAppsQuietSparkle(info);

    if (MacAppsUseTL()) {
        NSString *tlError = nil;
        TlImage *img = LoadTLGuest(_appPath, guest, reg, self.view.window, self, _container, &tlError);
        if (!img) {
            [self fail:tlError];
            return;
        }
        gGuestStarted = YES;
        [self redirectGuestOutput];
        _status.text = [NSString stringWithFormat:@"Running %@ (tl_loader)", exe];
    [self shimHideStatusVisually];
        [self.view layoutIfNeeded];
        int rc = RunTLGuest(img, guest);
        NSLog(@"MacAppsKit: tl_loader guest main exited with %d", rc);
        return;
    }

#if TARGET_OS_SIMULATOR
    reg(self.view.window, self, _container, _appPath);
    MacProcessShimInstallForBundle(_appPath.fileSystemRepresentation);
    PaneWineCommandInstall();
    PerlCommandInstall();
    MacProcessShimSetHelperLauncher(MacAppsDlopenHelperLauncher);

    void *h = dlopen(guest.fileSystemRepresentation, RTLD_NOW);
    if (!h) { [self fail:[NSString stringWithFormat:@"dlopen guest: %s", dlerror() ?: "?"]]; return; }
    GuestMainFn gmain = FindGuestEntryPoint(guest.fileSystemRepresentation, h);
    if (!gmain) { [self fail:@"No LC_MAIN or main in the guest"]; return; }
    gGuestStarted = YES;
    [self redirectGuestOutput];
    _status.text = [NSString stringWithFormat:@"Running %@ (dlopen + LC_MAIN)", exe];
    [self shimHideStatusVisually];
    [self.view layoutIfNeeded];
    const char *argv[] = {guest.fileSystemRepresentation, NULL};
    int rc = gmain(1, argv);
    NSLog(@"MacAppsKit: guest main exited with %d", rc);
#endif
}

@end
