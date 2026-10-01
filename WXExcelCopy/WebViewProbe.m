// WebViewProbe.m — 通用 WKWebView 加载探测：任何 WebView 加载都注入 JS，
// 命中 xlsx/spreadsheet/preview/file 关键词才弹窗（不依赖微信具体控制器类名）

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "WebViewProbe.h"
#import "JSBridge.h"

@implementation WebViewProbe

static NSMutableSet *gSeenURLs;
static BOOL gInstalled;

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;
    gSeenURLs = [NSMutableSet set];

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
    NSString *s = url.absoluteString ?: @"";
    NSString *lower = s.lowercaseString;
    BOOL hit = [lower containsString:@"xlsx"] ||
               [lower containsString:@"spreadsheet"] ||
               [lower containsString:@"sheet"] ||
               [lower containsString:@"preview"] ||
               [lower containsString:@"file"];

    // 所有 WebView 都注入 JS（点击复制逻辑本身无害）
    [JSBridge injectInto:wv];

    if (!hit) return;
    if ([gSeenURLs containsObject:s]) return;
    [gSeenURLs addObject:s];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [JSBridge topVC];
        if (!top) return;
        NSString *delegateCls = wv.navigationDelegate ? NSStringFromClass([wv.navigationDelegate class]) : @"nil";
        NSString *msg = [NSString stringWithFormat:@"WebView 加载命中:\n%@\n\ndelegate: %@\nURL 已复制到剪贴板", s, delegateCls];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"WXExcelCopy 探测"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"复制 URL" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = s;
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

@end
