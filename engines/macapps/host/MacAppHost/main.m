// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>
#include <stdio.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        fprintf(stderr, "MacAppHost: entering main()\n");
        fflush(stderr);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
