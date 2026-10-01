// JSBridge.h
#import <Foundation/Foundation.h>
@class WKWebView;

@interface JSBridge : NSObject
+ (void)injectInto:(WKWebView *)webView;
@end
