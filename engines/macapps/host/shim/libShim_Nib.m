#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <string.h>

@interface NSImage : NSObject
+ (instancetype)imageNamed:(NSString *)name;
- (instancetype)initWithSize:(CGSize)size;
@end

@interface NSColor : NSObject
+ (instancetype)colorWithUIColor:(UIColor *)c;
@end

@interface NSFont : NSObject
+ (NSFont *)systemFontOfSize:(CGFloat)size;
@end

@interface NSView : NSObject
- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(NSView *)v;
@end

@interface NSWindow : NSObject
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSView *contentView;
- (void)makeKeyAndOrderFront:(id)sender;
@end

@interface NSMenuItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) SEL action;
@property (nonatomic, weak) id target;
@property (nonatomic, strong) id submenu;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic) NSInteger tag;
@end

@interface NSMenu : NSObject
@property (nonatomic, copy) NSString *title;
- (void)addItem:(NSMenuItem *)item;
@end

typedef NS_ENUM(uint8_t, ShimNibValType) {
    ShimNibValInt8 = 0,
    ShimNibValInt16 = 1,
    ShimNibValInt32 = 2,
    ShimNibValInt64 = 3,
    ShimNibValTrue = 4,
    ShimNibValFalse = 5,
    ShimNibValFloat = 6,
    ShimNibValDouble = 7,
    ShimNibValBytes = 8,
    ShimNibValNil = 9,
    ShimNibValObjectRef = 10,
};

typedef struct {
    uint32_t keyIdx;
    uint8_t type;
    int64_t intVal;
    double dblVal;
    uint32_t objRef;
    uint32_t bytesOffset;
    uint32_t bytesLen;
} ShimNibValue;

typedef struct {
    uint32_t classIdx;
    uint32_t valStart;
    uint32_t valCount;
} ShimNibObject;

static BOOL ShimReadVarint(const uint8_t *buf, size_t len, size_t *pos, uint32_t *out) {
    uint32_t res = 0;
    uint32_t shift = 0;
    while (*pos < len && shift <= 28) {
        uint8_t b = buf[(*pos)++];
        res |= (uint32_t)(b & 0x7f) << shift;
        if (b & 0x80) {
            *out = res;
            return YES;
        }
        shift += 7;
    }
    return NO;
}

@interface ShimNibArchive : NSObject {
@public
    NSData *_rawData;
    NSMutableArray<NSString *> *_classes;
    NSMutableArray<NSString *> *_keys;
    ShimNibObject *_objs;
    uint32_t _objCount;
    ShimNibValue *_vals;
    uint32_t _valCount;
}
+ (instancetype)archiveWithData:(NSData *)data;
- (int32_t)findValueIndexForObject:(uint32_t)objIdx key:(NSString *)key;
- (NSString *)stringForObject:(uint32_t)objIdx key:(NSString *)key;
@end

@implementation ShimNibArchive

+ (instancetype)archiveWithData:(NSData *)data {
    if (data.length < 50) return nil;
    const uint8_t *b = (const uint8_t *)data.bytes;
    if (memcmp(b, "NIBArchive", 10) != 0) return nil;

    uint32_t hdr[10];
    memcpy(hdr, b + 10, sizeof(hdr));
    uint32_t nObjs = hdr[2], offObjs = hdr[3];
    uint32_t nKeys = hdr[4], offKeys = hdr[5];
    uint32_t nVals = hdr[6], offVals = hdr[7];
    uint32_t nCls = hdr[8], offCls = hdr[9];
    size_t len = data.length;

    ShimNibArchive *ar = [self new];
    ar->_rawData = data;
    ar->_classes = [NSMutableArray arrayWithCapacity:nCls];
    ar->_keys = [NSMutableArray arrayWithCapacity:nKeys];
    ar->_objCount = nObjs;
    ar->_objs = calloc(nObjs ?: 1, sizeof(ShimNibObject));
    ar->_valCount = nVals;
    ar->_vals = calloc(nVals ?: 1, sizeof(ShimNibValue));

    size_t p = offCls;
    for (uint32_t i = 0; i < nCls; i++) {
        uint32_t clen = 0, extra = 0, skip = 0;
        if (!ShimReadVarint(b, len, &p, &clen) || !ShimReadVarint(b, len, &p, &extra)) return nil;
        for (uint32_t e = 0; e < extra; e++) {
            if (!ShimReadVarint(b, len, &p, &skip)) return nil;
        }
        if (p + clen > len) return nil;
        size_t slen = clen;
        while (slen > 0 && b[p + slen - 1] == '\0') slen--;
        NSString *cname = [[NSString alloc] initWithBytes:b + p length:slen encoding:NSUTF8StringEncoding] ?: @"NSObject";
        [ar->_classes addObject:cname];
        p += clen;
    }

    p = offKeys;
    for (uint32_t i = 0; i < nKeys; i++) {
        uint32_t klen = 0;
        if (!ShimReadVarint(b, len, &p, &klen) || p + klen > len) return nil;
        NSString *kname = [[NSString alloc] initWithBytes:b + p length:klen encoding:NSUTF8StringEncoding] ?: @"";
        [ar->_keys addObject:kname];
        p += klen;
    }

    p = offObjs;
    for (uint32_t i = 0; i < nObjs; i++) {
        if (!ShimReadVarint(b, len, &p, &ar->_objs[i].classIdx) ||
            !ShimReadVarint(b, len, &p, &ar->_objs[i].valStart) ||
            !ShimReadVarint(b, len, &p, &ar->_objs[i].valCount)) {
            return nil;
        }
    }

    p = offVals;
    for (uint32_t i = 0; i < nVals; i++) {
        uint32_t kidx = 0;
        if (!ShimReadVarint(b, len, &p, &kidx) || p >= len) return nil;
        uint8_t vtype = b[p++];
        ShimNibValue *v = &ar->_vals[i];
        v->keyIdx = kidx;
        v->type = vtype;
        switch (vtype) {
            case ShimNibValInt8:
                if (p + 1 > len) return nil;
                v->intVal = (int8_t)b[p];
                p += 1;
                break;
            case ShimNibValInt16: {
                if (p + 2 > len) return nil;
                int16_t s;
                memcpy(&s, b + p, 2);
                v->intVal = s;
                p += 2;
                break;
            }
            case ShimNibValInt32: {
                if (p + 4 > len) return nil;
                int32_t s;
                memcpy(&s, b + p, 4);
                v->intVal = s;
                p += 4;
                break;
            }
            case ShimNibValInt64: {
                if (p + 8 > len) return nil;
                int64_t s;
                memcpy(&s, b + p, 8);
                v->intVal = s;
                p += 8;
                break;
            }
            case ShimNibValTrue:
                v->intVal = 1;
                break;
            case ShimNibValFalse:
            case ShimNibValNil:
                v->intVal = 0;
                break;
            case ShimNibValFloat: {
                if (p + 4 > len) return nil;
                float f;
                memcpy(&f, b + p, 4);
                v->dblVal = f;
                p += 4;
                break;
            }
            case ShimNibValDouble: {
                if (p + 8 > len) return nil;
                double d;
                memcpy(&d, b + p, 8);
                v->dblVal = d;
                p += 8;
                break;
            }
            case ShimNibValBytes: {
                uint32_t blen = 0;
                if (!ShimReadVarint(b, len, &p, &blen) || p + blen > len) return nil;
                v->bytesOffset = (uint32_t)p;
                v->bytesLen = blen;
                p += blen;
                break;
            }
            case ShimNibValObjectRef: {
                if (p + 4 > len) return nil;
                uint32_t oidx = 0;
                memcpy(&oidx, b + p, 4);
                v->objRef = oidx;
                p += 4;
                break;
            }
            default:
                return nil;
        }
    }
    return ar;
}

- (void)dealloc {
    free(_objs);
    free(_vals);
}

- (int32_t)findValueIndexForObject:(uint32_t)objIdx key:(NSString *)key {
    if (objIdx >= _objCount) return -1;
    ShimNibObject obj = _objs[objIdx];
    for (uint32_t i = 0; i < obj.valCount; i++) {
        uint32_t vi = obj.valStart + i;
        if (vi >= _valCount) break;
        uint32_t ki = _vals[vi].keyIdx;
        if (ki < _keys.count && [_keys[ki] isEqualToString:key]) {
            return (int32_t)vi;
        }
    }
    return -1;
}

- (NSString *)stringForObject:(uint32_t)objIdx key:(NSString *)key {
    int32_t vi = [self findValueIndexForObject:objIdx key:key];
    if (vi < 0) return nil;
    ShimNibValue v = _vals[vi];
    if (v.type == ShimNibValBytes) {
        return [[NSString alloc] initWithBytes:(const uint8_t *)_rawData.bytes + v.bytesOffset
                                        length:v.bytesLen
                                      encoding:NSUTF8StringEncoding];
    }
    return nil;
}

@end

@interface ShimNibConnector : NSObject
@property (nonatomic, strong) id source;
@property (nonatomic, strong) id destination;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) BOOL isControlAction;
@property (nonatomic) BOOL isBinding;
@property (nonatomic, copy) NSString *binding;
@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, copy) NSDictionary *options;
@end
@implementation ShimNibConnector
@end

@interface ShimNibUnarchiver : NSCoder {
@public
    ShimNibArchive *_archive;
    id _owner;
    NSMutableDictionary<NSNumber *, id> *_instantiated;
    NSMutableArray *_allObjects;
    uint32_t _currentObj;
    uint32_t _rootOwnerObjIdx;
    BOOL _hasRootOwnerIdx;
}
- (instancetype)initWithArchive:(ShimNibArchive *)archive owner:(id)owner;
- (id)decodeObjectAtIndex:(uint32_t)idx;
- (NSDictionary *)decodeRootAndWireOutlets:(NSArray **)outTopLevel;
@end

@implementation ShimNibUnarchiver

- (instancetype)initWithArchive:(ShimNibArchive *)archive owner:(id)owner {
    if ((self = [super init])) {
        _archive = archive;
        _owner = owner;
        _instantiated = [NSMutableDictionary new];
        _allObjects = [NSMutableArray new];
        if (archive->_objCount > 1) {
            int32_t rootRef = [archive findValueIndexForObject:1 key:@"NSRoot"];
            if (rootRef >= 0 && archive->_vals[rootRef].type == ShimNibValObjectRef) {
                _rootOwnerObjIdx = archive->_vals[rootRef].objRef;
                _hasRootOwnerIdx = YES;
            }
        }
    }
    return self;
}

- (BOOL)allowsKeyedCoding { return YES; }

- (BOOL)containsValueForKey:(NSString *)key {
    return [_archive findValueIndexForObject:_currentObj key:key] >= 0;
}

- (id)decodeObjectForKey:(NSString *)key {
    int32_t vi = [_archive findValueIndexForObject:_currentObj key:key];
    if (vi < 0) return nil;
    ShimNibValue v = _archive->_vals[vi];
    if (v.type == ShimNibValNil) return nil;
    if (v.type == ShimNibValObjectRef) return [self decodeObjectAtIndex:v.objRef];
    if (v.type == ShimNibValBytes) {
        return [_archive stringForObject:_currentObj key:key];
    }
    return nil;
}

- (BOOL)decodeBoolForKey:(NSString *)key {
    int32_t vi = [_archive findValueIndexForObject:_currentObj key:key];
    if (vi < 0) return NO;
    return _archive->_vals[vi].intVal != 0;
}

- (int)decodeIntForKey:(NSString *)key { return (int)[self decodeInt64ForKey:key]; }
- (int32_t)decodeInt32ForKey:(NSString *)key { return (int32_t)[self decodeInt64ForKey:key]; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { return (NSInteger)[self decodeInt64ForKey:key]; }

- (int64_t)decodeInt64ForKey:(NSString *)key {
    int32_t vi = [_archive findValueIndexForObject:_currentObj key:key];
    if (vi < 0) return 0;
    ShimNibValue v = _archive->_vals[vi];
    if (v.type == ShimNibValDouble || v.type == ShimNibValFloat) return (int64_t)v.dblVal;
    return v.intVal;
}

- (float)decodeFloatForKey:(NSString *)key { return (float)[self decodeDoubleForKey:key]; }

- (double)decodeDoubleForKey:(NSString *)key {
    int32_t vi = [_archive findValueIndexForObject:_currentObj key:key];
    if (vi < 0) return 0.0;
    ShimNibValue v = _archive->_vals[vi];
    if (v.type == ShimNibValDouble || v.type == ShimNibValFloat) return v.dblVal;
    return (double)v.intVal;
}

- (const uint8_t *)decodeBytesForKey:(NSString *)key returnedLength:(NSUInteger *)lengthp {
    int32_t vi = [_archive findValueIndexForObject:_currentObj key:key];
    if (vi < 0 || _archive->_vals[vi].type != ShimNibValBytes) {
        if (lengthp) *lengthp = 0;
        return NULL;
    }
    ShimNibValue v = _archive->_vals[vi];
    if (lengthp) *lengthp = v.bytesLen;
    return (const uint8_t *)_archive->_rawData.bytes + v.bytesOffset;
}

- (id)decodeObjectAtIndex:(uint32_t)idx {
    if (idx >= _archive->_objCount) return nil;
    id cached = _instantiated[@(idx)];
    if (cached) return (cached == NSNull.null) ? nil : cached;

    if (_hasRootOwnerIdx && idx == _rootOwnerObjIdx && _owner) {
        _instantiated[@(idx)] = _owner;
        return _owner;
    }

    uint32_t prevObj = _currentObj;
    _currentObj = idx;

    ShimNibObject meta = _archive->_objs[idx];
    NSString *clsName = (meta.classIdx < _archive->_classes.count)
        ? _archive->_classes[meta.classIdx]
        : @"NSObject";

    id result = nil;

    if ([clsName isEqualToString:@"NSString"] ||
        [clsName isEqualToString:@"NSMutableString"] ||
        [clsName isEqualToString:@"NSLocalizableString"]) {
        NSString *s = [_archive stringForObject:idx key:@"NS.bytes"] ?: @"";
        result = [clsName isEqualToString:@"NSMutableString"] ? [s mutableCopy] : s;
    } else if ([clsName isEqualToString:@"NSNumber"]) {
        if ([self containsValueForKey:@"NS.dblval"]) result = @([self decodeDoubleForKey:@"NS.dblval"]);
        else if ([self containsValueForKey:@"NS.boolval"]) result = @([self decodeBoolForKey:@"NS.boolval"]);
        else result = @([self decodeInt64ForKey:@"NS.intval"]);
    } else if ([clsName isEqualToString:@"NSArray"] ||
               [clsName isEqualToString:@"NSMutableArray"] ||
               [clsName isEqualToString:@"NSSet"] ||
               [clsName isEqualToString:@"NSMutableSet"]) {
        NSMutableArray *arr = [NSMutableArray new];
        for (uint32_t i = 0; i < meta.valCount; i++) {
            uint32_t vi = meta.valStart + i;
            if (vi >= _archive->_valCount) break;
            ShimNibValue v = _archive->_vals[vi];
            NSString *k = (v.keyIdx < _archive->_keys.count) ? _archive->_keys[v.keyIdx] : @"";
            if ([k isEqualToString:@"UINibEncoderEmptyKey"] && v.type == ShimNibValObjectRef) {
                id elem = [self decodeObjectAtIndex:v.objRef];
                [arr addObject:elem ?: NSNull.null];
            }
        }
        if ([clsName isEqualToString:@"NSMutableSet"]) result = [NSMutableSet setWithArray:arr];
        else if ([clsName isEqualToString:@"NSSet"]) result = [NSSet setWithArray:arr];
        else if ([clsName isEqualToString:@"NSMutableArray"]) result = arr;
        else result = [arr copy];
    } else if ([clsName isEqualToString:@"NSDictionary"] || [clsName isEqualToString:@"NSMutableDictionary"]) {
        NSMutableArray *items = [NSMutableArray new];
        for (uint32_t i = 0; i < meta.valCount; i++) {
            uint32_t vi = meta.valStart + i;
            if (vi >= _archive->_valCount) break;
            ShimNibValue v = _archive->_vals[vi];
            NSString *k = (v.keyIdx < _archive->_keys.count) ? _archive->_keys[v.keyIdx] : @"";
            if ([k isEqualToString:@"UINibEncoderEmptyKey"] && v.type == ShimNibValObjectRef) {
                id elem = [self decodeObjectAtIndex:v.objRef];
                [items addObject:elem ?: NSNull.null];
            }
        }
        NSMutableDictionary *dict = [NSMutableDictionary new];
        for (NSUInteger i = 0; i + 1 < items.count; i += 2) {
            id k = items[i], v = items[i + 1];
            if (k != NSNull.null && v != NSNull.null) dict[k] = v;
        }
        result = [clsName isEqualToString:@"NSMutableDictionary"] ? dict : [dict copy];
    } else if ([clsName isEqualToString:@"NSCustomObject"]) {
        NSString *customClsName = [self decodeObjectForKey:@"NSClassName"];
        if ([customClsName isEqualToString:@"NSApplication"]) {
            Class appCls = NSClassFromString(@"NSApplication");
            id shared = appCls && [appCls respondsToSelector:@selector(sharedApplication)]
                ? ((id (*)(id, SEL))objc_msgSend)(appCls, @selector(sharedApplication))
                : nil;
            if (shared) {
                result = shared;
            }
        }
        if (!result) {
            Class cls = customClsName.length ? NSClassFromString(customClsName) : nil;
            if (!cls && customClsName.length) {
                fprintf(stderr, "NSNib WARNING: missing custom class %s\n", customClsName.UTF8String);
                fflush(stderr);
            }
            result = cls ? [cls new] : [NSObject new];
        }
    } else if ([clsName isEqualToString:@"NSCustomView"] || [clsName isEqualToString:@"NSClassSwapper"]) {
        NSString *customClsName = [self decodeObjectForKey:@"NSClassName"];
        Class cls = customClsName.length ? NSClassFromString(customClsName) : [NSView class];
        if (!cls) cls = [NSView class];
        if ([cls instancesRespondToSelector:@selector(initWithCoder:)]) {
            result = [[cls alloc] initWithCoder:self];
        } else {
            NSString *frameStr = [self decodeObjectForKey:@"NSFrame"];
            CGRect r = frameStr.length ? CGRectFromString(frameStr) : CGRectMake(0, 0, 200, 100);
            result = [[cls alloc] initWithFrame:r];
        }
    } else if ([clsName isEqualToString:@"NSCustomResource"]) {
        NSString *rname = [self decodeObjectForKey:@"NSResourceName"];
        result = rname.length ? ([NSImage imageNamed:rname] ?: [[NSImage alloc] initWithSize:CGSizeMake(16, 16)]) : nil;
    } else if ([clsName isEqualToString:@"NSWindowTemplate"]) {
        NSString *wclsName = [self decodeObjectForKey:@"NSWindowClass"];
        Class wcls = wclsName.length ? NSClassFromString(wclsName) : [NSWindow class];
        if (!wcls) wcls = [NSWindow class];
        NSString *rectStr = [self decodeObjectForKey:@"NSWindowRect"];
        CGRect r = rectStr.length ? CGRectFromString(rectStr) : CGRectMake(0, 0, 480, 360);
        NSUInteger style = (NSUInteger)[self decodeIntegerForKey:@"NSWindowStyleMask"];
        NSWindow *w = [[wcls alloc] initWithContentRect:r styleMask:style backing:2 defer:NO];
        NSString *title = [self decodeObjectForKey:@"NSWindowTitle"];
        if (title) w.title = title;
        id cv = [self decodeObjectForKey:@"NSWindowView"];
        if (cv) w.contentView = cv;
        result = w;
    } else if ([clsName isEqualToString:@"NSNibOutletConnector"] ||
               [clsName isEqualToString:@"NSNibControlConnector"]) {
        ShimNibConnector *conn = [ShimNibConnector new];
        conn.source = [self decodeObjectForKey:@"NSSource"];
        conn.destination = [self decodeObjectForKey:@"NSDestination"];
        conn.label = [self decodeObjectForKey:@"NSLabel"];
        conn.isControlAction = [clsName isEqualToString:@"NSNibControlConnector"];
        result = conn;
    } else if ([clsName isEqualToString:@"NSNibBindingConnector"]) {
        ShimNibConnector *conn = [ShimNibConnector new];
        conn.source = [self decodeObjectForKey:@"NSSource"];
        conn.destination = [self decodeObjectForKey:@"NSDestination"];
        conn.label = [self decodeObjectForKey:@"NSLabel"];
        conn.isBinding = YES;
        conn.binding = [self decodeObjectForKey:@"NSBinding"];
        conn.keyPath = [self decodeObjectForKey:@"NSKeyPath"];
        id opts = [self decodeObjectForKey:@"NSOptions"];
        if ([opts isKindOfClass:NSDictionary.class]) conn.options = opts;
        result = conn;
    } else if ([clsName isEqualToString:@"NSColor"]) {
        result = [NSColor colorWithUIColor:UIColor.labelColor];
    } else if ([clsName isEqualToString:@"NSFont"]) {
        double sz = [self decodeDoubleForKey:@"NSSize"];
        result = [NSFont systemFontOfSize:(sz > 0 ? sz : 13.0)];
    } else if ([clsName isEqualToString:@"NSIBObjectData"]) {
        NSMutableDictionary *info = [NSMutableDictionary new];
        id root = [self decodeObjectForKey:@"NSRoot"];
        id vis = [self decodeObjectForKey:@"NSVisibleWindows"];
        id conns = [self decodeObjectForKey:@"NSConnections"];
        id keys = [self decodeObjectForKey:@"NSObjectsKeys"];
        id vals = [self decodeObjectForKey:@"NSObjectsValues"];
        if (root) info[@"root"] = root;
        if (vis) info[@"visibleWindows"] = vis;
        if (conns) info[@"connections"] = conns;
        if (keys) info[@"objectsKeys"] = keys;
        if (vals) info[@"objectsValues"] = vals;
        result = info;
    } else if ([clsName isEqualToString:@"NSUserDefaultsController"]) {
        Class udc = NSClassFromString(@"NSUserDefaultsController");
        result = udc ? ((id (*)(id, SEL))objc_msgSend)(udc, @selector(sharedUserDefaultsController)) : [NSObject new];
    } else if ([clsName isEqualToString:@"NSObject"]) {
        id objData = [self decodeObjectForKey:@"IB.objectdata"];
        result = objData ?: [NSObject new];
    } else {
        Class cls = NSClassFromString(clsName);
        if (cls && [cls instancesRespondToSelector:@selector(initWithCoder:)]) {
            result = [[cls alloc] initWithCoder:self];
        } else if (cls) {
            result = [cls new];
        } else {
            result = [NSObject new];
        }
    }

    _instantiated[@(idx)] = result ?: NSNull.null;
    if (result && ![clsName isEqualToString:@"NSIBObjectData"] &&
        ![clsName hasPrefix:@"NSNib"] && ![clsName isEqualToString:@"NSString"] &&
        ![clsName isEqualToString:@"NSMutableString"] && ![clsName isEqualToString:@"NSLocalizableString"] &&
        ![clsName isEqualToString:@"NSNumber"]) {
        [_allObjects addObject:result];
    }

    _currentObj = prevObj;
    return result;
}

- (NSDictionary *)decodeRootAndWireOutlets:(NSArray **)outTopLevel {
    id rootObj = [self decodeObjectAtIndex:0];
    NSDictionary *info = [rootObj isKindOfClass:NSDictionary.class] ? rootObj : nil;
    NSArray *conns = info[@"connections"];
    for (id item in conns) {
        if (![item isKindOfClass:ShimNibConnector.class]) continue;
        ShimNibConnector *c = item;
        if (c.isBinding || !c.source || !c.label.length) continue;
        if (c.isControlAction) {
            NSString *selName = c.label;
            if (![selName hasSuffix:@":"]) selName = [selName stringByAppendingString:@":"];
            SEL sel = NSSelectorFromString(selName);
            if ([c.source respondsToSelector:@selector(setTarget:)]) {
                @try {
                    [c.source setValue:c.destination forKey:@"target"];
                } @catch (NSException *ignored) {}
            }
            if ([c.source respondsToSelector:@selector(setAction:)]) {
                ((void (*)(id, SEL, SEL))objc_msgSend)(c.source, @selector(setAction:), sel);
            }
        } else if (c.destination) {
            @try {
                [c.source setValue:c.destination forKey:c.label];
            } @catch (NSException *ex) {
                fprintf(stderr, "NSNib outlet [%s setValue:%s forKey:%s] skipped: %s\n",
                        class_getName([c.source class]),
                        class_getName([c.destination class]),
                        c.label.UTF8String,
                        ex.reason.UTF8String ?: "KVC error");
                fflush(stderr);
            }
        }
    }
    for (id item in conns) {
        if (![item isKindOfClass:ShimNibConnector.class]) continue;
        ShimNibConnector *c = item;
        if (!c.isBinding || !c.source || !c.binding.length || !c.keyPath.length) continue;
        SEL bindSel = @selector(bind:toObject:withKeyPath:options:);
        if ([c.source respondsToSelector:bindSel]) {
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(
                c.source, bindSel, c.binding, c.destination, c.keyPath, c.options);
        }
    }

    for (id obj in _allObjects) {
        if ([obj respondsToSelector:@selector(awakeFromNib)]) {
            ((void (*)(id, SEL))objc_msgSend)(obj, @selector(awakeFromNib));
        }
    }
    if (_owner && [_owner respondsToSelector:@selector(awakeFromNib)]) {
        ((void (*)(id, SEL))objc_msgSend)(_owner, @selector(awakeFromNib));
    }

    NSSet *visWindows = info[@"visibleWindows"];
    if ([visWindows isKindOfClass:NSSet.class]) {
        for (id w in visWindows) {
            if ([w respondsToSelector:@selector(makeKeyAndOrderFront:)]) {
                [w makeKeyAndOrderFront:nil];
            }
        }
    }

    if (outTopLevel) {
        NSMutableArray *tops = [NSMutableArray new];
        NSArray *keys = info[@"objectsKeys"];
        NSArray *vals = info[@"objectsValues"];
        id root = info[@"root"];
        if ([keys isKindOfClass:NSArray.class] && [vals isKindOfClass:NSArray.class]) {
            NSUInteger cnt = MIN(keys.count, vals.count);
            for (NSUInteger i = 0; i < cnt; i++) {
                if (vals[i] == root && keys[i] != root && keys[i] != NSNull.null) {
                    [tops addObject:keys[i]];
                }
            }
        }
        *outTopLevel = [tops copy];
    }
    return info;
}

@end

__attribute__((visibility("default")))
@interface NSNib : NSObject
@property (nonatomic, copy) NSData *shimData;
@property (nonatomic, strong) NSBundle *shimBundle;
- (instancetype)initWithNibNamed:(NSString *)nibName bundle:(NSBundle *)bundle;
- (instancetype)initWithNibData:(NSData *)nibData bundle:(NSBundle *)bundle;
- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)topLevelObjects;
@end

@implementation NSNib

- (instancetype)initWithNibNamed:(NSString *)nibName bundle:(NSBundle *)bundle {
    NSBundle *b = bundle ?: NSBundle.mainBundle;
    NSString *path = [b pathForResource:nibName ofType:@"nib"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    return [self initWithNibData:data bundle:b];
}

- (instancetype)initWithNibData:(NSData *)nibData bundle:(NSBundle *)bundle {
    if (!nibData.length) return nil;
    if ((self = [super init])) {
        _shimData = [nibData copy];
        _shimBundle = bundle ?: NSBundle.mainBundle;
    }
    return self;
}

- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)topLevelObjects {
    ShimNibArchive *ar = [ShimNibArchive archiveWithData:_shimData];
    if (!ar) {
        fprintf(stderr, "NSNib ERROR: unsupported nib format (not NIBArchive)\n");
        fflush(stderr);
        return NO;
    }
    ShimNibUnarchiver *coder = [[ShimNibUnarchiver alloc] initWithArchive:ar owner:owner];
    NSDictionary *info = [coder decodeRootAndWireOutlets:topLevelObjects];
    return info != nil;
}

@end

@implementation NSBundle (ShimNibLoading)

- (BOOL)loadNibNamed:(NSString *)nibName owner:(id)owner topLevelObjects:(NSArray **)topLevelObjects {
    NSNib *nib = [[NSNib alloc] initWithNibNamed:nibName bundle:self];
    if (!nib) return NO;
    return [nib instantiateWithOwner:owner topLevelObjects:topLevelObjects];
}

+ (BOOL)loadNibNamed:(NSString *)nibName owner:(id)owner {
    return [NSBundle.mainBundle loadNibNamed:nibName owner:owner topLevelObjects:nil];
}

@end
