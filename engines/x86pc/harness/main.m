// Minimal headless iOS harness for the x86pc engine (STATUS 4b, step c).
// UIScene lifecycle. Starts libqemu-x86_64-softmmu.dylib (utmapp/qemu shared-lib build) on a worker thread the way
// QEMU's own system/main.c does (qemu_init, then qemu_main_loop + qemu_cleanup), with -display none. The guest screen
// is pulled through the human monitor ("screendump" over TCP 127.0.0.1:<port>) and shown in a UIImageView, so a
// `simctl io screenshot` shows the guest inside the iOS app.
// Launch args (after `--` in simctl launch): QEMU argv; "@DOC" is replaced by the app's Documents path, "@RES" by
// the bundle's resource path.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

extern void qemu_init(int argc, char **argv);
extern int qemu_main_loop(void);
extern void qemu_cleanup(int);

static int g_argc; static char **g_argv; static int g_monport = 44444;

static void *qemu_thread(void *unused) {
    qemu_init(g_argc, g_argv);          // returns with the BQL held, which qemu_main_loop expects
    int status = qemu_main_loop();
    qemu_cleanup(status);
    NSLog(@"x86pc: qemu exited %d", status);
    return NULL;
}

static void start_qemu(void) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *res = NSBundle.mainBundle.resourcePath;
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSMutableArray<NSString *> *q = [NSMutableArray arrayWithObject:@"qemu-system-x86_64"];
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"--"]) continue;                                   // simctl launch passes it through
        if ([a hasPrefix:@"-NS"] || [a hasPrefix:@"-Apple"]) { i++; continue; }   // UIKit's own defaults args
        a = [[a stringByReplacingOccurrencesOfString:@"@DOC" withString:doc]
                 stringByReplacingOccurrencesOfString:@"@RES" withString:res];
        NSRange r = [a rangeOfString:@"tcp:127.0.0.1:"];
        if (r.location != NSNotFound && i > 1 && [args[i-1] isEqualToString:@"-monitor"])
            g_monport = [[a substringFromIndex:NSMaxRange(r)] intValue];
        [q addObject:a];
    }
    g_argc = (int)q.count; g_argv = calloc(g_argc + 1, sizeof(char *));
    for (int i = 0; i < g_argc; i++) g_argv[i] = strdup(q[i].UTF8String);
    NSLog(@"x86pc: argv %@", [q componentsJoinedByString:@" "]);
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 8 << 20);
    pthread_t t; pthread_create(&t, &at, qemu_thread, NULL);
}

static UIImage *load_ppm(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d.length < 16) return nil;
    const uint8_t *p = d.bytes, *e = p + d.length; int f[3] = {0}, n = 0;
    if (p[0] != 'P' || p[1] != '6') return nil; p += 2;
    while (n < 3 && p < e) {
        while (p < e && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) p++;
        if (p < e && *p == '#') { while (p < e && *p != '\n') p++; continue; }
        int v = 0; while (p < e && *p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0'); f[n++] = v;
    }
    p++; int w = f[0], h = f[1];
    if (w <= 0 || h <= 0 || p + (size_t)w * h * 3 > e) return nil;
    NSMutableData *rgba = [NSMutableData dataWithLength:(size_t)w * h * 4]; uint8_t *o = rgba.mutableBytes;
    for (size_t i = 0; i < (size_t)w * h; i++) { o[4*i] = p[3*i]; o[4*i+1] = p[3*i+1]; o[4*i+2] = p[3*i+2]; o[4*i+3] = 255; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGImageAlphaNoneSkipLast, dp, NULL, false, kCGRenderingIntentDefault);
    UIImage *u = [UIImage imageWithCGImage:img];
    CGImageRelease(img); CGDataProviderRelease(dp); CGColorSpaceRelease(cs);
    return u;
}

static BOOL monitor_cmd(int port, NSString *cmd) {
    int s = socket(AF_INET, SOCK_STREAM, 0); if (s < 0) return NO;
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    struct timeval tv = { .tv_sec = 2 }; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return NO; }
    char buf[512]; recv(s, buf, sizeof buf, 0);                       // banner + prompt
    NSString *line = [cmd stringByAppendingString:@"\n"];
    send(s, line.UTF8String, strlen(line.UTF8String), 0);
    usleep(400000); recv(s, buf, sizeof buf, 0); close(s);
    return YES;
}

@interface ViewController : UIViewController
@property UIImageView *screen; @property UILabel *status; @property NSDate *t0;
@end
@implementation ViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.screen = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.screen.contentMode = UIViewContentModeScaleAspectFit;
    self.screen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.screen.layer.magnificationFilter = kCAFilterNearest;
    [self.view addSubview:self.screen];
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, self.view.bounds.size.width - 16, 40)];
    self.status.textColor = UIColor.greenColor; self.status.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.status.numberOfLines = 2; self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.status];
    self.t0 = [NSDate date];
    start_qemu();
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [self refresh]; }];
}
- (void)refresh {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *ppm = [doc stringByAppendingPathComponent:@"screen.ppm"];
    int port = g_monport; NSTimeInterval el = -self.t0.timeIntervalSinceNow;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = monitor_cmd(port, [NSString stringWithFormat:@"screendump %@", ppm]);
        UIImage *img = ok ? load_ppm(ppm) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (img) self.screen.image = img;
            self.status.text = [NSString stringWithFormat:@"Triptych x86pc (QEMU TCG, iOS Simulator)  %.0fs%@", el,
                                img ? [NSString stringWithFormat:@"  %.0fx%.0f", img.size.width, img.size.height] : @"  waiting for monitor"];
        });
    });
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ViewController new];
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s
                              options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = SceneDelegate.class; return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
