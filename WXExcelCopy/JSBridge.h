// JSBridge.h
#import <Foundation/Foundation.h>
@class WKWebView;

@interface JSBridge : NSObject
+ (void)injectInto:(WKWebView *)webView;
// didFinishNavigation 补注入：补挂消息 handler + 当前 document 直接运行点击脚本
+ (void)ensureInjected:(WKWebView *)webView;
@end
