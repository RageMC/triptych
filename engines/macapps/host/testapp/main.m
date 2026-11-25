// SPDX-License-Identifier: GPL-3.0-or-later
// Tiny macOS arm64 AppKit + Metal test app (built against MacOSX.sdk only).
// Creates an NSWindow with an NSButton and a CAMetalLayer Metal triangle view,
// logging mouseDown events and button clicks to stderr.

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <math.h>
#include <stdio.h>

static NSString *const kEmbeddedMSL =
    @"#include <metal_stdlib>\n"
    @"using namespace metal;\n"
    @"struct VertexOut { float4 position [[position]]; float3 color; };\n"
    @"vertex VertexOut triangle_vertex(uint vid [[vertex_id]], constant float &angle [[buffer(0)]]) {\n"
    @"    const float2 pos[3] = { float2(0.00, 0.65), float2(-0.65, -0.55), float2(0.65, -0.55) };\n"
    @"    const float3 col[3] = { float3(1.0, 0.25, 0.30), float3(0.20, 0.95, 0.45), float3(0.25, 0.55, 1.0) };\n"
    @"    float c = cos(angle); float s = sin(angle); float2 p = pos[vid];\n"
    @"    VertexOut out;\n"
    @"    out.position = float4(p.x * c - p.y * s, p.x * s + p.y * c, 0.0, 1.0);\n"
    @"    out.color = col[vid];\n"
    @"    return out;\n"
    @"}\n"
    @"fragment float4 triangle_fragment(VertexOut in [[stage_in]], constant float &hue [[buffer(0)]]) {\n"
    @"    return float4(in.color.zxy * hue + in.color * (1.0 - hue), 1.0);\n"
    @"}\n";

@interface TriangleMetalView : NSView
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, assign) float hue;
@property (nonatomic, assign) float angle;
@property (nonatomic, assign) CGSize lastDrawableSize;
@end

@implementation TriangleMetalView

- (id<MTLRenderPipelineState>)buildPipelineFromLibrary:(id<MTLLibrary>)lib error:(NSError **)errOut {
    if (!lib) return nil;
    id<MTLFunction> vfn = [lib newFunctionWithName:@"triangle_vertex"];
    id<MTLFunction> ffn = [lib newFunctionWithName:@"triangle_fragment"];
    if (!vfn || !ffn) return nil;
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    return [_device newRenderPipelineStateWithDescriptor:desc error:errOut];
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    _hue = 0.0f;
    _angle = 0.0f;

    CAMetalLayer *metalLayer = [CAMetalLayer layer];
    metalLayer.device = _device;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.framebufferOnly = YES;
    self.wantsLayer = YES;
    self.layer = metalLayer;

    NSError *err = nil;
    NSString *metallibPath = [[NSBundle mainBundle] pathForResource:@"testapp" ofType:@"metallib"];
    if (metallibPath) {
        id<MTLLibrary> lib = [_device newLibraryWithURL:[NSURL fileURLWithPath:metallibPath] error:&err];
        _pipeline = [self buildPipelineFromLibrary:lib error:&err];
        if (_pipeline) {
            fprintf(stderr, "TestMacApp: loaded precompiled metallib %s\n", metallibPath.UTF8String);
        } else {
            fprintf(stderr, "TestMacApp: precompiled metallib unusable (%s), falling back to runtime MSL\n",
                    err ? err.localizedDescription.UTF8String : "unknown");
        }
    }
    if (!_pipeline) {
        err = nil;
        id<MTLLibrary> srcLib = [_device newLibraryWithSource:kEmbeddedMSL options:nil error:&err];
        _pipeline = [self buildPipelineFromLibrary:srcLib error:&err];
        fprintf(stderr, "TestMacApp: runtime MSL pipeline -> %s%s\n",
                _pipeline ? "OK" : "FAILED ",
                _pipeline ? "" : (err ? err.localizedDescription.UTF8String : "unknown"));
    }
    fflush(stderr);
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)cycleHue {
    _hue = fmodf(_hue + 0.25f, 1.0f);
    [self drawFrame];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    _hue = fmodf(_hue + 0.25f, 1.0f);
    fprintf(stderr, "TestMacApp mouseDown at (%.1f, %.1f) hue=%.2f\n", pt.x, pt.y, _hue);
    fflush(stderr);
    [self drawFrame];
}

- (void)drawFrame {
    if (!_pipeline) return;
    CGSize boundsSize = self.bounds.size;
    if (boundsSize.width < 1.0 || boundsSize.height < 1.0) return;

    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window ? self.window.backingScaleFactor : 2.0;
    if (scale < 1.0) scale = 2.0;
    CGSize targetSize = CGSizeMake(floor(boundsSize.width * scale), floor(boundsSize.height * scale));
    if (!CGSizeEqualToSize(_lastDrawableSize, targetSize)) {
        layer.drawableSize = targetSize;
        layer.contentsScale = scale;
        _lastDrawableSize = targetSize;
    }

    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;

    _angle = fmodf(_angle + 0.015f, (float)(M_PI * 2.0));

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.08, 0.10, 0.15, 1.0);

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:&_angle length:sizeof(float) atIndex:0];
    [enc setFragmentBytes:&_hue length:sizeof(float) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

@end

@interface TestAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) TriangleMetalView *triangleView;
@property (nonatomic, strong) NSButton *button;
@property (nonatomic, assign) NSInteger clickCount;
@property (nonatomic, strong) NSTimer *renderTimer;
@end

@implementation TestAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    fprintf(stderr, "TestMacApp applicationDidFinishLaunching\n");
    fflush(stderr);

    NSRect visible = [NSScreen mainScreen].visibleFrame;
    CGFloat w = visible.size.width > 0 ? MIN(400.0, visible.size.width) : 400.0;
    CGFloat h = visible.size.height > 0 ? MIN(640.0, visible.size.height) : 640.0;
    NSRect contentRect = NSMakeRect(0, 0, w, h);

    _window = [[NSWindow alloc] initWithContentRect:contentRect
                                          styleMask:NSWindowStyleMaskTitled |
                                                    NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"TestMacApp";
    _window.backgroundColor = [NSColor colorWithRed:0.08 green:0.10 blue:0.15 alpha:1.0];

    NSView *content = _window.contentView;
    NSRect b = content.bounds;

    CGFloat btnHeight = 48.0;
    CGFloat btnBottom = 24.0;
    CGFloat metalBottom = btnBottom + btnHeight + 16.0;
    NSRect metalFrame = NSMakeRect(16.0, metalBottom, MAX(100.0, b.size.width - 32.0), MAX(120.0, b.size.height - metalBottom - 16.0));
    _triangleView = [[TriangleMetalView alloc] initWithFrame:metalFrame];
    _triangleView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_triangleView];

    _button = [NSButton buttonWithTitle:@"Click Me (0)" target:self action:@selector(buttonClicked:)];
    _button.frame = NSMakeRect(24.0, btnBottom, MAX(120.0, b.size.width - 48.0), btnHeight);
    _button.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:_button];

    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [_triangleView drawFrame];

    __weak typeof(self) weakSelf = self;
    _renderTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0) repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf.triangleView drawFrame];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_renderTimer forMode:NSRunLoopCommonModes];
}

- (void)buttonClicked:(id)sender {
    (void)sender;
    _clickCount++;
    _button.title = [NSString stringWithFormat:@"Click Me (%ld)", (long)_clickCount];
    [_triangleView cycleHue];
    fprintf(stderr, "TestMacApp buttonClicked count=%ld\n", (long)_clickCount);
    fflush(stderr);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stderr, "TestMacApp main() entered (argc=%d)\n", argc);
        fflush(stderr);
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        TestAppDelegate *delegate = [TestAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
