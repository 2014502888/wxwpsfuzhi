// JSBridge.h
#import <Foundation/Foundation.h>
@class WKWebView;

@interface JSBridge : NSObject
+ (void)injectInto:(WKWebView *)webView;
// 预览页抬头下方插入每列行数统计条（作为页面内容一部分，不悬浮）
+ (void)injectColumnStatsInto:(WKWebView *)webView;
@end
