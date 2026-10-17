// JSBridge.h
#import <Foundation/Foundation.h>
@class WKWebView;

@interface JSBridge : NSObject
+ (void)injectInto:(WKWebView *)webView;
// didFinishNavigation 补注入：补挂消息 handler + 当前 document 直接运行点击脚本
+ (void)ensureInjected:(WKWebView *)webView;
// 判断是否为超大 sheet：file URL 且 xl/worksheets/*.xml 解压体积最大值 > 8MB
+ (BOOL)isBigFile:(WKWebView *)webView;
// 解析候选顺序：匹配文件优先（预览副本前缀 → OpenData 完整文件），其余按时间（原生统计栏用）
- (NSArray<NSString *> *)orderedCandidates:(NSString *)previewURL;
@end
