// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>
#include <stdio.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    fprintf(stderr, "MacAppHost: didFinishLaunchingWithOptions\n");
    fflush(stderr);
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                              options:(UISceneConnectionOptions *)options {
    (void)application;
    (void)options;
    UISceneConfiguration *cfg = [UISceneConfiguration configurationWithName:@"Default Configuration"
                                                               sessionRole:connectingSceneSession.role];
    if (!cfg.sceneClass) cfg.sceneClass = [UIWindowScene class];
    if (!cfg.delegateClass) cfg.delegateClass = NSClassFromString(@"SceneDelegate");
    fprintf(stderr, "MacAppHost: sceneConfig sceneClass=%s delegateClass=%s\n",
            NSStringFromClass(cfg.sceneClass).UTF8String ?: "(nil)",
            NSStringFromClass(cfg.delegateClass).UTF8String ?: "(nil)");
    fflush(stderr);
    return cfg;
}

@end
