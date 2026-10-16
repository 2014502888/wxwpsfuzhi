// WebViewProbe.m — 通用 WKWebView 加载探测：任何 WebView 加载都注入 JS
// （不依赖微信具体控制器类名；不再弹任何探测窗）

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "WebViewProbe.h"
#import "JSBridge.h"

@implementation WebViewProbe

static BOOL gInstalled;

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;

    Class wk = [WKWebView class];

    // -[WKWebView loadRequest:]
    SEL s1 = @selector(loadRequest:);
    Method m1 = class_getInstanceMethod(wk, s1);
    if (m1) {
        IMP o1 = method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(^id(id self, NSURLRequest *req) {
            id r = ((id(*)(id, SEL, NSURLRequest *))o1)(self, s1, req);
            [WebViewProbe onLoad:self url:req.URL];
            return r;
        }));
    }

    // -[WKWebView loadHTMLString:baseURL:]
    SEL s2 = @selector(loadHTMLString:baseURL:);
    Method m2 = class_getInstanceMethod(wk, s2);
    if (m2) {
        IMP o2 = method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^id(id self, NSString *html, NSURL *base) {
            id r = ((id(*)(id, SEL, NSString *, NSURL *))o2)(self, s2, html, base);
            [WebViewProbe onLoad:self url:base];
            return r;
        }));
    }

    // -[WKWebView loadFileURL:allowingReadAccessToURL:]
    SEL s3 = @selector(loadFileURL:allowingReadAccessToURL:);
    Method m3 = class_getInstanceMethod(wk, s3);
    if (m3) {
        IMP o3 = method_getImplementation(m3);
        method_setImplementation(m3, imp_implementationWithBlock(^id(id self, NSURL *file, NSURL *read) {
            id r = ((id(*)(id, SEL, NSURL *, NSURL *))o3)(self, s3, file, read);
            [WebViewProbe onLoad:self url:file];
            return r;
        }));
    }

    NSLog(@"[WXExcelCopy] WebViewProbe installed");
}

+ (void)onLoad:(WKWebView *)wv url:(NSURL *)url {
    if (!wv) return;
    // 2026-10-16 方案1：只对 xlsx/xls 文件预览 WebView 注入；微信其它 WebView
    // （聊天网页/公众号/小程序/其它文档预览）完全放行——不挂 message handler、
    // 不加 user script，零干预。
    // 原因：此前 hook 微信所有 WebView 并注入，微信整体变重；打开超大 xlsx
    // （如 sheet1.xml 解压 126MB）时，微信 WPS 渲染本就接近单进程内存上限，
    // 插件对每个 WebView 的附加操作把微信推到 per-process-limit（4.06GB）被
    // Jetsam 杀掉（bug_type 298 / reason per-process-limit）。实测卸载插件不闪退、
    // 装上闪退，差异就在这份全局干预。
    // 过滤口径与 JS 侧主 frame URL 校验一致：主 frame file://xxx.xlsx 或 .xls
    // 才注入；多 sheet 表格所在 iframe（x-apple-ql-id://）属 WebKit 内部导航，
    // 不经 load 方法，不受影响。
    NSString *low = (url.absoluteString ?: @"").lowercaseString;
    if ([low containsString:@".xlsx"] || [low containsString:@".xls"]) {
        [JSBridge injectInto:wv];
    }
}

@end
