// JSBridge.h
#import <Foundation/Foundation.h>
@class WKWebView;
@class UIViewController;

@interface JSBridge : NSObject
+ (void)injectInto:(WKWebView *)webView;
+ (UIViewController *)topVC;
@end
