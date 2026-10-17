// XlsxNativeBar.h — 大文件（解压 >8MB）原生统计栏：
// 微信 WPS 渲染超大 xlsx 时 CPU+内存双临界，任何 JS 注入都可能触发 watchdog 被杀，
// 因此大文件彻底零注入；统计栏改用 iOS 原生 UIView 叠加在预览 WKWebView 上，
// 用系统字体显示（列字母/数量/表头，天然不乱码），点击走原生流式 columnLinesAtPath 复制。

#import <UIKit/UIKit.h>
@class WKWebView;

@interface XlsxNativeBar : NSObject
// 在预览 webView 上叠加原生统计栏（大文件专用；内部后台匹配文件 + 流式统计 + 读表头）
+ (void)showForWebView:(WKWebView *)webView url:(NSURL *)url;
@end
