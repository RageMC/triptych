// SPDX-License-Identifier: GPL-3.0-or-later
// Minimal UIKit-backed AppKit shim (libShim_AppKit.dylib).
// Follows the pattern of macos-on-ios (MIT, Copyright (c) 2026 Ross Fisher;
// see LICENSE.macos-on-ios in this directory) adapted for in-process hosting
// inside an already-running UIKit host (MacAppHost / Triptych).

#import "libShim_AppKit.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <unistd.h>

@class NSWindow, NSView, NSViewController, NSColor, NSEvent, NSScreen;

// Exported AppKit symbols expected by linked macOS binaries.
__attribute__((visibility("default"))) id NSApp = nil;
__attribute__((visibility("default"))) double NSAppKitVersionNumber = 2685.60;
__attribute__((visibility("default"))) NSString *const NSAppearanceNameAqua = @"NSAppearanceNameAqua";
__attribute__((visibility("default"))) NSString *const NSAppearanceNameDarkAqua = @"NSAppearanceNameDarkAqua";
__attribute__((visibility("default"))) NSString *const NSApplicationWillFinishLaunchingNotification = @"NSApplicationWillFinishLaunchingNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationDidFinishLaunchingNotification = @"NSApplicationDidFinishLaunchingNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationWillBecomeActiveNotification = @"NSApplicationWillBecomeActiveNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationWillResignActiveNotification = @"NSApplicationWillResignActiveNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationDidResignActiveNotification = @"NSApplicationDidResignActiveNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationDidChangeScreenParametersNotification = @"NSApplicationDidChangeScreenParametersNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationDidHideNotification = @"NSApplicationDidHideNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationDidUnhideNotification = @"NSApplicationDidUnhideNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationDidUpdateNotification = @"NSApplicationDidUpdateNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationWillHideNotification = @"NSApplicationWillHideNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationWillTerminateNotification = @"NSApplicationWillTerminateNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationWillUnhideNotification = @"NSApplicationWillUnhideNotification";
__attribute__((visibility("default"))) NSString *const NSApplicationWillUpdateNotification = @"NSApplicationWillUpdateNotification";
__attribute__((visibility("default"))) NSString *const NSWindowDidBecomeKeyNotification = @"NSWindowDidBecomeKeyNotification";
__attribute__((visibility("default"))) NSString *const NSWindowDidBecomeMainNotification = @"NSWindowDidBecomeMainNotification";
__attribute__((visibility("default"))) NSString *const NSWindowDidResignKeyNotification = @"NSWindowDidResignKeyNotification";
__attribute__((visibility("default"))) NSString *const NSWindowDidResizeNotification = @"NSWindowDidResizeNotification";
__attribute__((visibility("default"))) NSString *const NSWindowWillCloseNotification = @"NSWindowWillCloseNotification";
__attribute__((visibility("default"))) NSString *const NSWorkspaceDidActivateApplicationNotification = @"NSWorkspaceDidActivateApplicationNotification";
__attribute__((visibility("default"))) NSString *const NSWorkspaceDidDeactivateApplicationNotification = @"NSWorkspaceDidDeactivateApplicationNotification";
__attribute__((visibility("default"))) NSString *const NSWorkspaceDidMountNotification = @"NSWorkspaceDidMountNotification";
__attribute__((visibility("default"))) NSString *const NSWorkspaceDidUnmountNotification = @"NSWorkspaceDidUnmountNotification";
__attribute__((visibility("default"))) NSString *const NSWorkspaceApplicationKey = @"NSWorkspaceApplicationKey";
__attribute__((visibility("default"))) NSString *const NSWorkspaceRecycleOperation = @"recycle";
__attribute__((visibility("default"))) NSString *const NSCharacterEncodingDocumentOption = @"CharacterEncoding";
__attribute__((visibility("default"))) NSString *const NSDeviceRGBColorSpace = @"NSDeviceRGBColorSpace";
__attribute__((visibility("default"))) NSString *const NSCalibratedRGBColorSpace = @"NSCalibratedRGBColorSpace";
__attribute__((visibility("default"))) NSString *const NSDraggingImageComponentLabelKey = @"label";
__attribute__((visibility("default"))) NSString *const NSImageHintInterpolation = @"NSImageHintInterpolation";
__attribute__((visibility("default"))) NSString *const NSImageNameCaution = @"NSCaution";
__attribute__((visibility("default"))) NSString *const NSObservedKeyPathKey = @"NSObservedKeyPathKey";
__attribute__((visibility("default"))) NSString *const NSObservedObjectKey = @"NSObservedObjectKey";
__attribute__((visibility("default"))) NSString *const NSPasteboardTypeFileURL = @"public.file-url";
__attribute__((visibility("default"))) NSString *const NSValueBinding = @"value";
__attribute__((visibility("default"))) NSString *const NSHiddenBinding = @"hidden";
__attribute__((visibility("default"))) NSString *const NSTitleBinding = @"title";
__attribute__((visibility("default"))) NSString *const NSMaxValueBinding = @"maxValue";
__attribute__((visibility("default"))) NSString *const NSValueTransformerNameBindingOption = @"NSValueTransformerName";
__attribute__((visibility("default"))) NSString *const NSImageNameApplicationIcon = @"NSApplicationIcon";
__attribute__((visibility("default"))) NSString *const NSViewFrameDidChangeNotification = @"NSViewFrameDidChangeNotification";
__attribute__((visibility("default"))) const CGFloat NSViewNoIntrinsicMetric = -1.0;
__attribute__((visibility("default"))) const CGFloat NSFontWeightRegular = 0.0;

__attribute__((visibility("default"))) void NSBeep(void) {}
__attribute__((visibility("default"))) void NSFrameRectWithWidth(CGRect rect, CGFloat frameWidth) {
    (void)rect; (void)frameWidth;
}
__attribute__((visibility("default"))) void NSRectFillUsingOperation(CGRect rect, NSUInteger op) {
    (void)op;
    UIRectFill(rect);
}
__attribute__((visibility("default"))) NSInteger NSRunAlertPanel(NSString *title, NSString *msgFormat, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...) {
    (void)defaultButton; (void)alternateButton; (void)otherButton;
    NSString *msg = msgFormat;
    if (msgFormat) {
        va_list ap;
        va_start(ap, otherButton);
        msg = [[NSString alloc] initWithFormat:msgFormat arguments:ap];
        va_end(ap);
    }
    fprintf(stderr, "NSRunAlertPanel: %s | %s\n",
            title ? title.UTF8String : "",
            msg ? msg.UTF8String : "");
    fflush(stderr);
    return 1; // NSAlertDefaultReturn
}

static NSMutableArray<NSWindow *> *gWindows;
static UIWindow *gHostWindow;
static UIViewController *gRootVC;
static UIView *gHostContainer;
static NSString *gMacBundleRoot;
static BOOL gHostedMode = NO;
static NSUInteger gUserActionDepth;
static BOOL gHostFullscreen = NO;

void ShimBindingPush(id target, NSString *binding, id value);

// MARK: Unknown-selector fallback (macos-on-ios pattern, MIT)

static id ShimMissing(id self, SEL _cmd, ...) {
    (void)self;
    (void)_cmd;
    return nil;
}

static id ShimMissingInit(id self, SEL _cmd, ...) {
    (void)_cmd;
    return self;
}

static BOOL ShimResolve(Class cls, SEL sel, BOOL isClass) {
    fprintf(stderr, "SHIM MISSING %c[%s %s]\n",
            isClass ? '+' : '-',
            class_getName(cls),
            sel_getName(sel));
    fflush(stderr);
    BOOL isInit = !isClass && [NSStringFromSelector(sel) hasPrefix:@"init"];
    class_addMethod(isClass ? object_getClass(cls) : cls, sel,
                    (IMP)(isInit ? ShimMissingInit : ShimMissing), "@@:");
    return YES;
}

#define SHIM_RESOLVE \
    + (BOOL)resolveInstanceMethod:(SEL)sel { return [super resolveInstanceMethod:sel] || ShimResolve(self, sel, NO); } \
    + (BOOL)resolveClassMethod:(SEL)sel { return [super resolveClassMethod:sel] || ShimResolve(self, sel, YES); }

// MARK: NSBundle & Metal runtime hooks (macos-on-ios pattern, MIT)

static IMP gOrigBundlePath, gOrigExecutablePath, gOrigResourcePath;
static IMP gOrigBundleURL, gOrigExecutableURL, gOrigResourceURL;
static IMP gOrigPathForResource, gOrigURLForResource;
static IMP gOrigPathForResourceDir, gOrigURLForResourceDir;
static IMP gOrigPrivateFrameworksPath, gOrigPrivateFrameworksURL;
static IMP gOrigSharedSupportPath, gOrigSharedSupportURL;
static IMP gOrigBuiltInPlugInsPath, gOrigBuiltInPlugInsURL;
static IMP gOrigBundleWithPath, gOrigBundleWithURL, gOrigBundleWithIdentifier;
static IMP gOrigInfoDictionary, gOrigObjectForInfoKey, gOrigBundleIdentifier;
static NSDictionary *gMacGuestInfoPlist;

static NSDictionary *ShimLoadGuestInfoPlist(void) {
    if (!gMacBundleRoot) return nil;
    if (!gMacGuestInfoPlist) {
        NSString *p = [gMacBundleRoot stringByAppendingPathComponent:@"Contents/Info.plist"];
        gMacGuestInfoPlist = [NSDictionary dictionaryWithContentsOfFile:p];
    }
    return gMacGuestInfoPlist;
}

static NSString *ShimBundlePath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) return gMacBundleRoot;
    return ((NSString *(*)(id, SEL))gOrigBundlePath)(self, _cmd);
}

static NSString *ShimResourcePath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [gMacBundleRoot stringByAppendingPathComponent:@"Contents/Resources"];
    }
    return ((NSString *(*)(id, SEL))gOrigResourcePath)(self, _cmd);
}

static NSString *ShimExecutablePath(NSBundle *self, SEL _cmd) {
    NSString *real = ((NSString *(*)(id, SEL))gOrigExecutablePath)(self, _cmd);
    if (self != NSBundle.mainBundle || !gMacBundleRoot) return real;
    NSString *execName = ShimLoadGuestInfoPlist()[@"CFBundleExecutable"];
    return [gMacBundleRoot stringByAppendingFormat:@"/Contents/MacOS/%@",
            execName.length ? execName : real.lastPathComponent];
}

static NSDictionary *ShimInfoDictionary(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        NSDictionary *d = ShimLoadGuestInfoPlist();
        if (d) return d;
    }
    return ((NSDictionary *(*)(id, SEL))gOrigInfoDictionary)(self, _cmd);
}

static id ShimObjectForInfoKey(NSBundle *self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        NSDictionary *d = ShimLoadGuestInfoPlist();
        if (d && d[key]) return d[key];
    }
    return ((id (*)(id, SEL, id))gOrigObjectForInfoKey)(self, _cmd, key);
}

static NSString *ShimBundleIdentifier(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        NSString *bid = ShimLoadGuestInfoPlist()[@"CFBundleIdentifier"];
        if (bid) return bid;
    }
    return ((NSString *(*)(id, SEL))gOrigBundleIdentifier)(self, _cmd);
}

static NSURL *ShimBundleURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [NSURL fileURLWithPath:ShimBundlePath(self, @selector(bundlePath)) isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL))gOrigBundleURL)(self, _cmd);
}

static NSURL *ShimResourceURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [NSURL fileURLWithPath:ShimResourcePath(self, @selector(resourcePath)) isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL))gOrigResourceURL)(self, _cmd);
}

static NSURL *ShimExecutableURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [NSURL fileURLWithPath:ShimExecutablePath(self, @selector(executablePath))];
    }
    return ((NSURL *(*)(id, SEL))gOrigExecutableURL)(self, _cmd);
}

static NSString *ShimMacResourceInDir(NSString *name, NSString *ext, NSString *subpath) {
    if (!gMacBundleRoot || !name) return nil;
    NSString *file = ext.length ? [name stringByAppendingPathExtension:ext] : name;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *resRoot = [gMacBundleRoot stringByAppendingPathComponent:@"Contents/Resources"];
    if (subpath.length) {
        NSString *p = [[resRoot stringByAppendingPathComponent:subpath] stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSArray<NSString *> *dirs = @[@"", @"Base.lproj", @"en.lproj", @"English.lproj"];
    for (NSString *dir in dirs) {
        NSString *base = dir.length ? [resRoot stringByAppendingPathComponent:dir] : resRoot;
        NSString *p = [base stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

static NSString *ShimMacResource(NSString *name, NSString *ext) {
    return ShimMacResourceInDir(name, ext, nil);
}

static NSString *ShimPathForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        NSString *macPath = ShimMacResource(name, ext);
        if (macPath) return macPath;
    }
    return ((NSString *(*)(id, SEL, id, id))gOrigPathForResource)(self, _cmd, name, ext);
}

static NSURL *ShimURLForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        NSString *macPath = ShimMacResource(name, ext);
        if (macPath) return [NSURL fileURLWithPath:macPath];
    }
    return ((NSURL *(*)(id, SEL, id, id))gOrigURLForResource)(self, _cmd, name, ext);
}

static NSString *ShimPathForResourceDir(NSBundle *self, SEL _cmd, NSString *name, NSString *ext, NSString *subpath) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        NSString *macPath = ShimMacResourceInDir(name, ext, subpath);
        if (macPath) return macPath;
    }
    return ((NSString *(*)(id, SEL, id, id, id))gOrigPathForResourceDir)(self, _cmd, name, ext, subpath);
}

static NSURL *ShimURLForResourceDir(NSBundle *self, SEL _cmd, NSString *name, NSString *ext, NSString *subpath) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        NSString *macPath = ShimMacResourceInDir(name, ext, subpath);
        if (macPath) return [NSURL fileURLWithPath:macPath];
    }
    return ((NSURL *(*)(id, SEL, id, id, id))gOrigURLForResourceDir)(self, _cmd, name, ext, subpath);
}

static NSString *ShimPrivateFrameworksPath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [gMacBundleRoot stringByAppendingPathComponent:@"Contents/Frameworks"];
    }
    return ((NSString *(*)(id, SEL))gOrigPrivateFrameworksPath)(self, _cmd);
}

static NSURL *ShimPrivateFrameworksURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [NSURL fileURLWithPath:ShimPrivateFrameworksPath(self, @selector(privateFrameworksPath)) isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL))gOrigPrivateFrameworksURL)(self, _cmd);
}

static NSString *ShimSharedSupportPath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [gMacBundleRoot stringByAppendingPathComponent:@"Contents/SharedSupport"];
    }
    return ((NSString *(*)(id, SEL))gOrigSharedSupportPath)(self, _cmd);
}

static NSURL *ShimSharedSupportURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [NSURL fileURLWithPath:ShimSharedSupportPath(self, @selector(sharedSupportPath)) isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL))gOrigSharedSupportURL)(self, _cmd);
}

static NSString *ShimBuiltInPlugInsPath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [gMacBundleRoot stringByAppendingPathComponent:@"Contents/PlugIns"];
    }
    return ((NSString *(*)(id, SEL))gOrigBuiltInPlugInsPath)(self, _cmd);
}

static NSURL *ShimBuiltInPlugInsURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacBundleRoot) {
        return [NSURL fileURLWithPath:ShimBuiltInPlugInsPath(self, @selector(builtInPlugInsPath)) isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL))gOrigBuiltInPlugInsURL)(self, _cmd);
}

static BOOL ShimIsMacFrameworkPath(NSString *path) {
    if (!path) return NO;
    return [path hasPrefix:@"/System/Library/Frameworks/"] &&
           ![[NSFileManager defaultManager] fileExistsAtPath:path];
}

static BOOL ShimIsMacFrameworkIdentifier(NSString *ident) {
    if (!ident) return NO;
    return [ident isEqualToString:@"com.apple.AppKit"] ||
           [ident isEqualToString:@"com.apple.Cocoa"] ||
           [ident isEqualToString:@"com.apple.CoreServices"] ||
           [ident isEqualToString:@"com.apple.ApplicationServices"] ||
           [ident isEqualToString:@"com.apple.Carbon"] ||
           [ident isEqualToString:@"com.apple.ExceptionHandling"] ||
           [ident isEqualToString:@"com.apple.Quartz"] ||
           [ident isEqualToString:@"com.apple.ScriptingBridge"] ||
           [ident isEqualToString:@"com.apple.DiskArbitration"] ||
           [ident isEqualToString:@"com.apple.ServiceManagement"] ||
           [ident isEqualToString:@"com.apple.SecurityFoundation"];
}

static NSBundle *ShimBundleWithPath(Class self, SEL _cmd, NSString *path) {
    if (gMacBundleRoot && path &&
        [path.stringByStandardizingPath isEqualToString:gMacBundleRoot.stringByStandardizingPath]) {
        return NSBundle.mainBundle;
    }
    NSBundle *res = ((NSBundle *(*)(id, SEL, id))gOrigBundleWithPath)(self, _cmd, path);
    if (!res && ShimIsMacFrameworkPath(path)) {
        return [NSBundle bundleForClass:NSString.class];
    }
    return res;
}

static NSBundle *ShimBundleWithURL(Class self, SEL _cmd, NSURL *url) {
    if (gMacBundleRoot && url.isFileURL &&
        [url.path.stringByStandardizingPath isEqualToString:gMacBundleRoot.stringByStandardizingPath]) {
        return NSBundle.mainBundle;
    }
    NSBundle *res = ((NSBundle *(*)(id, SEL, id))gOrigBundleWithURL)(self, _cmd, url);
    if (!res && url.isFileURL && ShimIsMacFrameworkPath(url.path)) {
        return [NSBundle bundleForClass:NSString.class];
    }
    return res;
}

static NSBundle *ShimBundleWithIdentifier(Class self, SEL _cmd, NSString *ident) {
    NSBundle *res = ((NSBundle *(*)(id, SEL, id))gOrigBundleWithIdentifier)(self, _cmd, ident);
    if (!res && ShimIsMacFrameworkIdentifier(ident)) {
        return [NSBundle bundleForClass:NSString.class];
    }
    return res;
}

static void ShimInstallBundleHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class bc = NSBundle.class;
        Class bmc = object_getClass(bc);
        gOrigBundlePath = method_setImplementation(class_getInstanceMethod(bc, @selector(bundlePath)), (IMP)ShimBundlePath);
        gOrigExecutablePath = method_setImplementation(class_getInstanceMethod(bc, @selector(executablePath)), (IMP)ShimExecutablePath);
        gOrigResourcePath = method_setImplementation(class_getInstanceMethod(bc, @selector(resourcePath)), (IMP)ShimResourcePath);
        gOrigPrivateFrameworksPath = method_setImplementation(class_getInstanceMethod(bc, @selector(privateFrameworksPath)), (IMP)ShimPrivateFrameworksPath);
        gOrigPrivateFrameworksURL = method_setImplementation(class_getInstanceMethod(bc, @selector(privateFrameworksURL)), (IMP)ShimPrivateFrameworksURL);
        gOrigSharedSupportPath = method_setImplementation(class_getInstanceMethod(bc, @selector(sharedSupportPath)), (IMP)ShimSharedSupportPath);
        gOrigSharedSupportURL = method_setImplementation(class_getInstanceMethod(bc, @selector(sharedSupportURL)), (IMP)ShimSharedSupportURL);
        gOrigBuiltInPlugInsPath = method_setImplementation(class_getInstanceMethod(bc, @selector(builtInPlugInsPath)), (IMP)ShimBuiltInPlugInsPath);
        gOrigBuiltInPlugInsURL = method_setImplementation(class_getInstanceMethod(bc, @selector(builtInPlugInsURL)), (IMP)ShimBuiltInPlugInsURL);
        gOrigBundleWithPath = method_setImplementation(class_getClassMethod(bc, @selector(bundleWithPath:)), (IMP)ShimBundleWithPath);
        gOrigBundleWithURL = method_setImplementation(class_getClassMethod(bc, @selector(bundleWithURL:)), (IMP)ShimBundleWithURL);
        gOrigBundleWithIdentifier = method_setImplementation(class_getClassMethod(bc, @selector(bundleWithIdentifier:)), (IMP)ShimBundleWithIdentifier);
        (void)bmc;
        gOrigBundleURL = method_setImplementation(class_getInstanceMethod(bc, @selector(bundleURL)), (IMP)ShimBundleURL);
        gOrigExecutableURL = method_setImplementation(class_getInstanceMethod(bc, @selector(executableURL)), (IMP)ShimExecutableURL);
        gOrigResourceURL = method_setImplementation(class_getInstanceMethod(bc, @selector(resourceURL)), (IMP)ShimResourceURL);
        gOrigPathForResource = method_setImplementation(class_getInstanceMethod(bc, @selector(pathForResource:ofType:)), (IMP)ShimPathForResource);
        gOrigURLForResource = method_setImplementation(class_getInstanceMethod(bc, @selector(URLForResource:withExtension:)), (IMP)ShimURLForResource);
        gOrigPathForResourceDir = method_setImplementation(class_getInstanceMethod(bc, @selector(pathForResource:ofType:inDirectory:)), (IMP)ShimPathForResourceDir);
        gOrigURLForResourceDir = method_setImplementation(class_getInstanceMethod(bc, @selector(URLForResource:withExtension:subdirectory:)), (IMP)ShimURLForResourceDir);
        gOrigInfoDictionary = method_setImplementation(class_getInstanceMethod(bc, @selector(infoDictionary)), (IMP)ShimInfoDictionary);
        gOrigObjectForInfoKey = method_setImplementation(class_getInstanceMethod(bc, @selector(objectForInfoDictionaryKey:)), (IMP)ShimObjectForInfoKey);
        gOrigBundleIdentifier = method_setImplementation(class_getInstanceMethod(bc, @selector(bundleIdentifier)), (IMP)ShimBundleIdentifier);
    });
}

static IMP gSupportsFamily, gBufLen, gBufBytes, gLibData;

static BOOL ShimSupportsFamily(id self, SEL _cmd, MTLGPUFamily family) {
    if (family == MTLGPUFamilyMac2) return YES;
    return ((BOOL (*)(id, SEL, MTLGPUFamily))gSupportsFamily)(self, _cmd, family);
}

static NSUInteger ShimFixResourceOptions(NSUInteger options) {
    const NSUInteger managed = 1UL << MTLResourceStorageModeShift;
    if ((options & MTLResourceStorageModeMask) == managed) {
        return (options & ~MTLResourceStorageModeMask) | MTLResourceStorageModeShared;
    }
    return options;
}

static id ShimBufLen(id self, SEL _cmd, NSUInteger len, NSUInteger opts) {
    return ((id (*)(id, SEL, NSUInteger, NSUInteger))gBufLen)(self, _cmd, len, ShimFixResourceOptions(opts));
}

static id ShimBufBytes(id self, SEL _cmd, const void *p, NSUInteger len, NSUInteger opts) {
    return ((id (*)(id, SEL, const void *, NSUInteger, NSUInteger))gBufBytes)(self, _cmd, p, len, ShimFixResourceOptions(opts));
}

static id ShimLibData(id self, SEL _cmd, dispatch_data_t data, NSError **error) {
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, id, NSError **))gLibData)(self, _cmd, data, &e);
    NSData *bytes = (NSData *)data;
    if (!lib && bytes.length > 8 && !memcmp(bytes.bytes, "MTLB", 4) && (((const uint8_t *)bytes.bytes)[5] & 0x80)) {
        NSMutableData *ios = [bytes mutableCopy];
        ((uint8_t *)ios.mutableBytes)[5] &= 0x7f;
        dispatch_data_t d = dispatch_data_create(ios.bytes, ios.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *e2 = nil;
        lib = ((id (*)(id, SEL, id, NSError **))gLibData)(self, _cmd, d, &e2);
        if (lib) e = nil;
    }
    if (error) *error = e;
    return lib;
}

__attribute__((constructor)) static void ShimMetalInit(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    Class dc = object_getClass(dev);
    Method m = class_getInstanceMethod(dc, @selector(supportsFamily:));
    if (m) gSupportsFamily = method_setImplementation(m, (IMP)ShimSupportsFamily);
    m = class_getInstanceMethod(dc, @selector(newBufferWithLength:options:));
    if (m) gBufLen = method_setImplementation(m, (IMP)ShimBufLen);
    m = class_getInstanceMethod(dc, @selector(newBufferWithBytes:length:options:));
    if (m) gBufBytes = method_setImplementation(m, (IMP)ShimBufBytes);
    m = class_getInstanceMethod(dc, @selector(newLibraryWithData:error:));
    if (m) gLibData = method_setImplementation(m, (IMP)ShimLibData);
}

// MARK: NSEvent

typedef NS_ENUM(NSUInteger, NSEventType) {
    NSEventTypeLeftMouseDown = 1,
    NSEventTypeLeftMouseUp = 2,
    NSEventTypeMouseMoved = 5,
    NSEventTypeLeftMouseDragged = 6,
    NSEventTypeKeyDown = 10,
    NSEventTypeKeyUp = 11,
    NSEventTypeFlagsChanged = 12,
    NSEventTypeScrollWheel = 22,
};

__attribute__((visibility("default")))
@interface NSEvent : NSObject
@property NSEventType type;
@property CGPoint locationInWindow;
@property NSTimeInterval timestamp;
@property (weak) NSWindow *window;
@property NSInteger clickCount;
@property NSInteger buttonNumber;
@property NSUInteger modifierFlags;
@property unsigned short keyCode;
@property (copy) NSString *characters;
@property (copy) NSString *charactersIgnoringModifiers;
@property BOOL isARepeat;
@property BOOL hasPreciseScrollingDeltas;
@property CGFloat scrollingDeltaX, scrollingDeltaY, deltaX, deltaY;
@end

static NSMutableArray *gMonitors;
static NSUInteger gModifiers;
static CGPoint gMouseLocation;

@implementation NSEvent
SHIM_RESOLVE
+ (id)addLocalMonitorForEventsMatchingMask:(uint64_t)mask handler:(NSEvent *(^)(NSEvent *))handler {
    if (!gMonitors) gMonitors = [NSMutableArray new];
    id token = @[@(mask), [handler copy]];
    [gMonitors addObject:token];
    return token;
}
+ (void)removeMonitor:(id)token { [gMonitors removeObject:token]; }
+ (NSUInteger)modifierFlags { return gModifiers; }
+ (CGPoint)mouseLocation { return gMouseLocation; }
+ (NSUInteger)pressedMouseButtons { return 0; }
@end

// MARK: NSColor

__attribute__((visibility("default")))
@interface NSColor : NSObject
@property (nonatomic, strong, readonly) UIColor *uiColor;
@end

@implementation NSColor
SHIM_RESOLVE

- (instancetype)initWithUIColor:(UIColor *)c {
    if ((self = [super init])) {
        _uiColor = c ?: UIColor.clearColor;
    }
    return self;
}

+ (instancetype)colorWithUIColor:(UIColor *)c {
    return [[self alloc] initWithUIColor:c];
}

+ (NSColor *)blackColor { return [self colorWithUIColor:UIColor.blackColor]; }
+ (NSColor *)darkGrayColor { return [self colorWithUIColor:UIColor.darkGrayColor]; }
+ (NSColor *)lightGrayColor { return [self colorWithUIColor:UIColor.lightGrayColor]; }
+ (NSColor *)whiteColor { return [self colorWithUIColor:UIColor.whiteColor]; }
+ (NSColor *)grayColor { return [self colorWithUIColor:UIColor.grayColor]; }
+ (NSColor *)redColor { return [self colorWithUIColor:UIColor.redColor]; }
+ (NSColor *)greenColor { return [self colorWithUIColor:UIColor.greenColor]; }
+ (NSColor *)blueColor { return [self colorWithUIColor:UIColor.blueColor]; }
+ (NSColor *)yellowColor { return [self colorWithUIColor:UIColor.yellowColor]; }
+ (NSColor *)cyanColor { return [self colorWithUIColor:UIColor.cyanColor]; }
+ (NSColor *)magentaColor { return [self colorWithUIColor:UIColor.magentaColor]; }
+ (NSColor *)orangeColor { return [self colorWithUIColor:UIColor.orangeColor]; }
+ (NSColor *)purpleColor { return [self colorWithUIColor:UIColor.purpleColor]; }
+ (NSColor *)brownColor { return [self colorWithUIColor:UIColor.brownColor]; }
+ (NSColor *)clearColor { return [self colorWithUIColor:UIColor.clearColor]; }
+ (NSColor *)windowBackgroundColor { return [self colorWithUIColor:[UIColor colorWithRed:0.12 green:0.13 blue:0.16 alpha:1.0]]; }
+ (NSColor *)controlBackgroundColor { return [self colorWithUIColor:UIColor.secondarySystemBackgroundColor]; }
+ (NSColor *)labelColor { return [self colorWithUIColor:UIColor.labelColor]; }
+ (NSColor *)secondaryLabelColor { return [self colorWithUIColor:UIColor.secondaryLabelColor]; }
+ (NSColor *)tertiaryLabelColor { return [self colorWithUIColor:UIColor.tertiaryLabelColor]; }
+ (NSColor *)quaternaryLabelColor { return [self colorWithUIColor:UIColor.quaternaryLabelColor]; }
+ (NSColor *)linkColor { return [self colorWithUIColor:UIColor.linkColor]; }
+ (NSColor *)placeholderTextColor { return [self colorWithUIColor:UIColor.placeholderTextColor]; }
+ (NSColor *)textColor { return [self colorWithUIColor:UIColor.labelColor]; }
+ (NSColor *)textBackgroundColor { return [self colorWithUIColor:UIColor.systemBackgroundColor]; }
+ (NSColor *)controlColor { return [self colorWithUIColor:UIColor.secondarySystemFillColor]; }
+ (NSColor *)controlTextColor { return [self colorWithUIColor:UIColor.labelColor]; }
+ (NSColor *)selectedTextColor { return [self colorWithUIColor:UIColor.whiteColor]; }
+ (NSColor *)selectedTextBackgroundColor { return [self colorWithUIColor:UIColor.systemBlueColor]; }
+ (NSColor *)selectedContentBackgroundColor { return [self colorWithUIColor:UIColor.systemBlueColor]; }
+ (NSColor *)unemphasizedSelectedContentBackgroundColor { return [self colorWithUIColor:UIColor.systemGray4Color]; }
+ (NSColor *)separatorColor { return [self colorWithUIColor:UIColor.separatorColor]; }
+ (NSColor *)gridColor { return [self colorWithUIColor:UIColor.separatorColor]; }
+ (NSColor *)systemBlueColor { return [self colorWithUIColor:UIColor.systemBlueColor]; }
+ (NSColor *)systemRedColor { return [self colorWithUIColor:UIColor.systemRedColor]; }
+ (NSColor *)systemGreenColor { return [self colorWithUIColor:UIColor.systemGreenColor]; }
+ (NSColor *)systemOrangeColor { return [self colorWithUIColor:UIColor.systemOrangeColor]; }
+ (NSColor *)systemYellowColor { return [self colorWithUIColor:UIColor.systemYellowColor]; }
+ (NSColor *)systemGrayColor { return [self colorWithUIColor:UIColor.systemGrayColor]; }

+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [self colorWithUIColor:[UIColor colorWithRed:r green:g blue:b alpha:a]];
}
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [self colorWithRed:r green:g blue:b alpha:a];
}
+ (NSColor *)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [self colorWithRed:r green:g blue:b alpha:a];
}
+ (NSColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a {
    return [self colorWithUIColor:[UIColor colorWithWhite:w alpha:a]];
}
+ (NSColor *)colorWithCalibratedWhite:(CGFloat)w alpha:(CGFloat)a {
    return [self colorWithWhite:w alpha:a];
}
- (CGColorRef)CGColor { return _uiColor.CGColor; }
- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha {
    return [NSColor colorWithUIColor:[_uiColor colorWithAlphaComponent:alpha]];
}
- (void)set { [_uiColor set]; }
- (void)setFill { [_uiColor setFill]; }
- (void)setStroke { [_uiColor setStroke]; }
@end

// MARK: NSResponder

__attribute__((visibility("default")))
@interface NSResponder : NSObject
@property (nonatomic, weak) NSResponder *nextResponder;
@end

@implementation NSResponder
SHIM_RESOLVE
- (instancetype)initWithCoder:(NSCoder *)coder {
    (void)coder;
    return [self init];
}
#define SHIM_FORWARD(sel) - (void)sel(NSEvent *)e { [self.nextResponder sel e]; }
SHIM_FORWARD(mouseDown:)
SHIM_FORWARD(mouseUp:)
SHIM_FORWARD(mouseDragged:)
SHIM_FORWARD(mouseMoved:)
SHIM_FORWARD(rightMouseDown:)
SHIM_FORWARD(rightMouseUp:)
SHIM_FORWARD(scrollWheel:)
SHIM_FORWARD(keyDown:)
SHIM_FORWARD(keyUp:)
SHIM_FORWARD(flagsChanged:)
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
@end

// MARK: NSView

static void ShimDispatchEvent(NSEvent *e);

static void ShimPerformUserAction(void (^action)(void)) {
    gUserActionDepth++;
    @try {
        action();
    } @finally {
        gUserActionDepth--;
    }
}

// Convert AppKit autoresizing mask (MinY=8 bottom, MaxY=32 top) to UIKit (Top=8, Bottom=32).
static UIViewAutoresizing ShimMapAutoresizingMask(NSUInteger mask) {
    UIViewAutoresizing out = UIViewAutoresizingNone;
    if (mask & 1) out |= UIViewAutoresizingFlexibleLeftMargin;
    if (mask & 2) out |= UIViewAutoresizingFlexibleWidth;
    if (mask & 4) out |= UIViewAutoresizingFlexibleRightMargin;
    if (mask & 8) out |= UIViewAutoresizingFlexibleBottomMargin;
    if (mask & 16) out |= UIViewAutoresizingFlexibleHeight;
    if (mask & 32) out |= UIViewAutoresizingFlexibleTopMargin;
    return out;
}

@interface ShimHostView : UIView
@property (nonatomic, weak) NSView *nsView;
@end

__attribute__((visibility("default")))
@interface NSView : NSResponder {
@protected
    CGRect _nsFrame;
    NSUInteger _nsAutoresizingMask;
}
@property (nonatomic) CGRect frame;
@property (nonatomic) BOOL wantsLayer;
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, readonly) ShimHostView *hostView;
@property (nonatomic, weak) NSView *superview;
@property (nonatomic, readonly) NSMutableArray<NSView *> *shimSubviews;
@property (nonatomic) NSUInteger autoresizingMask;
- (instancetype)initWithFrame:(CGRect)frame;
- (CGRect)bounds;
- (BOOL)isFlipped;
- (void)addSubview:(NSView *)v;
- (void)removeFromSuperview;
- (NSView *)hitTest:(CGPoint)p;
- (CGPoint)convertPoint:(CGPoint)p fromView:(NSView *)view;
- (CGPoint)convertPoint:(CGPoint)p toView:(NSView *)view;
@end

static void ShimSyncHostFrame(NSView *v) {
    if (!v || !v.hostView) return;
    CGRect f = v.frame;
    if (v.superview) {
        CGFloat supH = v.superview.bounds.size.height;
        CGFloat uiY = v.superview.isFlipped ? f.origin.y : (supH - f.origin.y - f.size.height);
        v.hostView.frame = CGRectMake(f.origin.x, uiY, f.size.width, f.size.height);
    } else if (!v.window) {
        v.hostView.frame = CGRectMake(f.origin.x, f.origin.y, f.size.width, f.size.height);
    }
}

@implementation NSView
SHIM_RESOLVE

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super init])) {
        _nsFrame = frame;
        _hostView = [[ShimHostView alloc] initWithFrame:CGRectMake(frame.origin.x, frame.origin.y,
                                                                   frame.size.width, frame.size.height)];
        _hostView.nsView = self;
    }
    return self;
}

- (instancetype)init {
    return [self initWithFrame:CGRectZero];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    NSString *frameStr = [coder decodeObjectForKey:@"NSFrame"];
    CGRect frame = (frameStr && [frameStr isKindOfClass:NSString.class] && frameStr.length)
        ? CGRectFromString(frameStr)
        : CGRectZero;
    if ((self = [self initWithFrame:frame])) {
        if ([coder containsValueForKey:@"NSvFlags"]) {
            NSInteger vFlags = [coder decodeIntegerForKey:@"NSvFlags"];
            self.autoresizingMask = (NSUInteger)(vFlags & 0x3F);
            if (vFlags & 0x80000000L) self.hidden = YES;
        }
        NSArray *subs = [coder decodeObjectForKey:@"NSSubviews"];
        if ([subs isKindOfClass:NSArray.class]) {
            for (id sub in subs) {
                if ([sub isKindOfClass:NSView.class]) [self addSubview:sub];
            }
        }
    }
    return self;
}

- (CGRect)frame {
    return _nsFrame;
}

- (void)setFrame:(CGRect)frame {
    _nsFrame = frame;
    ShimSyncHostFrame(self);
    for (NSView *sub in _shimSubviews) {
        ShimSyncHostFrame(sub);
    }
}

- (void)setFrameSize:(CGSize)newSize {
    CGRect f = _nsFrame;
    f.size = newSize;
    self.frame = f;
}

- (void)setFrameOrigin:(CGPoint)newOrigin {
    CGRect f = _nsFrame;
    f.origin = newOrigin;
    self.frame = f;
}

- (CGRect)bounds {
    return CGRectMake(0, 0, _nsFrame.size.width, _nsFrame.size.height);
}

- (void)setAutoresizingMask:(NSUInteger)mask {
    _nsAutoresizingMask = mask;
    _hostView.autoresizingMask = ShimMapAutoresizingMask(mask);
}

- (NSUInteger)autoresizingMask {
    return _nsAutoresizingMask;
}

- (void)setLayer:(CALayer *)layer {
    [_layer removeFromSuperlayer];
    _layer = layer;
    layer.frame = _hostView.bounds;
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        layer.opaque = YES;
    }
    [_hostView.layer addSublayer:layer];
}

- (void)setWantsLayer:(BOOL)flag {
    _wantsLayer = flag;
    if (flag && !_layer) {
        self.layer = [self makeBackingLayer];
    }
}

- (CALayer *)makeBackingLayer {
    return [CALayer layer];
}

- (NSArray<NSView *> *)subviews {
    return _shimSubviews ? [_shimSubviews copy] : @[];
}

- (void)addSubview:(NSView *)v {
    if (!v || v == self) return;
    if (!_shimSubviews) _shimSubviews = [NSMutableArray new];
    [v removeFromSuperview];
    [_shimSubviews addObject:v];
    v.superview = self;
    [_hostView addSubview:v.hostView];
    ShimSyncHostFrame(v);
}

- (void)removeFromSuperview {
    [_superview.shimSubviews removeObject:self];
    _superview = nil;
    [_hostView removeFromSuperview];
}

- (NSWindow *)window {
    return _window ?: _superview.window;
}

- (NSResponder *)nextResponder {
    return [super nextResponder] ?: (_superview ?: (NSResponder *)self.window);
}

- (BOOL)isHidden { return _hostView.hidden; }
- (void)setHidden:(BOOL)h { _hostView.hidden = h; }
- (BOOL)isHiddenOrHasHiddenAncestor {
    for (NSView *v = self; v; v = v.superview) {
        if (v.isHidden) return YES;
    }
    return NO;
}
- (BOOL)isFlipped { return NO; }
- (void)setAutoresizesSubviews:(BOOL)flag { _hostView.autoresizesSubviews = flag; }
- (void)setNeedsDisplay:(BOOL)flag { (void)flag; [_hostView setNeedsDisplay]; }
- (void)setLayerContentsRedrawPolicy:(NSInteger)policy { (void)policy; }
- (void)addTrackingArea:(id)area { (void)area; }
- (void)removeTrackingArea:(id)area { (void)area; }
- (NSArray *)trackingAreas { return @[]; }

- (NSLayoutXAxisAnchor *)leadingAnchor { return _hostView.leadingAnchor; }
- (NSLayoutXAxisAnchor *)trailingAnchor { return _hostView.trailingAnchor; }
- (NSLayoutXAxisAnchor *)leftAnchor { return _hostView.leftAnchor; }
- (NSLayoutXAxisAnchor *)rightAnchor { return _hostView.rightAnchor; }
- (NSLayoutYAxisAnchor *)topAnchor { return _hostView.topAnchor; }
- (NSLayoutYAxisAnchor *)bottomAnchor { return _hostView.bottomAnchor; }
- (NSLayoutDimension *)widthAnchor { return _hostView.widthAnchor; }
- (NSLayoutDimension *)heightAnchor { return _hostView.heightAnchor; }
- (NSLayoutXAxisAnchor *)centerXAnchor { return _hostView.centerXAnchor; }
- (NSLayoutYAxisAnchor *)centerYAnchor { return _hostView.centerYAnchor; }
- (BOOL)translatesAutoresizingMaskIntoConstraints { return _hostView.translatesAutoresizingMaskIntoConstraints; }
- (void)setTranslatesAutoresizingMaskIntoConstraints:(BOOL)flag { _hostView.translatesAutoresizingMaskIntoConstraints = flag; }
- (id)nsli_layoutAnchorForAttribute:(NSInteger)attr { (void)attr; return nil; }
- (void)addConstraint:(id)c { if ([c isKindOfClass:NSLayoutConstraint.class]) [_hostView addConstraint:c]; }
- (void)removeConstraint:(id)c { if ([c isKindOfClass:NSLayoutConstraint.class]) [_hostView removeConstraint:c]; }
- (void)addConstraints:(NSArray *)cs {
    for (id c in cs) [self addConstraint:c];
}
- (NSArray *)constraints { return _hostView.constraints; }

- (NSView *)hitTest:(CGPoint)p {
    if (!CGRectContainsPoint(self.bounds, p) || self.isHidden) return nil;
    for (NSView *v in _shimSubviews.reverseObjectEnumerator) {
        NSView *hit = [v hitTest:CGPointMake(p.x - v.frame.origin.x, p.y - v.frame.origin.y)];
        if (hit) return hit;
    }
    return self;
}

- (CGPoint)convertPoint:(CGPoint)p fromView:(NSView *)view {
    NSView *src = view ?: (self.window ? [(id)self.window valueForKey:@"contentView"] : nil);
    if (!src || src == self) return p;
    CGFloat srcUIY = src.isFlipped ? p.y : (src.bounds.size.height - p.y);
    CGPoint localUI = [self.hostView convertPoint:CGPointMake(p.x, srcUIY) fromView:src.hostView];
    CGFloat dstNSY = self.isFlipped ? localUI.y : (self.bounds.size.height - localUI.y);
    return CGPointMake(localUI.x, dstNSY);
}

- (CGPoint)convertPoint:(CGPoint)p toView:(NSView *)view {
    NSView *dst = view ?: (self.window ? [(id)self.window valueForKey:@"contentView"] : nil);
    if (!dst || dst == self) return p;
    return [dst convertPoint:p fromView:self];
}

// Internal hook called by ShimHostView.layoutSubviews when UIKit resizes the backing UIView.
- (void)shimUpdateFromHostLayout {
    CGRect hf = _hostView.frame;
    if (_superview) {
        CGFloat supH = _superview.bounds.size.height;
        CGFloat nsY = _superview.isFlipped ? hf.origin.y : (supH - hf.origin.y - hf.size.height);
        _nsFrame = CGRectMake(hf.origin.x, nsY, hf.size.width, hf.size.height);
    } else {
        _nsFrame = _hostView.bounds;
    }
    for (CALayer *l in _hostView.layer.sublayers) {
        if (l == _layer || [l isKindOfClass:CAMetalLayer.class]) {
            l.frame = _hostView.bounds;
            l.contentsScale = _hostView.traitCollection.displayScale ?: 2.0;
        }
    }
}

@end

@implementation ShimHostView

- (void)layoutSubviews {
    [super layoutSubviews];
    [self.nsView shimUpdateFromHostLayout];
    for (NSView *sub in self.nsView.shimSubviews) {
        [sub shimUpdateFromHostLayout];
    }
}

- (NSEvent *)eventOfType:(NSEventType)type atUIKitPoint:(CGPoint)uiPt {
    NSWindow *win = self.nsView.window;
    NSView *content = win ? [(id)win valueForKey:@"contentView"] : self.nsView;
    CGPoint inContent = [content.hostView convertPoint:uiPt fromView:self];
    CGFloat nsY = content.isFlipped ? inContent.y : (content.bounds.size.height - inContent.y);
    NSEvent *e = [NSEvent new];
    e.type = type;
    e.locationInWindow = CGPointMake(inContent.x, nsY);
    gMouseLocation = e.locationInWindow;
    e.timestamp = NSProcessInfo.processInfo.systemUptime;
    e.window = win;
    e.modifierFlags = gModifiers;
    return e;
}

- (void)dispatchTouches:(NSSet<UITouch *> *)touches type:(NSEventType)type {
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    NSEvent *e = [self eventOfType:type atUIKitPoint:p];
    e.clickCount = MAX(1, (NSInteger)t.tapCount);
    ShimPerformUserAction(^{ ShimDispatchEvent(e); });
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self dispatchTouches:touches type:NSEventTypeLeftMouseDown];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self dispatchTouches:touches type:NSEventTypeLeftMouseDragged];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self dispatchTouches:touches type:NSEventTypeLeftMouseUp];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self dispatchTouches:touches type:NSEventTypeLeftMouseUp];
}

@end

// MARK: NSControl & NSButton

@class NSFont;

__attribute__((visibility("default")))
@interface NSActionCell : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic) NSUInteger controlSize;
@property (nonatomic) NSInteger state;
@property (nonatomic) NSInteger tag;
@property (nonatomic) BOOL editable;
@property (nonatomic) BOOL selectable;
@property (nonatomic) BOOL bordered;
@property (nonatomic) BOOL bezeled;
@property (nonatomic, copy) NSString *keyEquivalent;
@property (nonatomic) NSInteger shimButtonType;   // NSAuxButtonType: 3 checkbox, 4 radio, 7 push
@property (nonatomic) NSInteger shimBezelStyle;
@end

__attribute__((visibility("default")))
@interface NSControl : NSView
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, strong) id cell;
@property (nonatomic, strong) NSFont *font;
- (BOOL)sendAction:(SEL)action to:(id)target;
@end

@implementation NSControl
SHIM_RESOLVE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _enabled = YES;
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        // In Mac NIBArchives NSControl often encodes NSEnabled=NO while NSCellFlags tracks actual enabled state.
        _enabled = YES;
        _cell = [coder decodeObjectForKey:@"NSCell"];
    }
    return self;
}
- (id)cell {
    if (!_cell) {
        Class cls = NSClassFromString(@"NSActionCell");
        _cell = cls ? [cls new] : nil;
    }
    return _cell;
}
- (BOOL)sendAction:(SEL)action to:(id)target {
    SEL sel = action ?: self.action;
    id tgt = target ?: self.target;
    if (!sel || !tgt) return NO;
    if (![tgt respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(tgt, sel, self);
    return YES;
}
@end

__attribute__((visibility("default")))
@interface NSButton : NSControl
@property (nonatomic, copy) NSString *title;
@property (nonatomic) NSUInteger bezelStyle;
@property (nonatomic) NSInteger state;
@property (nonatomic, copy) NSString *keyEquivalent;
@property (nonatomic, strong, readonly) UIButton *uiButton;
+ (instancetype)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action;
+ (instancetype)buttonWithTitle:(NSString *)title image:(id)image target:(id)target action:(SEL)action;
@end

@implementation NSButton {
    NSInteger _shimType;
}
SHIM_RESOLVE

- (void)shimSetupUIButtonWithFrame:(CGRect)frame {
    (void)frame;
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.baseBackgroundColor = [UIColor colorWithRed:0.16 green:0.45 blue:0.95 alpha:1.0];
    cfg.baseForegroundColor = UIColor.whiteColor;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *d = [incoming mutableCopy];
        d[NSFontAttributeName] = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        return d;
    };
    cfg.title = @"Button";

    _uiButton = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    _uiButton.frame = self.hostView.bounds;
    _uiButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _uiButton.accessibilityIdentifier = @"NSButton";
    [_uiButton addTarget:self action:@selector(shimTouchDown) forControlEvents:UIControlEventTouchDown];
    [_uiButton addTarget:self action:@selector(shimTouchUpInside) forControlEvents:UIControlEventTouchUpInside];
    [self.hostView addSubview:_uiButton];
    _title = @"Button";
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self shimSetupUIButtonWithFrame:frame];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        [self shimSetupUIButtonWithFrame:self.frame];
        id cell = [coder decodeObjectForKey:@"NSCell"];
        if (cell && [cell respondsToSelector:@selector(title)]) {
            NSString *t = [cell title];
            if (t.length) self.title = t;
        }
        if ([cell isKindOfClass:NSActionCell.class]) {
            NSActionCell *c = cell;
            if (c.font) self.font = c.font;
            _keyEquivalent = [c.keyEquivalent copy];
            _shimType = c.shimButtonType;
            _state = c.state;
        }
        [self shimApplyStyle];
    }
    return self;
}

+ (instancetype)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action {
    NSButton *btn = [[self alloc] initWithFrame:CGRectMake(0, 0, 140, 40)];
    btn.title = title ?: @"";
    btn.target = target;
    btn.action = action;
    [btn sizeToFit];
    return btn;
}

+ (instancetype)buttonWithTitle:(NSString *)title image:(id)image target:(id)target action:(SEL)action {
    (void)image;
    return [self buttonWithTitle:title target:target action:action];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy] ?: @"";
    UIButtonConfiguration *cfg = _uiButton.configuration ?: [UIButtonConfiguration filledButtonConfiguration];
    cfg.title = _title;
    _uiButton.configuration = cfg;
    _uiButton.accessibilityLabel = _title;
}

- (void)setFont:(NSFont *)font {
    [super setFont:font];
    if (_uiButton) [self shimApplyStyle];
}

- (id)cell {
    id c = [super cell];
    if (![c isKindOfClass:NSClassFromString(@"NSButtonCell")]) {
        Class cls = NSClassFromString(@"NSButtonCell");
        if (cls) {
            c = [cls new];
            self.cell = c;
        }
    }
    return c;
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    _uiButton.enabled = enabled;
}

- (void)setButtonType:(NSUInteger)type {
    // NSButtonType: 3 switch (checkbox), 4 radio, everything else draws as a push button here.
    _shimType = (NSInteger)type;
    [self shimApplyStyle];
}

- (BOOL)shimIsChoice { return _shimType == 3 || _shimType == 4; }

- (void)shimApplyStyle {
    UIButtonConfiguration *cfg;
    if ([self shimIsChoice]) {
        BOOL radio = _shimType == 4;
        cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);
        cfg.imagePadding = 6.0;
        cfg.baseForegroundColor = UIColor.labelColor;
        NSString *sym = radio ? (_state ? @"largecircle.fill.circle" : @"circle")
                              : (_state ? @"checkmark.square.fill" : @"square");
        cfg.image = [[UIImage systemImageNamed:sym withConfiguration:
                      [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightRegular]]
                     imageWithTintColor:(_state ? UIColor.systemBlueColor : UIColor.secondaryLabelColor)
                          renderingMode:UIImageRenderingModeAlwaysOriginal];
        _uiButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    } else {
        cfg = [UIButtonConfiguration filledButtonConfiguration];
        BOOL isDefault = [_keyEquivalent isEqualToString:@"\r"];
        cfg.baseBackgroundColor = isDefault ? UIColor.systemBlueColor
            : [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
                return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0.40 alpha:1] : [UIColor colorWithWhite:0.96 alpha:1];
            }];
        cfg.baseForegroundColor = isDefault ? UIColor.whiteColor : UIColor.labelColor;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleSmall;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(3.0, 10.0, 3.0, 10.0);
        _uiButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    }
    UIFont *font = (UIFont *)[(id)self.font valueForKey:@"uiFont"] ?: [UIFont systemFontOfSize:13.0];
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *d = [incoming mutableCopy];
        d[NSFontAttributeName] = font;
        return d;
    };
    cfg.title = _title;
    _uiButton.configuration = cfg;
}

- (void)setState:(NSInteger)state {
    _state = state;
    if ([self shimIsChoice]) [self shimApplyStyle];
}

- (void)setKeyEquivalent:(NSString *)keyEquivalent {
    _keyEquivalent = [keyEquivalent copy];
    [self shimApplyStyle];
}

- (void)sizeToFit {
    [_uiButton sizeToFit];
    CGRect f = self.frame;
    f.size.width = MAX(88.0, _uiButton.bounds.size.width + 24.0);
    f.size.height = MAX(36.0, _uiButton.bounds.size.height + 8.0);
    self.frame = f;
}

- (void)shimTouchDown {
    NSEvent *e = [NSEvent new];
    e.type = NSEventTypeLeftMouseDown;
    e.timestamp = NSProcessInfo.processInfo.systemUptime;
    e.window = self.window;
    e.clickCount = 1;
    fprintf(stderr, "NSButton mouseDown (%s)\n", _title.UTF8String);
    fflush(stderr);
    [self mouseDown:e];
}

- (void)shimTouchUpInside {
    fprintf(stderr, "NSButton click (%s)\n", _title.UTF8String);
    fflush(stderr);
    if (_shimType == 3) self.state = !_state;
    if (_shimType == 4) {
        for (NSView *sib in self.superview.shimSubviews) {
            if (sib != (NSView *)self && [sib isKindOfClass:NSButton.class] && ((NSButton *)sib)->_shimType == 4 &&
                ((NSButton *)sib).action == self.action) ((NSButton *)sib).state = 0;
        }
        self.state = 1;
    }
    [self.hostView.window endEditing:YES]; // commit any field being edited, as a Mac click does
    ShimPerformUserAction(^{ [self sendAction:self.action to:self.target]; });
}

@end

// MARK: NSViewController

@interface NSBundle (ShimNibLoadingFwd)
- (BOOL)loadNibNamed:(NSString *)nibName owner:(id)owner topLevelObjects:(NSArray **)topLevelObjects;
@end

__attribute__((visibility("default")))
@interface NSViewController : NSResponder
@property (nonatomic, strong) NSView *view;
@property (nonatomic, copy) NSString *nibName;
@property (nonatomic, strong) NSBundle *nibBundle;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) id representedObject;
- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil;
@end

@implementation NSViewController
SHIM_RESOLVE
- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    if ((self = [super init])) {
        _nibName = [nibNameOrNil copy];
        _nibBundle = nibBundleOrNil ?: NSBundle.mainBundle;
    }
    return self;
}
- (NSView *)view {
    if (!_view) {
        [self loadView];
        if (!_view) _view = [NSView new];
        if ([self respondsToSelector:@selector(viewDidLoad)]) [self performSelector:@selector(viewDidLoad)];
    }
    return _view;
}
- (void)loadView {
    if (_nibName.length) {
        NSArray *tops = nil;
        [(_nibBundle ?: NSBundle.mainBundle) loadNibNamed:_nibName owner:self topLevelObjects:&tops];
        if (!_view) {
            for (id o in tops) {
                if ([o isKindOfClass:NSView.class]) { _view = o; break; }
            }
        }
    }
}
@end

// MARK: NSScreen

__attribute__((visibility("default")))
@interface NSScreen : NSObject
+ (instancetype)mainScreen;
+ (NSArray<NSScreen *> *)screens;
- (CGRect)frame;
- (CGRect)visibleFrame;
- (CGFloat)backingScaleFactor;
@end

static UIView *ShimActiveHostView(void) {
    return gHostContainer ?: gRootVC.view;
}

@implementation NSScreen
SHIM_RESOLVE
+ (instancetype)mainScreen {
    static NSScreen *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSScreen new]; });
    return s;
}
+ (NSArray<NSScreen *> *)screens { return @[[self mainScreen]]; }
- (CGRect)frame {
    UIView *v = ShimActiveHostView();
    return v ? v.bounds : CGRectMake(0, 0, 390, 760);
}
- (CGRect)visibleFrame {
    CGRect f = [self frame];
    CGFloat titleH = gHostFullscreen ? 0 : 34.0;
    if (f.size.height > titleH + 40.0) f.size.height -= titleH;
    return f;
}
- (NSDictionary *)deviceDescription {
    return @{@"NSScreenNumber": @1, @"NSDeviceSize": [NSValue valueWithCGSize:[self frame].size]};
}
- (NSString *)localizedName { return @"iOS Host Screen"; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond; }
- (CGFloat)backingScaleFactor {
    UIView *v = ShimActiveHostView();
    return v ? (v.traitCollection.displayScale ?: 2.0) : UIScreen.mainScreen.scale;
}
@end

// MARK: NSWindow

@interface ShimSheetSession : NSObject
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, copy) void (^completion)(NSInteger);
@end
@implementation ShimSheetSession
@end

__attribute__((visibility("default")))
@interface NSWindow : NSResponder
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSViewController *contentViewController;
@property (nonatomic, weak) id windowController;
@property (nonatomic, weak) id delegate;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic) CGRect frame;
@property (nonatomic) CGSize shimDesignSize;
@property (nonatomic) BOOL acceptsMouseMovedEvents;
@property (nonatomic) NSUInteger styleMask;
@property (nonatomic, weak) id shimFirstResponder;
@property (nonatomic, strong, readonly) UIView *chromeView;
@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, weak, readonly) NSWindow *sheetParent;
@property (nonatomic, strong, readonly) NSWindow *attachedSheet;
@property (nonatomic, readonly) BOOL isSheet;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)beginSheet:(NSWindow *)sheet completionHandler:(void (^)(NSInteger))handler;
- (void)endSheet:(NSWindow *)sheet returnCode:(NSInteger)code;
- (UIView *)shimSheetBackdrop;
@end

static void ShimNotifyWindow(NSWindow *w, NSString *suffix) {
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"window%@:", suffix]);
    NSNotification *n = [NSNotification notificationWithName:[NSString stringWithFormat:@"NSWindow%@Notification", suffix] object:w];
    if ([w.delegate respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(w.delegate, sel, n);
    [NSNotificationCenter.defaultCenter postNotification:n];
}

// The smallest size a window's SwiftUI content accepts when offered `available` (its own minimum if larger).
static CGSize ShimHostedMinimumSize(UIView *root, CGSize available) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < 64; i++) {
        UIView *v = queue[i];
        if (v != root && [NSStringFromClass(v.class) containsString:@"HostingView"]) {
            return [v sizeThatFits:available];
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return CGSizeZero;
}

static void ShimLayoutWindow(NSWindow *w, BOOL activate) {
    UIView *parent = ShimActiveHostView();
    CGRect hostBounds = parent.bounds;
    if (!parent || !w.contentView || ![gWindows containsObject:w] || hostBounds.size.width < 1.0 || hostBounds.size.height < 1.0) {
        fprintf(stderr, "NSWindow ShimAttachWindow '%s' not attached: host=%p (%.0fx%.0f) contentView=%p listed=%d\n",
                w.title.UTF8String ?: "", (__bridge void *)parent, hostBounds.size.width, hostBounds.size.height,
                (__bridge void *)w.contentView, [gWindows containsObject:w]);
        return;
    }

    UIView *chrome = w.chromeView;
    CGFloat safeTop = (gHostFullscreen && !w.sheetParent) ? parent.safeAreaInsets.top : 0;
    CGFloat titleBarH = 34.0;
    CGRect chromeFrame = hostBounds;
    UIView *titleBar = w.titleLabel.superview;
    if (w.sheetParent) {
        // A Mac sheet has no title bar: it drops from the top of its parent's content, centered on the parent.
        titleBarH = 0;
        UIView *backdrop = [w shimSheetBackdrop];
        backdrop.frame = hostBounds;
        if (backdrop.superview != parent) [parent addSubview:backdrop];
        CGRect anchor = hostBounds;
        UIView *parentContent = w.sheetParent.contentView.hostView;
        if (parentContent.superview) anchor = [parentContent convertRect:parentContent.bounds toView:parent];
        parent = backdrop;
        CGSize design = w.shimDesignSize;
        CGFloat width = MIN(hostBounds.size.width, MAX(1.0, design.width));
        CGFloat height = MIN(hostBounds.size.height, MAX(1.0, design.height));
        CGFloat x = MAX(0, MIN(hostBounds.size.width - width, CGRectGetMidX(anchor) - width * 0.5));
        CGFloat y = MAX(0, MIN(hostBounds.size.height - height, CGRectGetMinY(anchor)));
        chromeFrame = CGRectMake(x, y, width, height);
    }
    BOOL fixedDialog = NO;
    if (!w.sheetParent && gHostFullscreen && !(w.styleMask & (1 << 3))) {
        // A fixed-size window (a dialog) can't fill the screen: show it as a window of its own size, centered,
        // with its title bar, the way the Mac shows it. Resizable windows stay full screen.
        CGSize design = w.shimDesignSize;
        CGFloat height = design.height + 34.0;
        if (design.width > 1.0 && design.height > 1.0 && design.width < hostBounds.size.width - 1.0 &&
            height < hostBounds.size.height - 1.0) {
            fixedDialog = YES;
            safeTop = 0;
            chromeFrame = CGRectMake(floor((hostBounds.size.width - design.width) * 0.5),
                                     floor((hostBounds.size.height - height) * 0.5), design.width, height);
        }
    }
    chrome.frame = chromeFrame;
    chrome.layer.cornerRadius = (fixedDialog || w.sheetParent || !gHostFullscreen) ? 10.0 : 0.0;
    chrome.layer.borderWidth = (fixedDialog || w.sheetParent || !gHostFullscreen) ? 1.0 : 0.0;
    chrome.clipsToBounds = YES;
    if (chrome.superview != parent) [parent addSubview:chrome];

    // The window chrome belongs to the Mac app. Keep its title below the device cutout.
    titleBar.hidden = w.sheetParent != nil;
    if (!w.sheetParent) {
        titleBar.frame = CGRectMake(0, safeTop, chromeFrame.size.width, 34.0);
        titleBarH = CGRectGetMaxY(titleBar.frame);
    }
    CGRect contentFrame = CGRectMake(0, titleBarH, chromeFrame.size.width, MAX(1.0, chromeFrame.size.height - titleBarH));
    UIView *cvHost = w.contentView.hostView;
    CGSize origSize = w.sheetParent ? w.shimDesignSize : w.contentView.frame.size;
    if (origSize.width < 1.0 || origSize.height < 1.0) {
        origSize = w.shimDesignSize;
    }
    for (NSView *sub in w.contentView.shimSubviews) {
        CGRect sf = sub.frame;
        if (CGRectGetMaxX(sf) > origSize.width) origSize.width = CGRectGetMaxX(sf) + 16.0;
        if (CGRectGetMaxY(sf) > origSize.height) origSize.height = CGRectGetMaxY(sf) + 16.0;
    }
    fprintf(stderr, "NSWindow ShimAttachWindow '%s' origSize=%.0fx%.0f design=%.0fx%.0f host=%.0fx%.0f\n",
            w.title ? w.title.UTF8String : "",
            origSize.width, origSize.height,
            w.shimDesignSize.width, w.shimDesignSize.height,
            contentFrame.size.width, contentFrame.size.height);
    fflush(stderr);
    const NSUInteger resizableStyle = 1 << 3; // NSWindowStyleMaskResizable
    BOOL canResize = gHostFullscreen && !w.sheetParent && (w.styleMask & resizableStyle);
    if (canResize) {
        // A resizable window whose SwiftUI content can't get as narrow as the screen (CrossOver's main window
        // on an iPhone) is shown whole, scaled down, like a Mac desktop seen from further away.
        CGSize min = ShimHostedMinimumSize(cvHost, contentFrame.size);
        if (min.width > contentFrame.size.width + 1.0) {
            CGFloat s = contentFrame.size.width / min.width;
            origSize = CGSizeMake(min.width, MAX(min.height, contentFrame.size.height / s));
            canResize = NO;
        }
    }
    BOOL needsScale = origSize.width > contentFrame.size.width + 1.0 ||
        ((gHostFullscreen || w.sheetParent) && origSize.height > contentFrame.size.height + 1.0);
    if (!canResize && needsScale && origSize.height > 1.0 && origSize.width > 1.0) {
        CGFloat scale = MIN(contentFrame.size.width / origSize.width,
                            contentFrame.size.height / origSize.height);
        cvHost.autoresizingMask = UIViewAutoresizingNone;
        cvHost.transform = CGAffineTransformIdentity;
        cvHost.bounds = CGRectMake(0, 0, origSize.width, origSize.height);
        cvHost.transform = CGAffineTransformMakeScale(scale, scale);
        cvHost.center = CGPointMake(contentFrame.origin.x + contentFrame.size.width * 0.5,
                                    contentFrame.origin.y + (origSize.height * scale) * 0.5);
        if (cvHost.superview != chrome) {
            [chrome addSubview:cvHost];
        }
        w.frame = chromeFrame;
        [chrome layoutIfNeeded];
        [w.contentView shimUpdateFromHostLayout];
        for (NSView *sub in w.contentView.shimSubviews) [sub shimUpdateFromHostLayout];
    } else if (!canResize && !w.sheetParent && gHostFullscreen && origSize.width > 1.0 && origSize.height > 1.0 &&
               (origSize.width < contentFrame.size.width - 1.0 || origSize.height < contentFrame.size.height - 1.0)) {
        // A fixed-size window (a dialog) keeps its own size, centered on the full-screen backdrop, as on a Mac.
        cvHost.transform = CGAffineTransformIdentity;
        cvHost.frame = CGRectMake(contentFrame.origin.x + floor((contentFrame.size.width - origSize.width) * 0.5),
                                  contentFrame.origin.y + floor((contentFrame.size.height - origSize.height) * 0.5),
                                  origSize.width, origSize.height);
        cvHost.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        if (cvHost.superview != chrome) [chrome addSubview:cvHost];
        w.frame = chromeFrame;
        [chrome layoutIfNeeded];
        [w.contentView shimUpdateFromHostLayout];
        for (NSView *sub in w.contentView.shimSubviews) [sub shimUpdateFromHostLayout];
    } else {
        cvHost.transform = CGAffineTransformIdentity;
        cvHost.frame = contentFrame;
        cvHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (cvHost.superview != chrome) {
            [chrome addSubview:cvHost];
        }
        w.frame = chromeFrame;

        [chrome layoutIfNeeded];
        [w.contentView shimUpdateFromHostLayout];
        for (NSView *sub in w.contentView.shimSubviews) {
            [sub shimUpdateFromHostLayout];
        }
    }
    ShimNotifyWindow(w, @"DidResize");
    if (activate) {
        ShimNotifyWindow(w, @"DidBecomeMain");
        ShimNotifyWindow(w, @"DidBecomeKey");
    }
}

static void ShimAttachWindow(NSWindow *w) {
    ShimLayoutWindow(w, YES);
}

@implementation NSWindow {
    NSMutableArray<ShimSheetSession *> *_sheetSessions;
    UIView *_sheetBackdrop;
}
@synthesize frame = _frame;
SHIM_RESOLVE

- (void)shimSetupChrome {
    _chromeView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 600)];
    _chromeView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _chromeView.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.15 alpha:1.0];
    _chromeView.layer.cornerRadius = gHostFullscreen ? 0 : 12.0;
    _chromeView.layer.borderWidth = gHostFullscreen ? 0 : 1.0;
    _chromeView.accessibilityIdentifier = @"mac-app-window";
    _chromeView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    _chromeView.clipsToBounds = YES;
    _chromeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 34.0)];
    titleBar.backgroundColor = [UIColor colorWithRed:0.14 green:0.16 blue:0.22 alpha:1.0];
    titleBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_chromeView addSubview:titleBar];

    // Classic macOS traffic light indicators.
    NSArray<UIColor *> *dots = @[
        [UIColor colorWithRed:1.00 green:0.37 blue:0.34 alpha:1.0],
        [UIColor colorWithRed:0.99 green:0.74 blue:0.18 alpha:1.0],
        [UIColor colorWithRed:0.16 green:0.79 blue:0.26 alpha:1.0],
    ];
    for (NSUInteger i = 0; i < dots.count; i++) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(12.0 + i * 18.0, 11.0, 12.0, 12.0)];
        dot.backgroundColor = dots[i];
        dot.layer.cornerRadius = 6.0;
        [titleBar addSubview:dot];
    }

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(72.0, 0, 216.0, 34.0)];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1.0];
    _titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _titleLabel.accessibilityIdentifier = @"NSWindowTitle";
    [titleBar addSubview:_titleLabel];
}

- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer {
    (void)backing;
    (void)defer;
    if ((self = [super init])) {
        _frame = rect;
        _shimDesignSize = rect.size;
        _styleMask = style;
        [self shimSetupChrome];
        self.contentView = [[NSView alloc] initWithFrame:CGRectMake(0, 0, rect.size.width, rect.size.height)];
    }
    return self;
}

- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer screen:(id)screen {
    (void)screen;
    return [self initWithContentRect:rect styleMask:style backing:backing defer:defer];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy] ?: @"";
    _titleLabel.text = _title;
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    _backgroundColor = backgroundColor;
    if (backgroundColor) {
        _chromeView.backgroundColor = backgroundColor.uiColor;
        _contentView.hostView.backgroundColor = backgroundColor.uiColor;
    }
}

- (void)setContentView:(NSView *)v {
    if (_contentView.hostView.superview == _chromeView) {
        [_contentView.hostView removeFromSuperview];
    }
    _contentView = v;
    v.window = self;
    if (_backgroundColor) {
        v.hostView.backgroundColor = _backgroundColor.uiColor;
    }
    if (self.visible) ShimAttachWindow(self);
}

- (void)setContentViewController:(NSViewController *)vc {
    _contentViewController = vc;
    self.contentView = vc.view;
}

- (CGRect)frame {
    if (gHostFullscreen && [gWindows containsObject:self]) return ShimActiveHostView().bounds;
    return _frame;
}

- (CGRect)contentLayoutRect { return _contentView.bounds; }
- (CGRect)contentRectForFrameRect:(CGRect)r { return r; }
- (CGRect)frameRectForContentRect:(CGRect)r { return r; }
- (NSScreen *)screen { return [NSScreen mainScreen]; }
- (CGFloat)backingScaleFactor { return [NSScreen mainScreen].backingScaleFactor; }
- (BOOL)isKeyWindow { return gWindows.lastObject == self; }
- (BOOL)isVisible { return [gWindows containsObject:self]; }
- (BOOL)makeFirstResponder:(id)r { _shimFirstResponder = r; return YES; }
- (id)firstResponder { return _shimFirstResponder ?: _contentView; }

- (void)makeKeyAndOrderFront:(id)sender {
    (void)sender;
    if (_sheetParent && _sheetParent.attachedSheet != self) return;
    if (!gWindows) gWindows = [NSMutableArray new];
    [gWindows removeObject:self];
    [gWindows addObject:self];
    ShimAttachWindow(self);
    UIView *surface = _sheetBackdrop ?: _chromeView;
    [surface.superview bringSubviewToFront:surface];
    [self shimPresentAttachedSheet];
}
- (void)orderFront:(id)sender { [self makeKeyAndOrderFront:sender]; }
- (void)makeKeyWindow { [self makeKeyAndOrderFront:nil]; }
- (void)makeMainWindow { [self makeKeyAndOrderFront:nil]; }
- (void)center {}
- (void)close { [self orderOut:nil]; }
- (void)orderOut:(id)sender {
    (void)sender;
    if (_sheetParent) {
        [_sheetParent endSheet:self returnCode:0];
        return;
    }
    [_chromeView removeFromSuperview];
    [_sheetBackdrop removeFromSuperview];
    [gWindows removeObject:self];
    [_chromeView endEditing:YES];
    for (ShimSheetSession *session in [_sheetSessions copy]) {
        [self endSheet:session.window returnCode:0];
    }
}

- (UIView *)shimSheetBackdrop {
    if (!_sheetBackdrop) {
        _sheetBackdrop = [UIView new];
        _sheetBackdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
        _sheetBackdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _sheetBackdrop.accessibilityViewIsModal = YES;
    }
    return _sheetBackdrop;
}

- (NSWindow *)attachedSheet { return _sheetSessions.firstObject.window; }
- (NSArray<NSWindow *> *)sheets { return [_sheetSessions valueForKey:@"window"] ?: @[]; }

- (void)shimPresentAttachedSheet {
    NSWindow *sheet = self.attachedSheet;
    if (!sheet || !self.visible) return;
    [_chromeView endEditing:YES];
    _chromeView.accessibilityElementsHidden = YES;
    [sheet makeKeyAndOrderFront:nil];
}

- (void)beginSheet:(NSWindow *)sheet completionHandler:(void (^)(NSInteger))handler {
    if (!sheet || sheet == self || sheet.sheetParent) return;
    for (NSWindow *ancestor = _sheetParent; ancestor; ancestor = ancestor.sheetParent) {
        if (ancestor == sheet) return;
    }
    ShimSheetSession *session = [ShimSheetSession new];
    session.window = sheet;
    session.completion = handler;
    sheet->_sheetParent = self;
    sheet->_isSheet = YES;
    if (!_sheetSessions) _sheetSessions = [NSMutableArray new];
    [_sheetSessions addObject:session];
    if (_sheetSessions.count == 1) [self shimPresentAttachedSheet];
}

- (void)endSheet:(NSWindow *)sheet { [self endSheet:sheet returnCode:0]; }

- (void)endSheet:(NSWindow *)sheet returnCode:(NSInteger)code {
    if (sheet.sheetParent != self) return;
    BOOL wasAttached = sheet == self.attachedSheet;
    ShimSheetSession *ending;
    for (ShimSheetSession *session in _sheetSessions) {
        if (session.window == sheet) {
            ending = session;
            break;
        }
    }
    if (!ending) return;
    [_sheetSessions removeObjectIdenticalTo:ending];
    sheet->_sheetParent = nil;
    if (wasAttached) {
        [sheet orderOut:nil];
        _chromeView.accessibilityElementsHidden = NO;
        [self shimPresentAttachedSheet];
    }
    if (ending.completion) ending.completion(code);
}

- (void)sendEvent:(NSEvent *)e {
    id target = (e.type == NSEventTypeKeyDown || e.type == NSEventTypeKeyUp || e.type == NSEventTypeFlagsChanged)
        ? [self firstResponder]
        : ([_contentView hitTest:e.locationInWindow] ?: _contentView);
    SEL sel = NULL;
    switch (e.type) {
        case NSEventTypeLeftMouseDown: sel = @selector(mouseDown:); break;
        case NSEventTypeLeftMouseUp: sel = @selector(mouseUp:); break;
        case NSEventTypeLeftMouseDragged: sel = @selector(mouseDragged:); break;
        case NSEventTypeMouseMoved: sel = @selector(mouseMoved:); break;
        case NSEventTypeScrollWheel: sel = @selector(scrollWheel:); break;
        case NSEventTypeKeyDown: sel = @selector(keyDown:); break;
        case NSEventTypeKeyUp: sel = @selector(keyUp:); break;
        case NSEventTypeFlagsChanged: sel = @selector(flagsChanged:); break;
    }
    if (sel && [target respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, sel, e);
    }
}

@end

// MARK: NSApplication & Hosted Lifecycle

__attribute__((visibility("default")))
@interface NSApplication : NSResponder
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) id mainMenu;
- (void)sendEvent:(NSEvent *)e;
@end

static BOOL gAppRunning = NO;

static void ShimPostAppLifecycle(NSString *name, SEL delegateSel) {
    NSApplication *app = NSApp;
    NSNotification *n = [NSNotification notificationWithName:name object:app];
    BOOL responds = [app.delegate respondsToSelector:delegateSel];
    fprintf(stderr, "NSApplication lifecycle -> %s (delegate=%s responds=%d)\n",
            sel_getName(delegateSel),
            app.delegate ? class_getName([app.delegate class]) : "nil",
            responds);
    fflush(stderr);
    if (responds) {
        ((void (*)(id, SEL, id))objc_msgSend)(app.delegate, delegateSel, n);
    }
    [NSNotificationCenter.defaultCenter postNotification:n];
    fprintf(stderr, "NSApplication lifecycle <- %s\n", sel_getName(delegateSel));
    fflush(stderr);
}

static void ShimDeliverLaunchNotifications(void) {
    ShimPostAppLifecycle(NSApplicationWillFinishLaunchingNotification, @selector(applicationWillFinishLaunching:));
    ShimPostAppLifecycle(NSApplicationDidFinishLaunchingNotification, @selector(applicationDidFinishLaunching:));
    ShimPostAppLifecycle(NSApplicationWillBecomeActiveNotification, @selector(applicationWillBecomeActive:));
    ShimPostAppLifecycle(NSApplicationDidBecomeActiveNotification, @selector(applicationDidBecomeActive:));
    for (NSWindow *w in [gWindows copy]) {
        ShimAttachWindow(w);
    }
}

static void ShimDispatchEvent(NSEvent *e) {
    if (!e.window) e.window = gWindows.lastObject;
    for (NSArray *m in [gMonitors copy]) {
        if (!([m[0] unsignedLongLongValue] & (1ULL << e.type))) continue;
        e = ((NSEvent *(^)(NSEvent *))m[1])(e);
        if (!e) return;
    }
    [(NSApplication *)NSApp sendEvent:e];
}

@interface ShimStandaloneAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ShimStandaloneAppDelegate
@end

@interface ShimStandaloneSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ShimStandaloneSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session;
    (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    gHostWindow = self.window;
    gRootVC = [UIViewController new];
    gRootVC.view.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = gRootVC;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        ShimDeliverLaunchNotifications();
    });
}
@end

@implementation NSApplication
SHIM_RESOLVE

+ (instancetype)sharedApplication {
    if (!NSApp) {
        // The guest's NSPrincipalClass (CrossOver: CXApplication, which owns bindings like daysLeft) must be the one
        // instance, even when a framework or a nib's "Application" placeholder asks NSApplication first.
        Class cls = self;
        Class principal = NSClassFromString(NSBundle.mainBundle.infoDictionary[@"NSPrincipalClass"]);
        if (principal && principal != cls && [principal isSubclassOfClass:cls]) cls = principal;
        NSApp = [cls new];
        gWindows = [NSMutableArray new];
    }
    return NSApp;
}

- (BOOL)setActivationPolicy:(NSInteger)policy { (void)policy; return YES; }
- (void)activateIgnoringOtherApps:(BOOL)flag { (void)flag; }
- (void)finishLaunching {}
- (NSArray *)windows { return gWindows ?: @[]; }
- (NSWindow *)keyWindow { return gWindows.lastObject; }
- (NSWindow *)mainWindow { return gWindows.lastObject; }
- (void)sendEvent:(NSEvent *)e { [e.window sendEvent:e]; }
- (void)endSheet:(NSWindow *)sheet { [self endSheet:sheet returnCode:0]; }
- (void)endSheet:(NSWindow *)sheet returnCode:(NSInteger)code {
    [sheet.sheetParent endSheet:sheet returnCode:code];
}
- (BOOL)isRunning { return gAppRunning; }
- (BOOL)isActive { return YES; }
- (void)stop:(id)sender { (void)sender; CFRunLoopStop(CFRunLoopGetMain()); }
- (void)updateWindows {}

- (void)terminate:(id)sender {
    (void)sender;
    fprintf(stderr, "NSApplication terminate: called from %s\n", sender ? class_getName([sender class]) : "nil");
    fflush(stderr);
    if (gHostedMode) {
        CFRunLoopStop(CFRunLoopGetMain());
    } else {
        exit(0);
    }
}
// As in AppKit: the window is shown and the run loop runs (touches, timers, the guest's own sources) until
// stopModal / stopModalWithCode: / abortModal ends the innermost modal loop, whose code is returned.
static NSMutableArray<NSNumber *> *gModalCodes; // one entry per nested modal loop; NSNull-like sentinel = running
static const NSInteger kShimModalRunning = NSIntegerMin;
- (NSInteger)runModalForWindow:(NSWindow *)win {
    fprintf(stderr, "NSApplication runModalForWindow: %s (title=%s)\n",
            win ? class_getName([win class]) : "(null)",
            win.title.UTF8String ?: "");
    fflush(stderr);
    if (!gModalCodes) gModalCodes = [NSMutableArray new];
    [gModalCodes addObject:@(kShimModalRunning)];
    NSUInteger depth = gModalCodes.count;
    [win makeKeyAndOrderFront:nil];
    NSUInteger userActionDepth = gUserActionDepth;
    gUserActionDepth = 0;
    @try {
        while (gModalCodes.count >= depth && gModalCodes[depth - 1].integerValue == kShimModalRunning) {
            @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true); }
        }
    } @finally {
        gUserActionDepth = userActionDepth;
    }
    NSInteger code = gModalCodes.count >= depth ? gModalCodes[depth - 1].integerValue : -1001;
    while (gModalCodes.count >= depth) [gModalCodes removeLastObject];
    fprintf(stderr, "NSApplication runModalForWindow: '%s' ended with %ld\n", win.title.UTF8String ?: "", (long)code);
    return code;
}
static void ShimEndModal(NSInteger code) {
    if (gModalCodes.count && gModalCodes.lastObject.integerValue == kShimModalRunning)
        gModalCodes[gModalCodes.count - 1] = @(code);
}
- (void)stopModal { ShimEndModal(-1000); }            // NSModalResponseStop
- (void)stopModalWithCode:(NSInteger)returnCode { ShimEndModal(returnCode); }
- (void)abortModal { ShimEndModal(-1001); }           // NSModalResponseAbort
- (NSWindow *)modalWindow { return nil; }

- (void)run {
    gAppRunning = YES;
    if (gHostedMode) {
        // UIKit is already running in MacAppHost; deliver AppKit launch callbacks immediately
        // and pump the main run loop so stack-allocated delegates in guest main() stay alive.
        ShimDeliverLaunchNotifications();
        CFRunLoopRun();
        gAppRunning = NO;
        return;
    }
    UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), @"UIApplication", @"ShimStandaloneAppDelegate");
}

@end

__attribute__((visibility("default")))
NSInteger NSConvertGlyphsToPackedGlyphs(void *glBuf, NSInteger count, NSUInteger packing, char *packedGlyphs) {
    (void)glBuf; (void)count; (void)packing; (void)packedGlyphs;
    return 0;
}

__attribute__((visibility("default")))
int NSApplicationMain(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    Class principal = NSClassFromString(info[@"NSPrincipalClass"]) ?: [NSApplication class];
    NSApplication *app = [principal sharedApplication];
    NSString *mainNib = info[@"NSMainNibFile"];
    static NSArray *sTopObjects;
    if (mainNib.length) {
        NSArray *tops = nil;
        [NSBundle.mainBundle loadNibNamed:mainNib owner:app topLevelObjects:&tops];
        sTopObjects = tops;
    }
    NSString *delegateName = info[@"SHIMAppDelegate"];
    static id sDelegate;
    if (delegateName && !app.delegate) {
        sDelegate = [NSClassFromString(delegateName) new];
        app.delegate = sDelegate;
    }
    [app run];
    return 0;
}

// MARK: Extended AppKit Classes (Fonts, Images, Controls, Menus, Panels, Workspace)

__attribute__((visibility("default")))
@interface NSFont : NSObject
@property (nonatomic, strong, readonly) UIFont *uiFont;
@end

@implementation NSFont
SHIM_RESOLVE
- (instancetype)initWithCoder:(NSCoder *)coder {
    // Nib fonts: NSName + NSSize. ".AppleSystemUIFont*" is the system font (weight from the name).
    NSString *name = [coder decodeObjectForKey:@"NSName"];
    CGFloat size = [coder containsValueForKey:@"NSSize"] ? [coder decodeDoubleForKey:@"NSSize"] : 13.0;
    if (size <= 0) size = 13.0;
    UIFont *f = nil;
    if (![name isKindOfClass:NSString.class] || [name hasPrefix:@".AppleSystemUIFont"] || [name hasPrefix:@".SF"]) {
        UIFontWeight weight = UIFontWeightRegular;
        if ([name containsString:@"Bold"] || [name containsString:@"Emphasized"]) weight = UIFontWeightBold;
        else if ([name containsString:@"Semibold"]) weight = UIFontWeightSemibold;
        else if ([name containsString:@"Medium"]) weight = UIFontWeightMedium;
        f = [UIFont systemFontOfSize:size weight:weight];
    } else {
        f = [UIFont fontWithName:name size:size] ?: [UIFont systemFontOfSize:size];
    }
    return [self initWithUIFont:f];
}
- (instancetype)initWithUIFont:(UIFont *)f {
    if ((self = [super init])) _uiFont = f ?: [UIFont systemFontOfSize:13.0];
    return self;
}
+ (CGFloat)systemFontSize { return 13.0; }
+ (CGFloat)smallSystemFontSize { return 11.0; }
+ (CGFloat)labelFontSize { return 10.0; }
+ (NSFont *)systemFontOfSize:(CGFloat)size {
    return [[self alloc] initWithUIFont:[UIFont systemFontOfSize:size > 0 ? size : 13.0]];
}
+ (NSFont *)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    return [[self alloc] initWithUIFont:[UIFont systemFontOfSize:size > 0 ? size : 13.0 weight:weight]];
}
+ (NSFont *)boldSystemFontOfSize:(CGFloat)size {
    return [[self alloc] initWithUIFont:[UIFont boldSystemFontOfSize:size > 0 ? size : 13.0]];
}
+ (NSFont *)monospacedSystemFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    return [[self alloc] initWithUIFont:[UIFont monospacedSystemFontOfSize:size > 0 ? size : 13.0 weight:weight]];
}
+ (NSFont *)userFixedPitchFontOfSize:(CGFloat)size {
    return [[self alloc] initWithUIFont:[UIFont monospacedSystemFontOfSize:size > 0 ? size : 12.0 weight:UIFontWeightRegular]];
}
+ (NSFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    UIFont *f = name ? [UIFont fontWithName:name size:size > 0 ? size : 13.0] : nil;
    return [[self alloc] initWithUIFont:f ?: [UIFont systemFontOfSize:size > 0 ? size : 13.0]];
}
- (NSString *)fontName { return _uiFont.fontName; }
- (CGFloat)pointSize { return _uiFont.pointSize; }
@end

__attribute__((visibility("default")))
@interface NSImageSymbolConfiguration : NSObject
@property (nonatomic, strong, readonly) UIImageSymbolConfiguration *uiConfig;
@end

@implementation NSImageSymbolConfiguration
SHIM_RESOLVE
- (instancetype)initWithUIConfig:(UIImageSymbolConfiguration *)cfg {
    if ((self = [super init])) _uiConfig = cfg;
    return self;
}
+ (instancetype)configurationWithPointSize:(CGFloat)pointSize weight:(CGFloat)weight {
    (void)weight;
    return [[self alloc] initWithUIConfig:[UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightRegular]];
}
+ (instancetype)configurationWithScale:(NSInteger)scale {
    (void)scale;
    return [[self alloc] initWithUIConfig:[UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleMedium]];
}
@end

__attribute__((visibility("default")))
@interface NSImage : NSObject
@property (nonatomic, strong, readonly) UIImage *uiImage;
@property (nonatomic) CGSize size;
@property (nonatomic, getter=isTemplate) BOOL template;
@end

@implementation NSImage
SHIM_RESOLVE
- (instancetype)initWithUIImage:(UIImage *)img {
    if ((self = [super init])) {
        _uiImage = img;
        _size = img ? img.size : CGSizeMake(16, 16);
    }
    return self;
}
- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super init])) _size = size;
    return self;
}
- (instancetype)initWithData:(NSData *)data {
    return [self initWithUIImage:data ? [UIImage imageWithData:data] : nil];
}
- (instancetype)initWithContentsOfFile:(NSString *)path {
    return [self initWithUIImage:path ? [UIImage imageWithContentsOfFile:path] : nil];
}
- (instancetype)initWithContentsOfURL:(NSURL *)url {
    return [self initWithContentsOfFile:url.path];
}
+ (NSImage *)imageNamed:(NSString *)name {
    UIImage *img = name ? ([UIImage imageNamed:name] ?: [UIImage systemImageNamed:name]) : nil;
    if (!img && name && gMacBundleRoot) {
        NSString *resDir = [gMacBundleRoot stringByAppendingPathComponent:@"Contents/Resources"];
        NSString *p = [resDir stringByAppendingPathComponent:name];
        img = [UIImage imageWithContentsOfFile:p];
        if (!img && !name.pathExtension.length) {
            img = [UIImage imageWithContentsOfFile:[p stringByAppendingPathExtension:@"png"]];
        }
    }
    return img ? [[self alloc] initWithUIImage:img] : [[self alloc] initWithSize:CGSizeMake(16, 16)];
}
+ (NSImage *)imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc {
    (void)desc;
    UIImage *img = name ? [UIImage systemImageNamed:name] : nil;
    return [[self alloc] initWithUIImage:img];
}
- (NSImage *)imageWithSymbolConfiguration:(NSImageSymbolConfiguration *)cfg {
    UIImage *img = cfg.uiConfig ? [_uiImage imageByApplyingSymbolConfiguration:cfg.uiConfig] : _uiImage;
    return [[NSImage alloc] initWithUIImage:img ?: _uiImage];
}
- (void)lockFocus {}
- (void)unlockFocus {}
@end

__attribute__((visibility("default")))
@interface NSImageView : NSControl
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, strong, readonly) UIImageView *uiImageView;
@end

@implementation NSImageView
SHIM_RESOLVE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _uiImageView = [[UIImageView alloc] initWithFrame:self.hostView.bounds];
        _uiImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _uiImageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.hostView addSubview:_uiImageView];
    }
    return self;
}
+ (instancetype)imageViewWithImage:(NSImage *)image {
    NSImageView *iv = [[self alloc] initWithFrame:CGRectMake(0, 0, image ? image.size.width : 32, image ? image.size.height : 32)];
    iv.image = image;
    return iv;
}
- (void)setImage:(NSImage *)image {
    _image = image;
    _uiImageView.image = image.uiImage;
}
@end

__attribute__((visibility("default")))
@interface NSBezierPath : NSObject
@property (nonatomic, strong, readonly) UIBezierPath *uiPath;
@end

@implementation NSBezierPath
SHIM_RESOLVE
- (instancetype)initWithUIPath:(UIBezierPath *)p {
    if ((self = [super init])) _uiPath = p ?: [UIBezierPath bezierPath];
    return self;
}
- (instancetype)init { return [self initWithUIPath:[UIBezierPath bezierPath]]; }
+ (instancetype)bezierPath { return [self new]; }
+ (instancetype)bezierPathWithRect:(CGRect)rect { return [[self alloc] initWithUIPath:[UIBezierPath bezierPathWithRect:rect]]; }
+ (instancetype)bezierPathWithOvalInRect:(CGRect)rect { return [[self alloc] initWithUIPath:[UIBezierPath bezierPathWithOvalInRect:rect]]; }
+ (instancetype)bezierPathWithRoundedRect:(CGRect)rect xRadius:(CGFloat)x yRadius:(CGFloat)y {
    (void)y;
    return [[self alloc] initWithUIPath:[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:x]];
}
+ (void)fillRect:(CGRect)rect { UIRectFill(rect); }
+ (void)strokeRect:(CGRect)rect { UIRectFrame(rect); }
- (void)fill { [_uiPath fill]; }
- (void)stroke { [_uiPath stroke]; }
- (void)addClip { [_uiPath addClip]; }
- (void)moveToPoint:(CGPoint)p { [_uiPath moveToPoint:p]; }
- (void)lineToPoint:(CGPoint)p { [_uiPath addLineToPoint:p]; }
- (void)closePath { [_uiPath closePath]; }
@end

__attribute__((visibility("default")))
@interface NSBitmapImageRep : NSObject
@end
@implementation NSBitmapImageRep
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSGraphicsContext : NSObject
+ (instancetype)currentContext;
- (CGContextRef)CGContext;
@end
@implementation NSGraphicsContext
SHIM_RESOLVE
+ (instancetype)currentContext { return [self new]; }
- (CGContextRef)CGContext { return UIGraphicsGetCurrentContext(); }
+ (void)saveGraphicsState {}
+ (void)restoreGraphicsState {}
@end

__attribute__((visibility("default")))
@interface NSAnimationContext : NSObject
@property (nonatomic) NSTimeInterval duration;
@end
@implementation NSAnimationContext
SHIM_RESOLVE
+ (instancetype)currentContext {
    static NSAnimationContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [self new]; });
    return ctx;
}
+ (void)runAnimationGroup:(void (^)(NSAnimationContext *))changes completionHandler:(void (^)(void))completion {
    if (changes) changes([self currentContext]);
    if (completion) completion();
}
@end

__attribute__((visibility("default")))
@interface NSAlert : NSObject
@property (nonatomic, copy) NSString *messageText;
@property (nonatomic, copy) NSString *informativeText;
@property (nonatomic) NSUInteger alertStyle;
@property (nonatomic) BOOL showsSuppressionButton;
@property (nonatomic, strong) NSButton *suppressionButton;
@property (nonatomic, strong, readonly) NSMutableArray<NSString *> *shimButtons;
@end
@implementation NSAlert
SHIM_RESOLVE
- (instancetype)init {
    if ((self = [super init])) {
        _shimButtons = [NSMutableArray new];
        _suppressionButton = [NSButton buttonWithTitle:@"Don't ask again" target:nil action:NULL];
    }
    return self;
}
- (id)addButtonWithTitle:(NSString *)title {
    if (title) [_shimButtons addObject:title];
    return [NSButton buttonWithTitle:title ?: @"" target:nil action:NULL];
}
- (NSInteger)runModal {
    fprintf(stderr, "NSAlert runModal: %s | %s (buttons=%s)\n",
            _messageText ? _messageText.UTF8String : "",
            _informativeText ? _informativeText.UTF8String : "",
            [_shimButtons componentsJoinedByString:@", "].UTF8String ?: "");
    fflush(stderr);
    if (_shimButtons.count >= 2 && _messageText &&
        ([_messageText containsString:@"Applications folder"] || [_messageText containsString:@"Move"])) {
        return 1001; // NSAlertSecondButtonReturn ("Do Not Move")
    }
    return 1000; // NSAlertFirstButtonReturn
}
- (void)beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSInteger))handler {
    (void)sheetWindow;
    if (handler) handler([self runModal]);
}
@end

__attribute__((visibility("default")))
@interface NSBox : NSView
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, copy) NSString *title;
@end
@implementation NSBox
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSClipView : NSView
@property (nonatomic, strong) NSView *documentView;
@end
@implementation NSClipView
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSScrollView : NSView
@property (nonatomic, strong) NSView *documentView;
@property (nonatomic, strong) NSClipView *contentView;
@property (nonatomic, strong, readonly) UIScrollView *uiScrollView;
@end
@implementation NSScrollView
SHIM_RESOLVE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _uiScrollView = [[UIScrollView alloc] initWithFrame:self.hostView.bounds];
        _uiScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.hostView addSubview:_uiScrollView];
        _contentView = [[NSClipView alloc] initWithFrame:self.bounds];
    }
    return self;
}
- (void)setDocumentView:(NSView *)documentView {
    [_documentView removeFromSuperview];
    _documentView = documentView;
    if (documentView) {
        [_uiScrollView addSubview:documentView.hostView];
        _uiScrollView.contentSize = documentView.frame.size;
    }
}
@end

__attribute__((visibility("default")))
@interface NSCollectionView : NSView
@end
@implementation NSCollectionView
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSCollectionViewItem : NSViewController
@end
@implementation NSCollectionViewItem
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSOutlineView : NSView
@end
@implementation NSOutlineView
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSTableRowView : NSView
@end
@implementation NSTableRowView
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSTextField : NSControl <UITextFieldDelegate>
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, copy) NSString *placeholderString;
@property (nonatomic, strong) NSColor *textColor;
@property (nonatomic, weak) id delegate;
@property (nonatomic, getter=isEditable) BOOL editable;
@property (nonatomic, getter=isSelectable) BOOL selectable;
@property (nonatomic, getter=isBordered) BOOL bordered;
@property (nonatomic) BOOL drawsBackground;
@property (nonatomic) BOOL allowsEditingTextAttributes;
@property (nonatomic) NSTextAlignment alignment;
@property (nonatomic, strong, readonly) UILabel *uiLabel;
- (BOOL)shimUsesSecureTextEntry;
@end
@implementation NSTextField {
    UITextField *_editor;
}
SHIM_RESOLVE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _uiLabel = [[UILabel alloc] initWithFrame:self.hostView.bounds];
        _uiLabel.font = [UIFont systemFontOfSize:13.0]; // AppKit's default control font
        _uiLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _uiLabel.textColor = UIColor.labelColor;
        _uiLabel.numberOfLines = 0;
        [self.hostView addSubview:_uiLabel];
        _stringValue = @"";
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        NSActionCell *cell = self.cell;
        if ([cell isKindOfClass:NSActionCell.class]) {
            if (cell.font) self.font = cell.font;
            self.stringValue = cell.stringValue;
            self.selectable = cell.selectable;
            self.bordered = cell.bordered || cell.bezeled;
            self.editable = cell.editable;
            if (cell.font) self.font = cell.font;
        }
    }
    return self;
}
+ (instancetype)labelWithString:(NSString *)stringValue {
    NSTextField *tf = [[self alloc] initWithFrame:CGRectMake(0, 0, 200, 22)];
    tf.stringValue = stringValue;
    return tf;
}
+ (instancetype)textFieldWithString:(NSString *)stringValue {
    NSTextField *field = [self labelWithString:stringValue];
    field.bordered = YES;
    field.editable = YES;
    return field;
}
- (BOOL)shimUsesSecureTextEntry { return NO; }
- (void)setEditable:(BOOL)editable {
    if (editable && !_editor) {
        _editor = [[UITextField alloc] initWithFrame:self.hostView.bounds];
        _editor.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _editor.secureTextEntry = [self shimUsesSecureTextEntry];
        _editor.autocorrectionType = UITextAutocorrectionTypeNo;
        _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [self shimStyleEditor];
        _editor.text = _stringValue;
        _editor.placeholder = _placeholderString;
        _editor.font = _uiLabel.font;
        _editor.textColor = _uiLabel.textColor ?: UIColor.labelColor;
        _editor.tintColor = UIColor.systemBlueColor;
        _editor.textAlignment = _uiLabel.textAlignment;
        _editor.enabled = self.enabled;
        _editor.delegate = self;
        [_editor addTarget:self action:@selector(shimTextChanged:) forControlEvents:UIControlEventEditingChanged];
        [self.hostView addSubview:_editor];
    }
    if (!editable) [_editor resignFirstResponder];
    _editable = editable;
    _editor.hidden = !editable;
    _uiLabel.hidden = editable || [self shimUsesSecureTextEntry];
}
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    _editor.enabled = enabled;
}
- (void)setBordered:(BOOL)bordered {
    _bordered = bordered;
    [self shimStyleEditor];
}
// A Mac text field: light inset box in light mode, dark gray box with a hairline border in dark mode.
- (void)shimStyleEditor {
    if (!_editor) return;
    _editor.borderStyle = UITextBorderStyleNone;
    if (_bordered) {
        _editor.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0.17 alpha:1] : UIColor.whiteColor;
        }];
        _editor.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.45].CGColor;
        _editor.layer.borderWidth = 1.0;
        _editor.layer.cornerRadius = 5.0;
        UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 6, 1)];
        _editor.leftView = pad;
        _editor.leftViewMode = UITextFieldViewModeAlways;
    } else {
        _editor.backgroundColor = UIColor.clearColor;
        _editor.layer.borderWidth = 0;
        _editor.leftView = nil;
    }
}
- (void)setPlaceholderString:(NSString *)placeholderString {
    _placeholderString = [placeholderString copy];
    _editor.placeholder = _placeholderString;
}
- (void)setAlignment:(NSTextAlignment)alignment {
    _alignment = alignment;
    _uiLabel.textAlignment = alignment;
    _editor.textAlignment = alignment;
}
- (void)setStringValue:(NSString *)stringValue {
    _stringValue = [stringValue copy] ?: @"";
    if (![self shimUsesSecureTextEntry]) _uiLabel.text = _stringValue;
    _editor.text = _stringValue;
}
- (NSAttributedString *)attributedStringValue {
    return _uiLabel.attributedText ?: [[NSAttributedString alloc] initWithString:_stringValue ?: @""];
}
- (void)setAttributedStringValue:(NSAttributedString *)attr {
    if (!attr) {
        self.stringValue = @"";
        _uiLabel.attributedText = nil;
        return;
    }
    NSMutableAttributedString *m = [attr mutableCopy];
    [m enumerateAttributesInRange:NSMakeRange(0, m.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
        (void)stop;
        id fg = attrs[NSForegroundColorAttributeName];
        if ([fg isKindOfClass:NSColor.class]) {
            [m addAttribute:NSForegroundColorAttributeName value:((NSColor *)fg).uiColor range:range];
        }
        id bg = attrs[NSBackgroundColorAttributeName];
        if ([bg isKindOfClass:NSColor.class]) {
            [m addAttribute:NSBackgroundColorAttributeName value:((NSColor *)bg).uiColor range:range];
        }
        id font = attrs[NSFontAttributeName];
        if ([font isKindOfClass:NSFont.class]) {
            [m addAttribute:NSFontAttributeName value:((NSFont *)font).uiFont range:range];
        }
    }];
    // Runs without a font or colour take the field's own (AppKit does); UILabel would fall back to 17 pt.
    UIFont *base = _uiLabel.font ?: [UIFont systemFontOfSize:13.0];
    UIColor *fg = _uiLabel.textColor ?: UIColor.labelColor;
    [m enumerateAttributesInRange:NSMakeRange(0, m.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
        (void)stop;
        if (![attrs[NSFontAttributeName] isKindOfClass:UIFont.class]) [m addAttribute:NSFontAttributeName value:base range:range];
        if (![attrs[NSForegroundColorAttributeName] isKindOfClass:UIColor.class] && !attrs[NSLinkAttributeName])
            [m addAttribute:NSForegroundColorAttributeName value:fg range:range];
    }];
    _stringValue = [attr.string copy] ?: @"";
    if (![self shimUsesSecureTextEntry]) _uiLabel.attributedText = m;
    _editor.text = _stringValue;
}
- (void)setFont:(NSFont *)font {
    [super setFont:font];
    if (font.uiFont) {
        _uiLabel.font = font.uiFont;
        _editor.font = font.uiFont;
    }
}
- (void)setTextColor:(NSColor *)textColor {
    _textColor = textColor;
    if (textColor.uiColor) {
        _uiLabel.textColor = textColor.uiColor;
        _editor.textColor = textColor.uiColor;
    }
}
- (void)shimNotifyText:(NSString *)suffix {
    SEL selector = NSSelectorFromString([@"controlText" stringByAppendingFormat:@"%@:", suffix]);
    NSString *name = [@"NSControlText" stringByAppendingFormat:@"%@Notification", suffix];
    NSNotification *notification = [NSNotification notificationWithName:name object:self];
    id delegate = self.delegate;
    if ([delegate respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, selector, notification);
    }
    [NSNotificationCenter.defaultCenter postNotification:notification];
}
// UIKit asks these optional delegate questions. Without real answers SHIM_RESOLVE would add a stub that
// returns nil, which UIKit reads as NO: the field would refuse to start editing or to take any typed text.
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField { return self.editable && self.enabled; }
- (BOOL)textFieldShouldEndEditing:(UITextField *)textField { return YES; }
- (BOOL)textFieldShouldClear:(UITextField *)textField { return YES; }
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string { return YES; }
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRanges:(NSArray<NSValue *> *)ranges replacementString:(NSString *)string { return YES; }
- (void)textFieldDidChangeSelection:(UITextField *)textField {}
- (void)textFieldDidEndEditing:(UITextField *)textField reason:(UITextFieldDidEndEditingReason)reason { [self textFieldDidEndEditing:textField]; }
- (UIMenu *)textField:(UITextField *)textField editMenuForCharactersInRange:(NSRange)range suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions {
    return [UIMenu menuWithChildren:suggestedActions];
}
- (UIMenu *)textField:(UITextField *)textField editMenuForCharactersInRanges:(NSArray<NSValue *> *)ranges suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions {
    return [UIMenu menuWithChildren:suggestedActions];
}
- (BOOL)respondsToSelector:(SEL)sel {
    // Any other UITextFieldDelegate question gets UIKit's default, never a nil stub.
    // Walk the method lists directly: class_respondsToSelector would run SHIM_RESOLVE and add the nil stub.
    if (strncmp(sel_getName(sel), "textField", 9) == 0) {
        for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
            unsigned n = 0;
            Method *ms = class_copyMethodList(c, &n);
            BOOL real = NO, found = NO;
            for (unsigned i = 0; i < n && !found; i++) {
                if (method_getName(ms[i]) == sel) { found = YES; real = method_getImplementation(ms[i]) != (IMP)ShimMissing; }
            }
            free(ms);
            if (found) return real;
        }
        return NO;
    }
    return [super respondsToSelector:sel];
}
- (void)textFieldDidBeginEditing:(UITextField *)textField {
    [self shimNotifyText:@"DidBeginEditing"];
}
- (void)shimTextChanged:(UITextField *)textField {
    _stringValue = [textField.text copy] ?: @"";
    ShimBindingPush(self, @"value", _stringValue); // UIKit taps on buttons don't end editing, so commit as typed
    if (![self shimUsesSecureTextEntry]) _uiLabel.text = _stringValue;
    [self shimNotifyText:@"DidChange"];
}
- (void)textFieldDidEndEditing:(UITextField *)textField {
    ShimBindingPush(self, @"value", _stringValue);
    [self shimNotifyText:@"DidEndEditing"];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    ShimPerformUserAction(^{ [self sendAction:self.action to:self.target]; });
    [textField resignFirstResponder];
    return YES;
}
@end

__attribute__((visibility("default")))
@interface NSTextView : NSView
@property (nonatomic, copy) NSString *string;
@property (nonatomic) BOOL usesAdaptiveColorMappingForDarkAppearance;
@property (nonatomic, strong, readonly) UITextView *uiTextView;
@end
@implementation NSTextView
SHIM_RESOLVE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _uiTextView = [[UITextView alloc] initWithFrame:self.hostView.bounds];
        _uiTextView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _uiTextView.backgroundColor = UIColor.clearColor;
        [self.hostView addSubview:_uiTextView];
    }
    return self;
}
- (void)setString:(NSString *)string {
    _string = [string copy] ?: @"";
    _uiTextView.text = _string;
}
@end

__attribute__((visibility("default")))
@interface NSPopUpButton : NSButton
@end
@implementation NSPopUpButton
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSProgressIndicator : NSView
@property (nonatomic) double doubleValue;
@property (nonatomic) double maxValue;
@property (nonatomic) double minValue;
@property (nonatomic, getter=isIndeterminate) BOOL indeterminate;
@property (nonatomic, strong, readonly) UIActivityIndicatorView *spinner;
@end
@implementation NSProgressIndicator
SHIM_RESOLVE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.center = CGPointMake(frame.size.width * 0.5, frame.size.height * 0.5);
        _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                    UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self.hostView addSubview:_spinner];
    }
    return self;
}
- (void)startAnimation:(id)sender { (void)sender; [_spinner startAnimating]; }
- (void)stopAnimation:(id)sender { (void)sender; [_spinner stopAnimating]; }
@end

__attribute__((visibility("default")))
@interface NSPopover : NSResponder
@property (nonatomic, strong) NSViewController *contentViewController;
@property (nonatomic, weak) id delegate;
@end
@implementation NSPopover
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSMenuItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) SEL action;
@property (nonatomic, weak) id target;
@property (nonatomic, strong) id submenu;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) NSInteger tag;
@property (nonatomic, strong) id representedObject;
@end
@implementation NSMenuItem
SHIM_RESOLVE
- (instancetype)initWithTitle:(NSString *)title action:(SEL)selector keyEquivalent:(NSString *)charCode {
    (void)charCode;
    if ((self = [super init])) {
        _title = [title copy] ?: @"";
        _action = selector;
        _enabled = YES;
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    NSString *t = [coder decodeObjectForKey:@"NSTitle"];
    if ((self = [self initWithTitle:t ?: @"" action:NULL keyEquivalent:@""])) {
        _tag = [coder decodeIntegerForKey:@"NSTag"];
        _submenu = [coder decodeObjectForKey:@"NSSubmenu"];
        if ([coder containsValueForKey:@"NSIsDisabled"]) {
            _enabled = ![coder decodeBoolForKey:@"NSIsDisabled"];
        }
    }
    return self;
}
+ (instancetype)separatorItem { return [self new]; }
@end

__attribute__((visibility("default")))
@interface NSMenu : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong, readonly) NSMutableArray<NSMenuItem *> *shimItems;
@end
@implementation NSMenu
SHIM_RESOLVE
- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super init])) {
        _title = [title copy] ?: @"";
        _shimItems = [NSMutableArray new];
    }
    return self;
}
- (instancetype)init { return [self initWithTitle:@""]; }
- (instancetype)initWithCoder:(NSCoder *)coder {
    NSString *t = [coder decodeObjectForKey:@"NSTitle"];
    if ((self = [self initWithTitle:t ?: @""])) {
        NSArray *items = [coder decodeObjectForKey:@"NSMenuItems"];
        if ([items isKindOfClass:NSArray.class]) {
            for (id it in items) {
                if ([it isKindOfClass:NSMenuItem.class]) [_shimItems addObject:it];
            }
        }
    }
    return self;
}
- (void)addItem:(NSMenuItem *)item { if (item) [_shimItems addObject:item]; }
- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(SEL)selector keyEquivalent:(NSString *)charCode {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:charCode];
    [self addItem:item];
    return item;
}
- (NSArray<NSMenuItem *> *)itemArray { return [_shimItems copy]; }
- (NSInteger)numberOfItems { return (NSInteger)_shimItems.count; }
- (NSMenuItem *)itemAtIndex:(NSInteger)index { return (index >= 0 && index < (NSInteger)_shimItems.count) ? _shimItems[index] : nil; }
- (NSMenuItem *)itemWithTag:(NSInteger)tag {
    for (NSMenuItem *item in _shimItems) {
        if (item.tag == tag) return item;
    }
    return nil;
}
@end

__attribute__((visibility("default")))
@interface NSSavePanel : NSWindow
@property (nonatomic, copy) NSURL *URL;
@end
@implementation NSSavePanel
SHIM_RESOLVE
+ (instancetype)savePanel { return [self new]; }
- (NSInteger)runModal { return 0; } // NSModalResponseCancel
@end

__attribute__((visibility("default")))
@interface NSOpenPanel : NSSavePanel
@property (nonatomic, copy) NSArray<NSURL *> *URLs;
@end
@implementation NSOpenPanel
SHIM_RESOLVE
+ (instancetype)openPanel { return [self new]; }
- (NSArray<NSURL *> *)URLs { return _URLs ?: @[]; }
@end

__attribute__((visibility("default")))
@interface NSRunningApplication : NSObject
@property (nonatomic, readonly) pid_t processIdentifier;
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly, copy) NSURL *bundleURL;
@property (nonatomic, readonly, getter=isTerminated) BOOL terminated;
@property (nonatomic, readonly, getter=isActive) BOOL active;
@end
@implementation NSRunningApplication
SHIM_RESOLVE
+ (instancetype)currentApplication {
    static NSRunningApplication *cur;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cur = [self new]; });
    return cur;
}
+ (NSArray<NSRunningApplication *> *)runningApplicationsWithBundleIdentifier:(NSString *)bundleIdentifier {
    (void)bundleIdentifier;
    return @[];
}
- (pid_t)processIdentifier { return getpid(); }
- (NSString *)bundleIdentifier { return NSBundle.mainBundle.bundleIdentifier; }
- (NSURL *)bundleURL { return NSBundle.mainBundle.bundleURL; }
- (NSURL *)executableURL { return NSBundle.mainBundle.executableURL; }
- (BOOL)isActive { return YES; }
- (BOOL)activateWithOptions:(NSUInteger)options { (void)options; return YES; }
@end

__attribute__((visibility("default")))
@interface NSWorkspace : NSObject
@property (nonatomic, strong, readonly) NSNotificationCenter *notificationCenter;
@end
@implementation NSWorkspace
SHIM_RESOLVE
+ (instancetype)sharedWorkspace {
    static NSWorkspace *ws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ws = [self new]; });
    return ws;
}
- (instancetype)init {
    if ((self = [super init])) _notificationCenter = [NSNotificationCenter new];
    return self;
}
- (NSArray<NSRunningApplication *> *)runningApplications { return @[[NSRunningApplication currentApplication]]; }
- (BOOL)openURL:(NSURL *)url {
    if (!NSThread.isMainThread || !gUserActionDepth) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if ((![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) ||
        !url.host.length || url.user || url.password) return NO;
    UIApplication *application = UIApplication.sharedApplication;
    if (![application canOpenURL:url]) return NO;
    [application openURL:url options:@{} completionHandler:nil];
    // UIKit reports the outcome asynchronously. YES means the handoff was submitted.
    return YES;
}
- (NSImage *)iconForFile:(NSString *)fullPath { (void)fullPath; return [[NSImage alloc] initWithSize:CGSizeMake(32, 32)]; }
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)bid { (void)bid; return nil; }
@end

__attribute__((visibility("default")))
@interface NSWindowController : NSResponder
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSViewController *contentViewController;
@property (nonatomic, copy) NSString *windowNibName;
@property (nonatomic, weak) id owner;
- (instancetype)initWithWindow:(NSWindow *)window;
- (instancetype)initWithWindowNibName:(NSString *)windowNibName;
- (instancetype)initWithWindowNibName:(NSString *)windowNibName owner:(id)owner;
@end
@implementation NSWindowController {
    BOOL _shimWindowLoadAttempted;
}
SHIM_RESOLVE
- (instancetype)initWithWindow:(NSWindow *)window {
    if ((self = [super init])) _window = window;
    return self;
}
- (instancetype)initWithWindowNibName:(NSString *)windowNibName {
    return [self initWithWindowNibName:windowNibName owner:self];
}
- (instancetype)initWithWindowNibName:(NSString *)windowNibName owner:(id)owner {
    if ((self = [super init])) {
        _windowNibName = [windowNibName copy];
        _owner = owner ?: self;
    }
    return self;
}
// As in AppKit: the nib is looked up in the bundle of the owner's class (Sparkle's windows live in Sparkle.framework),
// the window loads once (windowDidLoad overrides that ask for self.window must not reload it), and a subclass may
// supply the nib name by overriding -windowNibName.
- (void)loadWindow {
    NSString *nib = self.windowNibName;
    if (_window || !nib.length) return;
    id owner = _owner ?: self;
    NSArray *tops = nil;
    NSBundle *b = [NSBundle bundleForClass:[owner class]];
    if (![b pathForResource:nib ofType:@"nib"]) b = NSBundle.mainBundle;
    [b loadNibNamed:nib owner:owner topLevelObjects:&tops];
    if (!_window) {
        for (id o in tops) {
            if ([o isKindOfClass:NSWindow.class]) { _window = o; break; }
        }
    }
}
- (BOOL)isWindowLoaded { return _window != nil || _shimWindowLoadAttempted; }
- (void)windowWillLoad {}
- (NSWindow *)window {
    if (!_window && !_shimWindowLoadAttempted && self.windowNibName.length) {
        _shimWindowLoadAttempted = YES;
        [self windowWillLoad];
        [self loadWindow];
        [self windowDidLoad];
    }
    return _window;
}
- (void)windowDidLoad {}
- (void)showWindow:(id)sender { (void)sender; [self.window makeKeyAndOrderFront:sender]; }
- (void)close { [_window close]; }
@end

// MARK: Additional Nib & Control Classes

@implementation NSActionCell
SHIM_RESOLVE
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) {
        NSString *c = [coder decodeObjectForKey:@"NSContents"];
        if ([c isKindOfClass:NSString.class]) {
            _stringValue = c;
            _title = c;
        }
        // NSCell's keyed archive stores these attributes in NSCellFlags.
        uint32_t flags = (uint32_t)[coder decodeInt32ForKey:@"NSCellFlags"];
        _selectable = (flags & 0x00200000) != 0;
        _bezeled = (flags & 0x00400000) != 0;
        _bordered = (flags & 0x00800000) != 0;
        _editable = (flags & 0x10000000) != 0;
        _state = (flags & 0x80000000) != 0;
        _tag = [coder decodeIntegerForKey:@"NSTag"];
        id font = [coder decodeObjectForKey:@"NSSupport"];
        if (font && [NSStringFromClass([font class]) isEqualToString:@"NSFont"]) _font = font;
        id key = [coder decodeObjectForKey:@"NSKeyEquivalent"];
        if ([key isKindOfClass:NSString.class]) _keyEquivalent = key;
        _shimButtonType = [coder containsValueForKey:@"NSAuxButtonType"] ? [coder decodeIntegerForKey:@"NSAuxButtonType"] : -1;
        _shimBezelStyle = [coder decodeIntegerForKey:@"NSBezelStyle"];
    }
    return self;
}
@end

#define SHIM_EMPTY_SUBCLASS(name, base) \
    __attribute__((visibility("default"))) @interface name : base @end \
    @implementation name SHIM_RESOLVE @end

SHIM_EMPTY_SUBCLASS(NSButtonCell, NSActionCell)
SHIM_EMPTY_SUBCLASS(NSTextFieldCell, NSActionCell)
SHIM_EMPTY_SUBCLASS(NSSearchFieldCell, NSTextFieldCell)
SHIM_EMPTY_SUBCLASS(NSSecureTextFieldCell, NSTextFieldCell)
SHIM_EMPTY_SUBCLASS(NSLevelIndicatorCell, NSActionCell)
SHIM_EMPTY_SUBCLASS(NSPathCell, NSActionCell)
SHIM_EMPTY_SUBCLASS(NSPathComponentCell, NSActionCell)
SHIM_EMPTY_SUBCLASS(NSSearchField, NSTextField)
__attribute__((visibility("default")))
@interface NSSecureTextField : NSTextField
@end
@implementation NSSecureTextField
- (BOOL)shimUsesSecureTextEntry { return YES; }
@end
SHIM_EMPTY_SUBCLASS(NSStackView, NSView)
SHIM_EMPTY_SUBCLASS(NSStackViewContainer, NSView)
SHIM_EMPTY_SUBCLASS(NSTabView, NSView)
SHIM_EMPTY_SUBCLASS(NSTabViewItem, NSObject)
SHIM_EMPTY_SUBCLASS(NSLevelIndicator, NSControl)
SHIM_EMPTY_SUBCLASS(NSPathControl, NSControl)
__attribute__((visibility("default")))
@interface NSMatrix : NSControl
@property (nonatomic, copy, readonly) NSArray<NSActionCell *> *cells;
@property (nonatomic, readonly) NSInteger numberOfRows;
@property (nonatomic, readonly) NSInteger numberOfColumns;
@property (nonatomic) NSInteger selectedIndex;
@end

@implementation NSMatrix {
    UIStackView *_grid;
    NSMutableArray<UIButton *> *_buttons;
}
SHIM_RESOLVE

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _cells = @[];
        _selectedIndex = -1;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        NSInteger rows = [coder decodeIntegerForKey:@"NSNumRows"];
        NSInteger columns = [coder decodeIntegerForKey:@"NSNumCols"];
        NSArray *cells = [coder decodeObjectForKey:@"NSCells"];
        if (![cells isKindOfClass:NSArray.class] || rows < 1 || columns < 1 ||
            rows > (NSInteger)cells.count / columns || rows * columns != (NSInteger)cells.count) return self;
        for (id cell in cells) {
            if (![cell isKindOfClass:NSActionCell.class]) return self;
        }
        _numberOfRows = rows;
        _numberOfColumns = columns;
        _cells = [cells copy];
        [self shimBuildGrid];
        NSInteger row = [coder containsValueForKey:@"NSSelectedRow"] ? [coder decodeIntegerForKey:@"NSSelectedRow"] : -1;
        NSInteger column = [coder containsValueForKey:@"NSSelectedCol"] ? [coder decodeIntegerForKey:@"NSSelectedCol"] : -1;
        if (row < 0 || column < 0) {
            // Interface Builder can encode the initial selection on the cell instead.
            self.selectedIndex = [_cells indexOfObjectPassingTest:^BOOL(NSActionCell *cell, NSUInteger index, BOOL *stop) {
                return cell.state != 0;
            }];
        } else {
            [self selectCellAtRow:row column:column];
        }
    }
    return self;
}

- (void)shimBuildGrid {
    _buttons = [NSMutableArray arrayWithCapacity:_cells.count];
    _grid = [[UIStackView alloc] initWithFrame:self.hostView.bounds];
    _grid.axis = UILayoutConstraintAxisVertical;
    _grid.distribution = UIStackViewDistributionFillEqually;
    _grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    for (NSInteger row = 0; row < _numberOfRows; row++) {
        UIStackView *line = [UIStackView new];
        line.distribution = UIStackViewDistributionFillEqually;
        for (NSInteger column = 0; column < _numberOfColumns; column++) {
            NSInteger index = row * _numberOfColumns + column;
            // A plain button with a radio symbol: UIKit's system button paints a tinted block when selected.
            UIButton *button = [UIButton buttonWithConfiguration:[UIButtonConfiguration plainButtonConfiguration] primaryAction:nil];
            button.tag = index;
            button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            button.accessibilityLabel = _cells[index].title;
            [self shimStyleRadio:button selected:NO];
            [button addTarget:self action:@selector(shimChoose:) forControlEvents:UIControlEventTouchUpInside];
            [line addArrangedSubview:button];
            [_buttons addObject:button];
        }
        [_grid addArrangedSubview:line];
    }
    [self.hostView addSubview:_grid];
}

- (void)shimStyleRadio:(UIButton *)button selected:(BOOL)selected {
    NSActionCell *cell = _cells[button.tag];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);
    cfg.imagePadding = 6.0;
    cfg.baseForegroundColor = UIColor.labelColor;
    cfg.image = [[UIImage systemImageNamed:(selected ? @"largecircle.fill.circle" : @"circle") withConfiguration:
                  [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightRegular]]
                 imageWithTintColor:(selected ? UIColor.systemBlueColor : UIColor.secondaryLabelColor)
                      renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIFont *font = cell.font.uiFont ?: [UIFont systemFontOfSize:13.0];
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *d = [incoming mutableCopy];
        d[NSFontAttributeName] = font;
        return d;
    };
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.title = cell.title;
    button.configuration = cfg;
    // iOS lays SF out a little wider than AppKit: shrink slightly rather than cut the label off.
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.85;
    button.accessibilityTraits = selected ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
}

- (void)shimChoose:(UIButton *)button {
    self.selectedIndex = button.tag;
    ShimPerformUserAction(^{ [self sendAction:self.action to:self.target]; });
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    if (selectedIndex < 0 || selectedIndex >= (NSInteger)_cells.count) selectedIndex = -1;
    _selectedIndex = selectedIndex;
    for (NSUInteger index = 0; index < _cells.count; index++) {
        BOOL selected = (NSInteger)index == selectedIndex;
        _cells[index].state = selected;
        if (index < _buttons.count) [self shimStyleRadio:_buttons[index] selected:selected];
    }
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    for (UIButton *button in _buttons) button.enabled = enabled;
}

- (NSInteger)selectedRow { return _selectedIndex < 0 ? -1 : _selectedIndex / _numberOfColumns; }
- (NSInteger)selectedColumn { return _selectedIndex < 0 ? -1 : _selectedIndex % _numberOfColumns; }
- (NSActionCell *)selectedCell { return _selectedIndex < 0 ? nil : _cells[_selectedIndex]; }
- (NSInteger)selectedTag { return self.selectedCell.tag; }
- (void)selectCellAtRow:(NSInteger)row column:(NSInteger)column {
    if (row < 0 || row >= _numberOfRows || column < 0 || column >= _numberOfColumns) return;
    self.selectedIndex = row * _numberOfColumns + column;
}
@end
SHIM_EMPTY_SUBCLASS(NSGridView, NSView)
SHIM_EMPTY_SUBCLASS(NSGridCell, NSObject)
SHIM_EMPTY_SUBCLASS(NSGridRow, NSObject)
SHIM_EMPTY_SUBCLASS(NSGridColumn, NSObject)
SHIM_EMPTY_SUBCLASS(NSArrayController, NSObject)
SHIM_EMPTY_SUBCLASS(NSObjectController, NSObject)
SHIM_EMPTY_SUBCLASS(NSColorSpace, NSObject)
SHIM_EMPTY_SUBCLASS(NSCursor, NSObject)

__attribute__((visibility("default")))
@interface NSSplitViewItem : NSObject
@property (nonatomic, strong) NSViewController *viewController;
@end
@implementation NSSplitViewItem
SHIM_RESOLVE
+ (instancetype)sidebarWithViewController:(NSViewController *)vc {
    NSSplitViewItem *item = [self new];
    item.viewController = vc;
    return item;
}
+ (instancetype)splitViewItemWithViewController:(NSViewController *)vc {
    NSSplitViewItem *item = [self new];
    item.viewController = vc;
    return item;
}
@end

__attribute__((visibility("default")))
@interface NSSplitViewController : NSViewController
@property (nonatomic, strong, readonly) NSMutableArray<NSSplitViewItem *> *shimItems;
@end
@implementation NSSplitViewController
SHIM_RESOLVE
- (instancetype)init {
    if ((self = [super init])) _shimItems = [NSMutableArray new];
    return self;
}
- (NSArray<NSSplitViewItem *> *)splitViewItems { return [_shimItems copy]; }
- (void)addSplitViewItem:(NSSplitViewItem *)item { if (item) [_shimItems addObject:item]; }
@end

__attribute__((visibility("default")))
@interface NSTrackingArea : NSObject
@end
@implementation NSTrackingArea
SHIM_RESOLVE
- (instancetype)initWithRect:(CGRect)rect options:(NSUInteger)options owner:(id)owner userInfo:(NSDictionary *)userInfo {
    (void)rect; (void)options; (void)owner; (void)userInfo;
    return [super init];
}
@end

__attribute__((visibility("default")))
@interface NSUserDefaultsController : NSObject
@end
@implementation NSUserDefaultsController
SHIM_RESOLVE
+ (instancetype)sharedUserDefaultsController {
    static NSUserDefaultsController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [self new]; });
    return c;
}
- (id)values { return NSUserDefaults.standardUserDefaults; }
@end

__attribute__((visibility("default")))
@interface NSDraggingImageComponent : NSObject
@end
@implementation NSDraggingImageComponent
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSTouchBar : NSObject
@end
@implementation NSTouchBar
SHIM_RESOLVE
@end

__attribute__((visibility("default")))
@interface NSCustomTouchBarItem : NSObject
@end
@implementation NSCustomTouchBarItem
SHIM_RESOLVE
@end

// MARK: Cocoa bindings (two-way, observed)
// 2026-11-24 (device log): bindings were applied once and never written back, so CrossOver's registration form never
// saw the typed login (NSContinuouslyUpdatesValue=0 fields commit through infoForBinding:), and enabled2/hidden2
// (AppKit's AND/OR binding families) failed. Each binding now keeps its info, observes the model with KVO, writes
// edits back, and folds enabledN with AND and hiddenN with OR, as AppKit does.

__attribute__((visibility("default"))) NSString *const NSOptionsKey = @"NSOptions";

@interface ShimBindingInfo : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic, copy) NSString *binding;
@property (nonatomic, weak) id observable;
@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, copy) NSDictionary *options;
@property (nonatomic) BOOL observing;
@property (nonatomic) BOOL pushing;
@end

static const void *kShimBindingsKey = &kShimBindingsKey;

static NSMutableDictionary<NSString *, ShimBindingInfo *> *ShimBindingsOf(id obj, BOOL create) {
    if (!obj) return nil;
    NSMutableDictionary *d = objc_getAssociatedObject(obj, kShimBindingsKey);
    if (!d && create) {
        d = [NSMutableDictionary new];
        objc_setAssociatedObject(obj, kShimBindingsKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return d;
}

static NSString *ShimBindingFamily(NSString *binding) {
    NSUInteger n = binding.length;
    while (n > 0 && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[binding characterAtIndex:n - 1]]) n--;
    NSString *base = [binding substringToIndex:n];
    return ([base isEqualToString:@"enabled"] || [base isEqualToString:@"hidden"]) ? base : nil;
}

static BOOL ShimBindingRead(ShimBindingInfo *info, id *outVal) {
    id observable = info.observable;
    if (!observable || !info.keyPath.length) return NO;
    id val = nil;
    @try {
        val = [observable valueForKeyPath:info.keyPath];
    } @catch (NSException *ex) {
        fprintf(stderr, "NSBinding KVC read failed [%s valueForKeyPath:%s]: %s\n",
                class_getName([observable class]), info.keyPath.UTF8String, ex.reason.UTF8String ?: "");
        fflush(stderr);
        return NO;
    }
    NSDictionary *options = [info.options isKindOfClass:NSDictionary.class] ? info.options : nil;
    NSString *xform = options[@"NSValueTransformerName"];
    if ([xform isEqualToString:@"NSNegateBoolean"]) {
        val = @(![val boolValue]);
    } else if ([xform isEqualToString:@"NSIsNil"]) {
        val = @(val == nil || val == NSNull.null);
    } else if ([xform isEqualToString:@"NSIsNotNil"]) {
        val = @(val != nil && val != NSNull.null);
    } else if (xform.length) {
        NSValueTransformer *t = [NSValueTransformer valueTransformerForName:xform];
        if (t) val = [t transformedValue:val];
    }
    if (val == NSNull.null) val = nil;
    *outVal = val;
    return YES;
}

static void ShimRefreshBinding(id target, NSString *binding) {
    NSMutableDictionary<NSString *, ShimBindingInfo *> *all = ShimBindingsOf(target, NO);
    ShimBindingInfo *info = all[binding];
    if (!target || !info) return;
    NSString *family = ShimBindingFamily(binding);
    @try {
        if (family) {
            BOOL isEnabled = [family isEqualToString:@"enabled"];
            BOOL agg = isEnabled; // enabled: AND of all; hidden: OR of all
            for (NSString *b in all) {
                if (![ShimBindingFamily(b) isEqualToString:family]) continue;
                id v = nil;
                if (!ShimBindingRead(all[b], &v)) continue;
                BOOL on = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : v != nil;
                agg = isEnabled ? (agg && on) : (agg || on);
            }
            [target setValue:@(agg) forKey:family];
            return;
        }
        id val = nil;
        if (!ShimBindingRead(info, &val)) return;
        if ([binding isEqualToString:@"value"]) {
            if ([target respondsToSelector:@selector(setStringValue:)]) {
                NSString *str = [val isKindOfClass:NSString.class] ? val
                    : (val == nil ? @"" : ([val respondsToSelector:@selector(stringValue)] ? [val stringValue] : [val description]));
                if (![[target valueForKey:@"stringValue"] isEqual:str]) [target setValue:(str ?: @"") forKey:@"stringValue"];
            } else {
                [target setValue:val forKey:@"objectValue"];
            }
        } else {
            [target setValue:val forKey:binding];
        }
    } @catch (NSException *ex) {
        fprintf(stderr, "NSBinding KVC write failed [%s setValue:forKey:%s]: %s\n",
                class_getName([target class]), binding.UTF8String, ex.reason.UTF8String ?: "");
        fflush(stderr);
    }
}

@implementation ShimBindingInfo
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (self.pushing) return; // our own write-back: the view already shows it
    __weak ShimBindingInfo *weakSelf = self;
    void (^refresh)(void) = ^{
        ShimBindingInfo *info = weakSelf;
        if (info && !info.pushing) ShimRefreshBinding(info.target, info.binding);
    };
    if (NSThread.isMainThread) refresh(); else dispatch_async(dispatch_get_main_queue(), refresh);
}
- (void)stop {
    id observable = self.observable;
    if (self.observing && observable) {
        @try { [observable removeObserver:self forKeyPath:self.keyPath]; } @catch (NSException *ex) { (void)ex; }
    }
    self.observing = NO;
}
- (void)dealloc { [self stop]; }
@end

/// Write an edit from the view back to the bound model (text typed, checkbox toggled, item picked).
__attribute__((visibility("default")))
void ShimBindingPush(id target, NSString *binding, id value) {
    ShimBindingInfo *info = ShimBindingsOf(target, NO)[binding];
    id observable = info.observable;
    if (!info || !observable || !info.keyPath.length) return;
    NSString *xform = [info.options isKindOfClass:NSDictionary.class] ? info.options[@"NSValueTransformerName"] : nil;
    if ([xform isEqualToString:@"NSNegateBoolean"]) value = @(![value boolValue]);
    else if (xform.length && ![xform isEqualToString:@"NSIsNil"] && ![xform isEqualToString:@"NSIsNotNil"]) {
        NSValueTransformer *t = [NSValueTransformer valueTransformerForName:xform];
        if ([t.class allowsReverseTransformation]) value = [t reverseTransformedValue:value];
    } else if (xform.length) return; // NSIsNil/NSIsNotNil are one-way
    info.pushing = YES;
    @try {
        [observable setValue:value forKeyPath:info.keyPath];
    } @catch (NSException *ex) {
        fprintf(stderr, "NSBinding push failed [%s setValue:forKeyPath:%s]: %s\n",
                class_getName([observable class]), info.keyPath.UTF8String, ex.reason.UTF8String ?: "");
        fflush(stderr);
    }
    info.pushing = NO;
}

@implementation NSObject (ShimBindings)
- (void)bind:(NSString *)binding toObject:(id)observable withKeyPath:(NSString *)keyPath options:(NSDictionary *)options {
    fprintf(stderr, "NSObject bind:%s toObject:%s keyPath:%s options:%s\n",
            binding.UTF8String ?: "",
            observable ? class_getName([observable class]) : "(nil)",
            keyPath.UTF8String ?: "",
            options ? [[options description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "(nil)");
    fflush(stderr);
    if (!binding.length || !observable || !keyPath.length) return;
    [self unbind:binding];
    ShimBindingInfo *info = [ShimBindingInfo new];
    info.target = self;
    info.binding = binding;
    info.observable = observable;
    info.keyPath = keyPath;
    info.options = [options isKindOfClass:NSDictionary.class] ? options : nil;
    ShimBindingsOf(self, YES)[binding] = info;
    @try {
        [observable addObserver:info forKeyPath:keyPath options:0 context:NULL];
        info.observing = YES;
    } @catch (NSException *ex) {
        fprintf(stderr, "NSBinding observe failed [%s %s]: %s\n", class_getName([observable class]), keyPath.UTF8String,
                ex.reason.UTF8String ?: "");
        fflush(stderr);
    }
    ShimRefreshBinding(self, binding);
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ShimRefreshBinding(weakSelf, binding); });
}
- (void)unbind:(NSString *)binding {
    NSMutableDictionary *all = ShimBindingsOf(self, NO);
    ShimBindingInfo *info = all[binding];
    if (!info) return;
    [info stop];
    [all removeObjectForKey:binding];
}
- (NSDictionary *)infoForBinding:(NSString *)binding {
    ShimBindingInfo *info = ShimBindingsOf(self, NO)[binding];
    id observable = info.observable;
    if (!info || !observable) return nil;
    return @{NSObservedObjectKey: observable, NSObservedKeyPathKey: info.keyPath, NSOptionsKey: info.options ?: @{}};
}
- (NSArray *)exposedBindings { return ShimBindingsOf(self, NO).allKeys ?: @[]; }
@end

// MARK: Host Registration API

__attribute__((visibility("default")))
void ShimHostRegister(UIWindow *window,
                      UIViewController *rootVC,
                      UIView *containerView,
                      NSString *macBundleRoot) {
    gHostedMode = YES;
    gHostWindow = window;
    gRootVC = rootVC;
    gHostContainer = containerView ?: rootVC.view;
    gMacBundleRoot = [macBundleRoot copy];
    if (!gWindows) gWindows = [NSMutableArray new];
    if (gMacBundleRoot.length > 0) {
        ShimInstallBundleHooks();
    }
    fprintf(stderr, "libShim_AppKit: hosted on window=%p container=%p macRoot=%s\n",
            (__bridge void *)gHostWindow,
            (__bridge void *)gHostContainer,
            gMacBundleRoot ? gMacBundleRoot.UTF8String : "(none)");
    fflush(stderr);
}

__attribute__((visibility("default")))
void ShimHostRegisterFullscreen(UIWindow *window, UIViewController *rootVC, UIView *containerView,
                                NSString *macBundleRoot) {
    gHostFullscreen = YES;
    ShimHostRegister(window, rootVC, containerView, macBundleRoot);
}

__attribute__((visibility("default")))
void ShimHostSizeChanged(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"NSApplicationDidChangeScreenParametersNotification"
                                                      object:NSApp];
    for (NSWindow *window in [gWindows copy]) {
        ShimLayoutWindow(window, NO);
    }
}

// MARK: - HTML import (-[NSAttributedString initWithHTML:...])
// iOS imports HTML through WebKit, which spins a nested run loop and never returns when a guest calls it from a
// SwiftUI body (CrossOver's catalog descriptions do). Mac apps use it for short rich text, so a small converter
// covers them: paragraphs and line breaks, lists, bold/italic, links and character entities.

static NSString *ShimHTMLDecodeEntities(NSString *s) {
    if ([s rangeOfString:@"&"].location == NSNotFound) return s;
    static NSDictionary<NSString *, NSString *> *named;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{@"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"", @"apos": @"'", @"nbsp": @" ",
                  @"copy": @"©", @"reg": @"®", @"trade": @"™", @"hellip": @"…",
                  @"mdash": @"—", @"ndash": @"–", @"rsquo": @"’", @"lsquo": @"‘",
                  @"rdquo": @"”", @"ldquo": @"“", @"bull": @"•"};
    });
    NSMutableString *out = [NSMutableString string];
    NSScanner *sc = [NSScanner scannerWithString:s];
    sc.charactersToBeSkipped = nil;
    while (!sc.isAtEnd) {
        NSString *chunk = nil;
        if ([sc scanUpToString:@"&" intoString:&chunk]) [out appendString:chunk];
        if (sc.isAtEnd) break;
        NSUInteger at = sc.scanLocation;
        NSRange semi = [s rangeOfString:@";" options:0 range:NSMakeRange(at, MIN((NSUInteger)12, s.length - at))];
        NSString *rep = nil;
        if (semi.location != NSNotFound) {
            NSString *name = [s substringWithRange:NSMakeRange(at + 1, semi.location - at - 1)];
            if ([name hasPrefix:@"#"]) {
                unsigned v = 0;
                NSScanner *ns = [NSScanner scannerWithString:[name substringFromIndex:1]];
                BOOL ok = [name hasPrefix:@"#x"] || [name hasPrefix:@"#X"]
                    ? ([ns setScanLocation:1], [ns scanHexInt:&v]) : [ns scanInt:(int *)&v];
                if (ok && v > 0 && v < 0x110000) {
                    UTF32Char c = v;
                    rep = [[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding];
                }
            } else {
                rep = named[name.lowercaseString];
            }
        }
        if (rep) {
            [out appendString:rep];
            sc.scanLocation = semi.location + 1;
        } else {
            [out appendString:@"&"];
            sc.scanLocation = at + 1;
        }
    }
    return out;
}

static NSAttributedString *ShimAttributedStringFromHTML(NSString *html) {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    CGFloat size = 13;
    UIFont *regular = [UIFont systemFontOfSize:size];
    int bold = 0, italic = 0, listDepth = 0, skip = 0;
    NSMutableArray<NSString *> *links = [NSMutableArray array];
    __block BOOL pendingSpace = NO;
    void (^newline)(void) = ^{
        pendingSpace = NO;
        if (out.length && ![out.string hasSuffix:@"\n"]) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    };
    NSScanner *sc = [NSScanner scannerWithString:html];
    sc.charactersToBeSkipped = nil;
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (!sc.isAtEnd) {
        NSString *text = nil;
        if ([sc scanUpToString:@"<" intoString:&text] && !skip) {
            // HTML whitespace: any run is one space, none at the start of a line.
            NSMutableString *t = [NSMutableString string];
            BOOL lead = [ws characterIsMember:[text characterAtIndex:0]];
            for (NSString *w in [text componentsSeparatedByCharactersInSet:ws]) {
                if (!w.length) continue;
                BOOL space = t.length ? YES : (pendingSpace || lead) && out.length && ![out.string hasSuffix:@"\n"];
                if (space) [t appendString:@" "];
                [t appendString:w];
            }
            pendingSpace = (t.length || pendingSpace || lead) && [ws characterIsMember:[text characterAtIndex:text.length - 1]];
            if (t.length) {
                UIFontDescriptorSymbolicTraits traits = (bold ? UIFontDescriptorTraitBold : 0) | (italic ? UIFontDescriptorTraitItalic : 0);
                UIFontDescriptor *d = [regular.fontDescriptor fontDescriptorWithSymbolicTraits:traits] ?: regular.fontDescriptor;
                NSMutableDictionary *attrs = [@{NSFontAttributeName: [UIFont fontWithDescriptor:d size:size]} mutableCopy];
                if (links.count && links.lastObject.length) {
                    NSURL *url = [NSURL URLWithString:links.lastObject];
                    if (url) attrs[NSLinkAttributeName] = url;
                }
                [out appendAttributedString:[[NSAttributedString alloc] initWithString:ShimHTMLDecodeEntities(t) attributes:attrs]];
            }
        }
        if (sc.isAtEnd) break;
        NSString *tag = nil;
        sc.scanLocation += 1;
        if (![sc scanUpToString:@">" intoString:&tag]) tag = @"";
        if (!sc.isAtEnd) sc.scanLocation += 1;
        if ([tag hasPrefix:@"!"]) continue;
        BOOL closing = [tag hasPrefix:@"/"];
        NSString *body = closing ? [tag substringFromIndex:1] : tag;
        NSString *name = [[body componentsSeparatedByCharactersInSet:ws].firstObject lowercaseString] ?: @"";
        if ([name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];
        if ([name isEqualToString:@"script"] || [name isEqualToString:@"style"] || [name isEqualToString:@"head"]) {
            skip += closing ? -1 : 1;
            if (skip < 0) skip = 0;
        } else if ([name isEqualToString:@"br"]) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
            pendingSpace = NO;
        } else if ([@[@"p", @"div", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"tr", @"table"] containsObject:name]) {
            newline();
        } else if ([name isEqualToString:@"ul"] || [name isEqualToString:@"ol"]) {
            listDepth += closing ? -1 : 1;
            if (listDepth < 0) listDepth = 0;
            newline();
        } else if ([name isEqualToString:@"li"]) {
            newline();
            if (!closing) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"• " attributes:@{NSFontAttributeName: regular}]];
        } else if ([name isEqualToString:@"b"] || [name isEqualToString:@"strong"]) {
            bold += closing ? -1 : 1;
            if (bold < 0) bold = 0;
        } else if ([name isEqualToString:@"i"] || [name isEqualToString:@"em"]) {
            italic += closing ? -1 : 1;
            if (italic < 0) italic = 0;
        } else if ([name isEqualToString:@"a"]) {
            if (closing) {
                if (links.count) [links removeLastObject];
            } else {
                NSString *href = @"";
                NSRange r = [body rangeOfString:@"href=" options:NSCaseInsensitiveSearch];
                if (r.location != NSNotFound && NSMaxRange(r) < body.length) {
                    NSString *rest = [body substringFromIndex:NSMaxRange(r)];
                    unichar q = [rest characterAtIndex:0];
                    if (q == '"' || q == '\'') {
                        NSRange end = [rest rangeOfString:[NSString stringWithCharacters:&q length:1] options:0 range:NSMakeRange(1, rest.length - 1)];
                        href = end.location == NSNotFound ? [rest substringFromIndex:1] : [rest substringWithRange:NSMakeRange(1, end.location - 1)];
                    } else {
                        href = [rest componentsSeparatedByCharactersInSet:ws].firstObject;
                    }
                }
                [links addObject:ShimHTMLDecodeEntities(href)];
            }
        }
    }
    while ([out.string hasSuffix:@"\n"]) [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    return out;
}

static NSString *ShimHTMLString(NSData *data, NSDictionary *options) {
    NSStringEncoding enc = NSUTF8StringEncoding;
    id e = options[@"CharacterEncoding"];
    if ([e respondsToSelector:@selector(unsignedIntegerValue)] && [e unsignedIntegerValue]) enc = [e unsignedIntegerValue];
    NSString *s = [[NSString alloc] initWithData:data encoding:enc] ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

static id ShimInitWithHTMLOptions(id self, SEL _cmd, NSData *data, NSDictionary *options, NSDictionary **attrs) {
    if (attrs) *attrs = @{};
    return [self initWithAttributedString:ShimAttributedStringFromHTML(ShimHTMLString(data, options))];
}

static id ShimInitWithHTML(id self, SEL _cmd, NSData *data, NSDictionary **attrs) {
    return ShimInitWithHTMLOptions(self, _cmd, data, nil, attrs);
}

static id ShimInitWithHTMLBaseURL(id self, SEL _cmd, NSData *data, NSURL *base, NSDictionary **attrs) {
    return ShimInitWithHTMLOptions(self, _cmd, data, nil, attrs);
}

__attribute__((constructor)) static void ShimInstallHTMLImport(void) {
    Class c = NSAttributedString.class;
    class_replaceMethod(c, sel_registerName("initWithHTML:options:documentAttributes:"), (IMP)ShimInitWithHTMLOptions, "@@:@@^@");
    class_replaceMethod(c, sel_registerName("initWithHTML:documentAttributes:"), (IMP)ShimInitWithHTML, "@@:@^@");
    class_replaceMethod(c, sel_registerName("initWithHTML:baseURL:documentAttributes:"), (IMP)ShimInitWithHTMLBaseURL, "@@:@@^@");
}
