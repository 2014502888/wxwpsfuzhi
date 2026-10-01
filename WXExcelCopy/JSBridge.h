// JSBridge.h
#import <Foundation/Foundation.h>
@class WKWebView;

@interface JSBridge : NSObject
+ (void)injectInto:(WKWebView *)webView;
// didFinishNavigation 补注入：补挂消息 handler + 当前 document 直接运行点击脚本
+ (void)ensureInjected:(WKWebView *)webView;
// 注入列标行（A/B/C）+ 行号列（表头=1），类似 WPS 表格
+ (void)injectRowColHeaderInto:(WKWebView *)webView;
// 预览页抬头下方插入每列行数统计条（作为页面内容一部分，不悬浮；列项可点击复制整列）
+ (void)injectColumnStatsInto:(WKWebView *)webView url:(NSString *)url;
@end
