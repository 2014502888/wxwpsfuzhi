// Tweak.m — 微信 xlsx 预览"点击单元格复制本列往下"插件入口
// 原理：hook 微信文件预览控制器 FileDetailWebPreviewController（WKWebView），
//       注入 JS 监听点击单元格 → 回调原生 → 解析沙盒 xlsx 全量数据 → 复制该列往下。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import "JSBridge.h"
#import "WebViewProbe.h"

#pragma mark - Runtime helpers

static void *kWXExcelInjectedKey = &kWXExcelInjectedKey;

// 深度遍历视图树找第一个 WKWebView
static WKWebView *FindWebViewInView(UIView *view, NSInteger depth) {
    if (depth > 12) return nil;
    if ([view isKindOfClass:[WKWebView class]]) {
        return (WKWebView *)view;
    }
    for (UIView *sub in view.subviews) {
        WKWebView *wv = FindWebViewInView(sub, depth + 1);
        if (wv) return wv;
    }
    return nil;
}

#pragma mark - Hook: FileDetailWebPreviewController

@interface FileDetailWebPreviewControllerHook : NSObject
@end

@implementation FileDetailWebPreviewControllerHook

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"FileDetailWebPreviewController");
        if (!cls) {
            // 兜底：微信新版本改名时尝试 FileDetailViewController
            cls = NSClassFromString(@"FileDetailViewController");
        }
        if (!cls) {
            NSLog(@"[WXExcelCopy] FileDetail preview controller not found");
            return;
        }

        // 1) viewDidLoad 后：主动找 webView 注入（尽早）
        SEL selDidLoad = NSSelectorFromString(@"viewDidLoad");
        Method mDidLoad = class_getInstanceMethod(cls, selDidLoad);
        if (mDidLoad) {
            IMP origDidLoad = method_getImplementation(mDidLoad);
            IMP newDidLoad = imp_implementationWithBlock(^(id self) {
                ((void(*)(id, SEL))origDidLoad)(self, selDidLoad);
                WKWebView *wv = FindWebViewInView([self valueForKey:@"view"], 0);
                if (wv) {
                    [JSBridge injectInto:wv];
                }
            });
            method_setImplementation(mDidLoad, newDidLoad);
        }

        // 2) webView:didFinishNavigation: 后：确保注入（加载完成最可靠）
        SEL selFinish = NSSelectorFromString(@"webView:didFinishNavigation:");
        Method mFinish = class_getInstanceMethod(cls, selFinish);
        if (mFinish) {
            IMP origFinish = method_getImplementation(mFinish);
            IMP newFinish = imp_implementationWithBlock(^(id self, WKWebView *wv, id nav) {
                ((void(*)(id, SEL, id, id))origFinish)(self, selFinish, wv, nav);
                [JSBridge injectInto:wv];
                // xlsx 预览页：抬头下方插入每列行数统计条
                NSString *u = wv.URL.absoluteString.lowercaseString ?: @"";
                if ([u containsString:@"xlsx"] || [u containsString:@"sheet"]) {
                    [JSBridge injectColumnStatsInto:wv];
                }
            });
            method_setImplementation(mFinish, newFinish);
        }

        NSLog(@"[WXExcelCopy] hook installed on %@", NSStringFromClass(cls));

        // 通用 WebView 探测（不依赖具体控制器类名）
        [WebViewProbe install];
    });
}

@end
