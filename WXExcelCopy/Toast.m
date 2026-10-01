// Toast.m — 轻量提示（悬浮 UILabel，1.5s 自动消失）

#import <UIKit/UIKit.h>
#import "Toast.h"

@implementation Toast

+ (void)show:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
        if (!keyWindow) return;

        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.layer.cornerRadius = 10;
        label.layer.masksToBounds = YES;

        CGFloat maxW = keyWindow.bounds.size.width - 60;
        CGSize sz = [text boundingRectWithSize:CGSizeMake(maxW, 200)
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{NSFontAttributeName: label.font}
                                       context:nil].size;
        label.frame = CGRectMake(0, 0, ceil(sz.width) + 28, ceil(sz.height) + 18);
        label.center = CGPointMake(keyWindow.center.x, keyWindow.bounds.size.height * 0.25);

        [keyWindow addSubview:label];
        label.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ label.alpha = 0; }
                             completion:^(BOOL f) { [label removeFromSuperview]; }];
        });
    });
}

@end
