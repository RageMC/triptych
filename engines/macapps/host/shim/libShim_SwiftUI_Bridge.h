#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSColor : NSObject
@property (nonatomic, strong, readonly) UIColor *uiColor;
- (instancetype)initWithUIColor:(UIColor *)c;
@end

@interface NSImage : NSObject
@property (nonatomic, strong, readonly, nullable) UIImage *uiImage;
- (instancetype)initWithUIImage:(nullable UIImage *)img;
@end

@interface NSResponder : NSObject
@end

@interface NSView : NSResponder
@property (nonatomic) CGRect frame;
@property (nonatomic, readonly) UIView *hostView;
- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(NSView *)v;
- (void)removeFromSuperview;
@end

@interface NSViewController : NSResponder
@property (nonatomic, strong) NSView *view;
- (void)loadView;
@end

NS_ASSUME_NONNULL_END
