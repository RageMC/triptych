// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>
#include <stdio.h>

@interface HostViewController : UIViewController
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    (void)session;
    (void)options;
    fprintf(stderr, "MacAppHost: scene:willConnectToSession: (%s)\n",
            NSStringFromClass([scene class]).UTF8String);
    fflush(stderr);
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [HostViewController new];
    [self.window makeKeyAndVisible];
    fprintf(stderr, "MacAppHost: window key=%d frame={{%.0f,%.0f},{%.0f,%.0f}}\n",
            self.window.isKeyWindow,
            self.window.frame.origin.x, self.window.frame.origin.y,
            self.window.frame.size.width, self.window.frame.size.height);
    fflush(stderr);
}

@end
