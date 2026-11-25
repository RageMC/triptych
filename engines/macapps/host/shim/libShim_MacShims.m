// SPDX-License-Identifier: GPL-3.0-or-later
// Shim for missing macOS system framework APIs on iOS / iOS Simulator.
// Re-exports CoreFoundation, Foundation, CoreGraphics, CoreServices, Security,
// SystemConfiguration, and IOKit, and supplies missing macOS-only symbols
// (DiskArbitration, SecurityFoundation, ServiceManagement, Authorization,
// LaunchServices, CGDisplayMode, NSAppleEventManager, etc.).

#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#define SHIM_LOG(fmt, ...) \
    do { \
        fprintf(stderr, "libShim_MacShims: " fmt "\n", ##__VA_ARGS__); \
        fflush(stderr); \
    } while (0)

#define SHIM_EXPORT __attribute__((visibility("default")))

// MARK: Unknown-selector fallback

static id MacShimMissing(id self, SEL _cmd, ...) {
    (void)self;
    (void)_cmd;
    return nil;
}

static id MacShimMissingInit(id self, SEL _cmd, ...) {
    (void)_cmd;
    return self;
}

static BOOL MacShimResolve(Class cls, SEL sel, BOOL isClass) {
    fprintf(stderr, "SHIM MISSING %c[%s %s]\n",
            isClass ? '+' : '-',
            class_getName(cls),
            sel_getName(sel));
    fflush(stderr);
    BOOL isInit = !isClass && [NSStringFromSelector(sel) hasPrefix:@"init"];
    class_addMethod(isClass ? object_getClass(cls) : cls, sel,
                    (IMP)(isInit ? MacShimMissingInit : MacShimMissing), "@@:");
    return YES;
}

#define MACSHIM_RESOLVE \
    + (BOOL)resolveInstanceMethod:(SEL)sel { return [super resolveInstanceMethod:sel] || MacShimResolve(self, sel, NO); } \
    + (BOOL)resolveClassMethod:(SEL)sel { return [super resolveClassMethod:sel] || MacShimResolve(self, sel, YES); }

// MARK: CoreFoundation macOS-only symbols

SHIM_EXPORT NSString *const NSURLQuarantinePropertiesKey = @"NSURLQuarantinePropertiesKey";

// x86_64 counts as loadable: apps ask this to decide whether Rosetta is installed (CrossOver's rosettaCheck shows a
// modal "Install Rosetta" otherwise). Triptych supplies x86 translation itself, and on iOS there is no
// softwareupdate to install Rosetta with, so "not loadable" could only end in the app quitting.
SHIM_EXPORT Boolean CFBundleIsArchitectureLoadable(cpu_type_t arch) {
    return arch == CPU_TYPE_ARM64 || arch == CPU_TYPE_X86_64;
}

static void *ShimCFHandle(void) {
    static void *h = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOLOAD);
        if (!h) h = RTLD_NEXT;
    });
    return h;
}

SHIM_EXPORT void *CFBundleGetDataPointerForName(CFBundleRef bundle, CFStringRef symbolName) {
    typedef void *(*Fn)(CFBundleRef, CFStringRef);
    static Fn realFn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        realFn = (Fn)dlsym(ShimCFHandle(), "CFBundleGetDataPointerForName");
    });
    void *p = realFn ? realFn(bundle, symbolName) : NULL;
    if (!p && symbolName) {
        char buf[512];
        if (CFStringGetCString(symbolName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            p = dlsym(RTLD_DEFAULT, buf);
        }
    }
    return p;
}

SHIM_EXPORT void *CFBundleGetFunctionPointerForName(CFBundleRef bundle, CFStringRef symbolName) {
    typedef void *(*Fn)(CFBundleRef, CFStringRef);
    static Fn realFn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        realFn = (Fn)dlsym(ShimCFHandle(), "CFBundleGetFunctionPointerForName");
    });
    void *p = realFn ? realFn(bundle, symbolName) : NULL;
    if (!p && symbolName) {
        char buf[512];
        if (CFStringGetCString(symbolName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            p = dlsym(RTLD_DEFAULT, buf);
        }
    }
    return p;
}

// MARK: CoreGraphics Display / EventSource stubs

typedef struct ShimCGDisplayMode {
    size_t width;
    size_t height;
    size_t pixelWidth;
    size_t pixelHeight;
} ShimCGDisplayMode;

SHIM_EXPORT CFTypeRef CGDisplayCopyDisplayMode(uint32_t display) {
    (void)display;
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    return (__bridge_retained CFTypeRef)@{
        @"w": @((size_t)b.size.width),
        @"h": @((size_t)b.size.height),
        @"pw": @((size_t)(b.size.width * scale)),
        @"ph": @((size_t)(b.size.height * scale)),
    };
}

SHIM_EXPORT size_t CGDisplayModeGetWidth(CFTypeRef mode) {
    NSDictionary *d = (__bridge NSDictionary *)mode;
    return [d isKindOfClass:NSDictionary.class] ? [d[@"w"] unsignedLongValue] : 390;
}

SHIM_EXPORT size_t CGDisplayModeGetPixelWidth(CFTypeRef mode) {
    NSDictionary *d = (__bridge NSDictionary *)mode;
    return [d isKindOfClass:NSDictionary.class] ? [d[@"pw"] unsignedLongValue] : 780;
}

SHIM_EXPORT void CGDisplayModeRelease(CFTypeRef mode) {
    if (mode) CFRelease(mode);
}

SHIM_EXPORT CFTimeInterval CGEventSourceSecondsSinceLastEventType(int32_t stateID, uint32_t eventType) {
    (void)stateID;
    (void)eventType;
    return 0.0;
}

// MARK: DiskArbitration stubs

SHIM_EXPORT CFStringRef const kDADiskDescriptionDeviceModelKey = CFSTR("DADeviceModel");

SHIM_EXPORT CFTypeRef DASessionCreate(CFAllocatorRef allocator) {
    (void)allocator;
    return (__bridge_retained CFTypeRef)@"ShimDASession";
}

SHIM_EXPORT CFTypeRef DADiskCreateFromBSDName(CFAllocatorRef allocator, CFTypeRef session, const char *name) {
    (void)allocator;
    (void)session;
    return (__bridge_retained CFTypeRef)(name ? @(name) : @"disk0");
}

SHIM_EXPORT CFDictionaryRef DADiskCopyDescription(CFTypeRef disk) {
    (void)disk;
    return (__bridge_retained CFDictionaryRef)@{@"DADeviceModel": @"iOS Virtual Disk"};
}

// MARK: Security (Authorization Services) & SecurityFoundation

typedef void *AuthorizationRef;
typedef uint32_t AuthorizationFlags;

SHIM_EXPORT OSStatus AuthorizationCreate(const void *rights, const void *environment,
                                         AuthorizationFlags flags, AuthorizationRef *authorization) {
    (void)rights;
    (void)environment;
    (void)flags;
    if (authorization) *authorization = (AuthorizationRef)(uintptr_t)0x1;
    return 0;
}

SHIM_EXPORT OSStatus AuthorizationCopyRights(AuthorizationRef authorization, const void *rights,
                                             const void *environment, AuthorizationFlags flags,
                                             void **authorizedRights) {
    (void)authorization;
    (void)rights;
    (void)environment;
    (void)flags;
    if (authorizedRights) *authorizedRights = NULL;
    return -60005; // errAuthorizationDenied
}

SHIM_EXPORT OSStatus AuthorizationExecuteWithPrivileges(AuthorizationRef authorization,
                                                        const char *pathToTool,
                                                        AuthorizationFlags options,
                                                        char *const *arguments,
                                                        FILE **communicationsPipe) {
    (void)authorization;
    (void)options;
    (void)arguments;
    (void)communicationsPipe;
    SHIM_LOG("STUB AuthorizationExecuteWithPrivileges(%s) -> denied", pathToTool ?: "(null)");
    return -60005;
}

SHIM_EXPORT OSStatus AuthorizationFree(AuthorizationRef authorization, AuthorizationFlags flags) {
    (void)authorization;
    (void)flags;
    return 0;
}

SHIM_EXPORT OSStatus AuthorizationRightGet(const char *rightName, CFDictionaryRef *rightDefinition) {
    (void)rightName;
    if (rightDefinition) *rightDefinition = NULL;
    return -60005;
}

SHIM_EXPORT OSStatus AuthorizationRightSet(AuthorizationRef authRef, const char *rightName,
                                           CFTypeRef rightDefinition, CFStringRef descriptionKey,
                                           CFBundleRef bundle, CFStringRef localeTableName) {
    (void)authRef;
    (void)rightName;
    (void)rightDefinition;
    (void)descriptionKey;
    (void)bundle;
    (void)localeTableName;
    return -60005;
}

SHIM_EXPORT
@interface SFAuthorization : NSObject
+ (id)authorization;
- (AuthorizationRef)authorizationRef;
@end

@implementation SFAuthorization
MACSHIM_RESOLVE
+ (id)authorization { return [self new]; }
- (AuthorizationRef)authorizationRef { return (AuthorizationRef)(uintptr_t)0x1; }
@end

// MARK: ServiceManagement stubs

SHIM_EXPORT CFStringRef const kSMDomainSystemLaunchd = CFSTR("kSMDomainSystemLaunchd");
SHIM_EXPORT CFStringRef const kSMDomainUserLaunchd = CFSTR("kSMDomainUserLaunchd");

SHIM_EXPORT Boolean SMJobSubmit(CFStringRef domain, CFDictionaryRef job, AuthorizationRef auth, CFErrorRef *outError) {
    (void)domain;
    (void)job;
    (void)auth;
    if (outError) *outError = NULL;
    SHIM_LOG("STUB SMJobSubmit -> false");
    return false;
}

SHIM_EXPORT Boolean SMJobRemove(CFStringRef domain, CFStringRef jobLabel, AuthorizationRef auth, Boolean wait, CFErrorRef *outError) {
    (void)domain;
    (void)jobLabel;
    (void)auth;
    (void)wait;
    if (outError) *outError = NULL;
    SHIM_LOG("STUB SMJobRemove -> false");
    return false;
}

// MARK: CoreServices (LaunchServices / FileManager / SharedFileList) stubs

// Darwin pthreads are preemptively scheduled. The legacy task ID is opaque.
typedef struct OpaqueMPTaskID *MPTaskID;

SHIM_EXPORT MPTaskID MPCurrentTaskID(void) {
    return (MPTaskID)pthread_self();
}

SHIM_EXPORT Boolean MPTaskIsPreemptive(MPTaskID task) {
    return task != NULL;
}

SHIM_EXPORT CFStringRef const kLSSharedFileListSessionLoginItems = CFSTR("kLSSharedFileListSessionLoginItems");

SHIM_EXPORT OSStatus FSPathCopyObjectSync(const char *path, void *ref, CFStringRef *outName) {
    (void)path;
    (void)ref;
    if (outName) *outName = NULL;
    return -43; // fnfErr
}

SHIM_EXPORT OSStatus FSPathMakeRef(const UInt8 *path, void *ref, Boolean *isDirectory) {
    if (!path || !ref) return -50;
    struct stat st;
    if (stat((const char *)path, &st) != 0) {
        if (isDirectory) *isDirectory = false;
        return -43;
    }
    if (isDirectory) *isDirectory = S_ISDIR(st.st_mode);
    memset(ref, 0, 80);
    strncpy((char *)ref, (const char *)path, 79);
    return 0;
}

SHIM_EXPORT OSStatus FSRefMakePath(const void *ref, UInt8 *path, UInt32 maxPathSize) {
    if (!ref || !path || maxPathSize == 0) return -50;
    const char *s = (const char *)ref;
    if (!s[0]) return -43;
    strncpy((char *)path, s, maxPathSize - 1);
    path[maxPathSize - 1] = '\0';
    return 0;
}

SHIM_EXPORT NSString *NSFileTypeForHFSTypeCode(OSType hfsFileTypeCode) {
    (void)hfsFileTypeCode;
    return @"";
}

SHIM_EXPORT OSType NSHFSTypeCodeFromFileType(NSString *fileTypeString) {
    (void)fileTypeString;
    return 0;
}

SHIM_EXPORT OSStatus LSCopyKindStringForRef(const void *inFSRef, CFStringRef *outKindString) {
    (void)inFSRef;
    if (outKindString) *outKindString = CFSTR("Document");
    return 0;
}

SHIM_EXPORT CFArrayRef LSCopyAllRoleHandlersForContentType(CFStringRef inContentType, uint32_t inRolesMask) {
    (void)inContentType;
    (void)inRolesMask;
    return (__bridge_retained CFArrayRef)@[];
}

SHIM_EXPORT CFArrayRef LSCopyApplicationURLsForURL(CFURLRef inURL, uint32_t inRolesMask) {
    (void)inURL;
    (void)inRolesMask;
    return (__bridge_retained CFArrayRef)@[];
}

SHIM_EXPORT OSStatus LSOpenFromURLSpec(const void *inLaunchSpec, CFURLRef *outLaunchedURL) {
    (void)inLaunchSpec;
    if (outLaunchedURL) *outLaunchedURL = NULL;
    SHIM_LOG("STUB LSOpenFromURLSpec");
    return -10814; // kLSApplicationNotFoundErr
}

SHIM_EXPORT OSStatus LSRegisterURL(CFURLRef inURL, Boolean inUpdate) {
    (void)inURL;
    (void)inUpdate;
    return 0;
}

SHIM_EXPORT CFTypeRef LSSharedFileListCreate(CFAllocatorRef inAllocator, CFStringRef inListType, CFTypeRef listOptions) {
    (void)inAllocator;
    (void)inListType;
    (void)listOptions;
    return (__bridge_retained CFTypeRef)@"ShimSharedFileList";
}

SHIM_EXPORT CFArrayRef LSSharedFileListCopySnapshot(CFTypeRef inList, UInt32 *outSnapshotSeed) {
    (void)inList;
    if (outSnapshotSeed) *outSnapshotSeed = 1;
    return (__bridge_retained CFArrayRef)@[];
}

SHIM_EXPORT CFStringRef LSSharedFileListItemCopyDisplayName(CFTypeRef inItem) {
    (void)inItem;
    return CFSTR("");
}

SHIM_EXPORT CFURLRef LSSharedFileListItemCopyResolvedURL(CFTypeRef inItem, UInt32 inFlags, CFErrorRef *outError) {
    (void)inItem;
    (void)inFlags;
    if (outError) *outError = NULL;
    return NULL;
}

SHIM_EXPORT OSStatus LSSharedFileListItemRemove(CFTypeRef inList, CFTypeRef inItem) {
    (void)inList;
    (void)inItem;
    return 0;
}

// MARK: Foundation macOS-only classes (NSAppleEventManager, NSAppleScript, NSXMLDocument)

SHIM_EXPORT
@interface NSAppleEventManager : NSObject
+ (NSAppleEventManager *)sharedAppleEventManager;
- (void)setEventHandler:(id)handler andSelector:(SEL)handleEventSelector forEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID;
- (void)removeEventHandlerForEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID;
@end

@implementation NSAppleEventManager
MACSHIM_RESOLVE
+ (NSAppleEventManager *)sharedAppleEventManager {
    static NSAppleEventManager *mgr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [NSAppleEventManager new]; });
    return mgr;
}
- (void)setEventHandler:(id)handler andSelector:(SEL)handleEventSelector forEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {
    (void)handler; (void)handleEventSelector; (void)eventClass; (void)eventID;
}
- (void)removeEventHandlerForEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {
    (void)eventClass; (void)eventID;
}
@end

SHIM_EXPORT
@interface NSAppleScript : NSObject
- (instancetype)initWithSource:(NSString *)source;
- (BOOL)compileAndReturnError:(NSDictionary **)errorInfo;
- (id)executeAndReturnError:(NSDictionary **)errorInfo;
@end

@implementation NSAppleScript
MACSHIM_RESOLVE
- (instancetype)initWithSource:(NSString *)source { (void)source; return [super init]; }
- (BOOL)compileAndReturnError:(NSDictionary **)errorInfo { (void)errorInfo; return NO; }
- (id)executeAndReturnError:(NSDictionary **)errorInfo { (void)errorInfo; return nil; }
@end

SHIM_EXPORT
@interface NSXMLDocument : NSObject
@end

@implementation NSXMLDocument
MACSHIM_RESOLVE
@end

// MARK: SystemConfiguration & IOKit macOS-only stubs

SHIM_EXPORT CFStringRef SCDynamicStoreCopyConsoleUser(CFTypeRef store, uid_t *uid, gid_t *gid) {
    (void)store;
    if (uid) *uid = 501;
    if (gid) *gid = 20;
    return CFSTR("mobile");
}

SHIM_EXPORT int IOPMCopyAssertionsByProcess(CFDictionaryRef *assertionsByProcess) {
    if (assertionsByProcess) *assertionsByProcess = NULL;
    return 0;
}

// MARK: Foundation NSScriptComparisonMethods (macOS NSObject category)

@implementation NSObject (ShimMacComparison)
- (BOOL)isEqualTo:(id)object { return [self isEqual:object]; }
- (BOOL)isNotEqualTo:(id)object { return ![self isEqual:object]; }
- (BOOL)isLessThan:(id)object {
    return [self respondsToSelector:@selector(compare:)] &&
           [(id)self compare:object] == NSOrderedAscending;
}
- (BOOL)isLessThanOrEqualTo:(id)object {
    if ([self isEqual:object]) return YES;
    return [self isLessThan:object];
}
- (BOOL)isGreaterThan:(id)object {
    return [self respondsToSelector:@selector(compare:)] &&
           [(id)self compare:object] == NSOrderedDescending;
}
- (BOOL)isGreaterThanOrEqualTo:(id)object {
    if ([self isEqual:object]) return YES;
    return [self isGreaterThan:object];
}
@end

// Security transforms and keychain import (macOS-only). Sparkle links them to verify downloaded updates; a Mac app's
// self-updater has nothing to update inside Triptych, so they fail cleanly with an error instead of being missing.
SHIM_EXPORT CFStringRef const kSecDigestSHA1 = CFSTR("SHA1");
SHIM_EXPORT CFStringRef const kSecTransformInputAttributeName = CFSTR("INPUT");
SHIM_EXPORT CFStringRef const kSecTransformOutputAttributeName = CFSTR("OUTPUT");
static void MacShimSecError(CFErrorRef *error) {
    if (error) *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, -4 /* errSecUnimplemented */, NULL);
}
SHIM_EXPORT CFTypeRef SecDigestTransformCreate(CFTypeRef type, CFIndex len, CFErrorRef *error) {
    SHIM_LOG("SecDigestTransformCreate: unsupported");
    MacShimSecError(error);
    return NULL;
}
SHIM_EXPORT CFTypeRef SecVerifyTransformCreate(CFTypeRef key, CFDataRef sig, CFErrorRef *error) {
    SHIM_LOG("SecVerifyTransformCreate: unsupported");
    MacShimSecError(error);
    return NULL;
}
SHIM_EXPORT CFTypeRef SecTransformCreateGroupTransform(void) { return NULL; }
SHIM_EXPORT CFTypeRef SecTransformCreateReadTransformWithReadStream(CFReadStreamRef stream) { return NULL; }
SHIM_EXPORT CFTypeRef SecTransformConnectTransforms(CFTypeRef src, CFStringRef srcName, CFTypeRef dst, CFStringRef dstName,
                                                    CFTypeRef group, CFErrorRef *error) {
    MacShimSecError(error);
    return NULL;
}
SHIM_EXPORT CFTypeRef SecTransformExecute(CFTypeRef transform, CFErrorRef *error) {
    MacShimSecError(error);
    return NULL;
}
SHIM_EXPORT OSStatus SecItemImport(CFDataRef data, CFStringRef fileNameOrExtension, void *inputFormat, void *itemType,
                                   uint32_t flags, const void *keyParams, void *importKeychain, CFArrayRef *outItems) {
    SHIM_LOG("SecItemImport: unsupported");
    if (outItems) *outItems = NULL;
    return -4; // errSecUnimplemented
}
SHIM_EXPORT OSStatus SecCodeCopyGuestWithAttributes(CFTypeRef host, CFDictionaryRef attributes, uint32_t flags, CFTypeRef *guest) {
    if (guest) *guest = NULL;
    return -67068; // errSecCSUnimplemented
}
