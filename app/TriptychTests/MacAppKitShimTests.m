// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@protocol ShimTestControl <NSObject>
@property (nonatomic, readonly) UIView *hostView;
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
- (instancetype)initWithFrame:(CGRect)frame;
- (instancetype)initWithCoder:(NSCoder *)coder;
@end

@protocol ShimTestMatrix <ShimTestControl>
@property (nonatomic, readonly) NSInteger selectedIndex;
@property (nonatomic, readonly) NSInteger selectedRow;
@property (nonatomic, readonly) NSInteger selectedColumn;
@property (nonatomic, readonly) NSInteger selectedTag;
- (void)selectCellAtRow:(NSInteger)row column:(NSInteger)column;
@end

@protocol ShimTestField <ShimTestControl>
@property (nonatomic, weak) id delegate;
@property (nonatomic, copy) NSString *stringValue;
@end

@protocol ShimTestWorkspace <NSObject>
- (BOOL)openURL:(NSURL *)url;
@end

@protocol ShimTestWindow <NSObject>
@property (nonatomic, readonly) UIView *chromeView;
@property (nonatomic, readonly) id attachedSheet;
@property (nonatomic, readonly) id sheetParent;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
@property (nonatomic, readonly, getter=isKeyWindow) BOOL keyWindow;
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)mask backing:(NSUInteger)backing defer:(BOOL)defer;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)beginSheet:(id)sheet completionHandler:(void (^)(NSInteger))handler;
- (void)endSheet:(id)sheet returnCode:(NSInteger)code;
- (void)close;
@end

@interface ShimTestCoder : NSCoder
@property (nonatomic, copy) NSDictionary<NSString *, id> *values;
@end

@implementation ShimTestCoder
- (BOOL)containsValueForKey:(NSString *)key { return self.values[key] != nil; }
- (id)decodeObjectForKey:(NSString *)key { return self.values[key]; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { return [self.values[key] integerValue]; }
- (int32_t)decodeInt32ForKey:(NSString *)key { return [self.values[key] intValue]; }
@end

@interface NSObject (ShimTestBindings)
- (void)bind:(NSString *)binding toObject:(id)observable withKeyPath:(NSString *)keyPath options:(NSDictionary *)options;
- (void)unbind:(NSString *)binding;
- (NSDictionary *)infoForBinding:(NSString *)binding;
@end

// valueForKey:@"enabled" hits the shim's nil stub for -enabled; ask isEnabled directly.
static BOOL ShimTestIsEnabled(id c) { return ((BOOL (*)(id, SEL))objc_msgSend)(c, @selector(isEnabled)); }

@interface ShimTestRegModel : NSObject
@property (nonatomic, copy) NSString *login;
@property (nonatomic, copy) NSString *password;
@property (nonatomic) BOOL busy;
@end
@implementation ShimTestRegModel
+ (NSSet *)keyPathsForValuesAffectingCanRegister { return [NSSet setWithObjects:@"login", @"password", nil]; }
- (BOOL)canRegister { return self.login.length > 0 && self.password.length > 0; }
@end

@interface MacAppKitShimTests : XCTestCase
@property (nonatomic, strong) id lastSender;
@property (nonatomic, strong) id<ShimTestWorkspace> workspace;
@property (nonatomic, copy) NSArray<NSNumber *> *urlResults;
@end

@implementation MacAppKitShimTests

static void *shimHandle;

- (void)setUp {
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libShim_AppKit.dylib"];
    if (!shimHandle) shimHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    const char *error = shimHandle ? NULL : dlerror();
    XCTAssertNotEqual(shimHandle, NULL, @"%s", error ?: "");
}

- (void)testSheetPresentationQueuesAndRestoresParent {
    void (*registerHost)(UIWindow *, UIViewController *, UIView *, NSString *) = dlsym(shimHandle, "ShimHostRegister");
    XCTAssertNotEqual(registerHost, NULL);
    if (!registerHost) return;
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 500, 600)];
    registerHost(nil, nil, host, nil);
    Class windowClass = NSClassFromString(@"NSWindow");
    CGRect rect = CGRectMake(0, 0, 320, 240);
    id<ShimTestWindow> parent = [[windowClass alloc] initWithContentRect:rect styleMask:1 backing:2 defer:NO];
    id<ShimTestWindow> first = [[windowClass alloc] initWithContentRect:rect styleMask:1 backing:2 defer:NO];
    id<ShimTestWindow> second = [[windowClass alloc] initWithContentRect:rect styleMask:1 backing:2 defer:NO];
    NSMutableArray<NSNumber *> *responses = [NSMutableArray new];
    [parent makeKeyAndOrderFront:nil];
    [parent beginSheet:first completionHandler:^(NSInteger code) { [responses addObject:@(code)]; }];
    [parent beginSheet:second completionHandler:^(NSInteger code) { [responses addObject:@(code)]; }];
    XCTAssertEqual(parent.attachedSheet, first);
    XCTAssertEqual(first.sheetParent, parent);
    XCTAssertTrue(first.isKeyWindow);
    XCTAssertFalse(second.isVisible);
    XCTAssertTrue(parent.chromeView.accessibilityElementsHidden);
    XCTAssertEqual(first.chromeView.superview.superview, host);
    XCTAssertEqual(first.chromeView.frame.size.width, 320);
    [parent endSheet:first returnCode:17];
    [parent endSheet:first returnCode:23];
    XCTAssertEqualObjects(responses, (@[@17]));
    XCTAssertFalse(first.isVisible);
    XCTAssertNil(first.sheetParent);
    XCTAssertEqual(parent.attachedSheet, second);
    XCTAssertTrue(second.isKeyWindow);
    [second close];
    XCTAssertEqualObjects(responses, (@[@17, @0]));
    XCTAssertNil(parent.attachedSheet);
    XCTAssertTrue(parent.isKeyWindow);
    XCTAssertFalse(parent.chromeView.accessibilityElementsHidden);
    [parent close];
    XCTAssertEqual(host.subviews.count, 0);
}

- (void)recordAction:(id)sender { self.lastSender = sender; }
- (void)controlTextDidChange:(NSNotification *)notification { self.lastSender = notification.object; }

- (void)testDecodedMatrixTracksSelectionAndSendsAction {
    Class cellClass = NSClassFromString(@"NSButtonCell");
    ShimTestCoder *cellCoder = [ShimTestCoder new];
    cellCoder.values = @{@"NSContents": @"First", @"NSTag": @42};
    id first = [[cellClass alloc] initWithCoder:cellCoder];
    cellCoder.values = @{@"NSContents": @"Second", @"NSTag": @71, @"NSCellFlags": @0x80000000};
    id second = [[cellClass alloc] initWithCoder:cellCoder];

    ShimTestCoder *coder = [ShimTestCoder new];
    coder.values = @{@"NSFrame": @"{{0, 0}, {200, 50}}", @"NSNumRows": @2, @"NSNumCols": @1,
                     @"NSCells": @[first, second], @"NSSelectedRow": @(-1), @"NSSelectedCol": @(-1)};
    id<ShimTestMatrix> matrix = [[NSClassFromString(@"NSMatrix") alloc] initWithCoder:coder];
    XCTAssertEqual(matrix.selectedIndex, 1);
    XCTAssertEqual(matrix.selectedRow, 1);
    XCTAssertEqual(matrix.selectedColumn, 0);
    XCTAssertEqual(matrix.selectedTag, 71);
    [matrix selectCellAtRow:2 column:0];
    XCTAssertEqual(matrix.selectedIndex, 1);

    matrix.target = self;
    matrix.action = @selector(recordAction:);
    UIStackView *grid = (UIStackView *)matrix.hostView.subviews.firstObject;
    UIStackView *row = (UIStackView *)grid.arrangedSubviews.firstObject;
    UIButton *button = (UIButton *)row.arrangedSubviews.firstObject;
    XCTAssertNotNil(button);
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqual(matrix.selectedIndex, 0);
    XCTAssertEqual(matrix.selectedTag, 42);
    XCTAssertTrue(button.accessibilityTraits & UIAccessibilityTraitSelected, "chosen radio is marked selected");
    XCTAssertEqual(self.lastSender, matrix);
}

- (void)testDecodedSecureFieldWiresDelegateAndMasksUIKitInput {
    ShimTestCoder *coder = [ShimTestCoder new];
    coder.values = @{@"NSCellFlags": @0x10400000};
    id cell = [[NSClassFromString(@"NSSecureTextFieldCell") alloc] initWithCoder:coder];
    coder.values = @{@"NSFrame": @"{{0, 0}, {200, 30}}", @"NSCell": cell};
    id<ShimTestField> field = [[NSClassFromString(@"NSSecureTextField") alloc] initWithCoder:coder];
    [(id)field setValue:self forKey:@"delegate"];
    XCTAssertEqual(field.delegate, self);
    UITextField *editor = (UITextField *)field.hostView.subviews.lastObject;
    XCTAssertTrue([editor isKindOfClass:UITextField.class]);
    XCTAssertTrue(editor.secureTextEntry);
    editor.text = @"synthetic input";
    [editor sendActionsForControlEvents:UIControlEventEditingChanged];
    XCTAssertEqualObjects(field.stringValue, @"synthetic input");
    XCTAssertEqual(self.lastSender, field);
}

- (void)testDecodedFieldsAnswerUIKitEditingQuestions {
    // On device, a tap asks the delegate textFieldShouldBeginEditing: and each keystroke asks
    // textField:shouldChangeCharactersInRange:...; nil stubs read as NO and blocked all typing.
    for (NSString *name in @[@"NSTextField", @"NSSecureTextField"]) {
        ShimTestCoder *coder = [ShimTestCoder new];
        coder.values = @{@"NSCellFlags": @0x10400000};
        id cell = [[NSClassFromString([name stringByAppendingString:@"Cell"]) alloc] initWithCoder:coder];
        coder.values = @{@"NSFrame": @"{{0, 0}, {200, 30}}", @"NSCell": cell};
        id<ShimTestField> field = [[NSClassFromString(name) alloc] initWithCoder:coder];
        UITextField *editor = (UITextField *)field.hostView.subviews.lastObject;
        XCTAssertTrue([editor isKindOfClass:UITextField.class], @"%@", name);
        id<UITextFieldDelegate> d = editor.delegate;
        XCTAssertNotNil(d, @"%@", name);
        XCTAssertTrue([d textFieldShouldBeginEditing:editor], @"%@ must allow editing", name);
        XCTAssertTrue([d textField:editor shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:@"a"], @"%@ must take keys", name);
        XCTAssertTrue([d textFieldShouldEndEditing:editor], @"%@", name);
        XCTAssertFalse([(id)d respondsToSelector:NSSelectorFromString(@"textField:shimUnknownQuestion:")], @"%@ unknown questions get UIKit defaults", name);
    }
}

- (void)testBindingsWriteBackAndCombineEnabledFamily {
    // CrossOver's registration sheet (device log 2026-11-24): login/password fields bound with
    // NSContinuouslyUpdatesValue=0, Unlock bound enabled=!busy and enabled2=canRegister.
    ShimTestRegModel *m = [ShimTestRegModel new];
    ShimTestCoder *coder = [ShimTestCoder new];
    coder.values = @{@"NSCellFlags": @0x10400000};
    id cell = [[NSClassFromString(@"NSTextFieldCell") alloc] initWithCoder:coder];
    coder.values = @{@"NSFrame": @"{{0, 0}, {200, 30}}", @"NSCell": cell};
    id<ShimTestField> login = [[NSClassFromString(@"NSTextField") alloc] initWithCoder:coder];
    id<ShimTestField> password = [[NSClassFromString(@"NSTextField") alloc] initWithCoder:coder];
    id button = [[NSClassFromString(@"NSButton") alloc] initWithFrame:CGRectMake(0, 0, 80, 30)];
    NSDictionary *noContinuous = @{@"NSContinuouslyUpdatesValue": @NO};
    [(id)login bind:@"value" toObject:m withKeyPath:@"login" options:noContinuous];
    [(id)password bind:@"value" toObject:m withKeyPath:@"password" options:noContinuous];
    [button bind:@"enabled" toObject:m withKeyPath:@"busy" options:@{@"NSValueTransformerName": @"NSNegateBoolean"}];
    [button bind:@"enabled2" toObject:m withKeyPath:@"canRegister" options:@{@"NSNullPlaceholder": @"-1"}];
    XCTAssertFalse(ShimTestIsEnabled(button), @"empty form: Unlock disabled");

    for (id<ShimTestField> f in @[login, password]) {
        UITextField *editor = (UITextField *)f.hostView.subviews.lastObject;
        editor.text = @"synthetic";
        [editor sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    XCTAssertEqualObjects(m.login, @"synthetic", @"typed text reaches the model");
    XCTAssertEqualObjects(m.password, @"synthetic");
    XCTAssertTrue(ShimTestIsEnabled(button), @"enabled AND enabled2 follow the model");
    m.busy = YES;
    XCTAssertFalse(ShimTestIsEnabled(button), @"model changes reach the view");
    m.login = @"changed";
    XCTAssertEqualObjects(login.stringValue, @"changed");

    NSDictionary *info = [(id)login infoForBinding:@"value"];
    XCTAssertEqual(info[@"NSObservedObjectKey"], m);
    XCTAssertEqualObjects(info[@"NSObservedKeyPathKey"], @"login");
    [(id)login unbind:@"value"];
    XCTAssertNil([(id)login infoForBinding:@"value"]);
}

- (void)openSyntheticURLs:(id)sender {
    self.urlResults = @[@([self.workspace openURL:[NSURL URLWithString:@"https://example.invalid/"]]),
                        @([self.workspace openURL:[NSURL URLWithString:@"http://example.invalid/"]]),
                        @([self.workspace openURL:[NSURL URLWithString:@"file:///tmp/example"]]),
                        @([self.workspace openURL:[NSURL URLWithString:@"https://user@example.invalid/"]])];
}

- (void)testWorkspaceHandsOffOnlyUserInitiatedWebURLs {
    self.workspace = [NSClassFromString(@"NSWorkspace") new];
    NSMutableArray<NSURL *> *urls = [NSMutableArray new];
    Method canOpen = class_getInstanceMethod(UIApplication.class, @selector(canOpenURL:));
    Method open = class_getInstanceMethod(UIApplication.class, @selector(openURL:options:completionHandler:));
    IMP canOpenStub = imp_implementationWithBlock(^BOOL(UIApplication *application, NSURL *url) { return YES; });
    IMP openStub = imp_implementationWithBlock(^(UIApplication *application, NSURL *url, NSDictionary *options,
                                                void (^completion)(BOOL)) { [urls addObject:url]; });
    IMP originalCanOpen = method_setImplementation(canOpen, canOpenStub);
    IMP originalOpen = method_setImplementation(open, openStub);
    @try {
        XCTAssertFalse([self.workspace openURL:[NSURL URLWithString:@"https://example.invalid/"]]);
        id<ShimTestControl> control = [[NSClassFromString(@"NSButton") alloc] initWithFrame:CGRectMake(0, 0, 120, 30)];
        control.target = self;
        control.action = @selector(openSyntheticURLs:);
        UIButton *button = (UIButton *)control.hostView.subviews.firstObject;
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        XCTAssertEqualObjects(self.urlResults, (@[@YES, @YES, @NO, @NO]));
        XCTAssertEqualObjects([urls valueForKey:@"scheme"], (@[@"https", @"http"]));
    } @finally {
        method_setImplementation(open, originalOpen);
        method_setImplementation(canOpen, originalCanOpen);
        imp_removeBlock(openStub);
        imp_removeBlock(canOpenStub);
    }
}

@end
