// XlsxNativeBar.m — 大文件原生统计栏（见 .h 说明）
#import "XlsxNativeBar.h"
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "JSBridge.h"
#import "XLSXParser.h"
#import "Toast.h"

@interface XlsxNativeBar ()
@property (nonatomic, weak) WKWebView *webView;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) JSBridge *bridge;
@property (nonatomic, strong) NSString *filePath;
@property (nonatomic) NSInteger sheetIndex;
@property (nonatomic, strong) NSArray<NSNumber *> *counts;
@property (nonatomic, strong) NSArray<NSString *> *headers;
@property (nonatomic) BOOL observing;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic) NSInteger stableSame;   // contentSize 连续相同采样次数
@property (nonatomic) CGFloat lastHeight;     // 上次采样 contentSize.height
@property (nonatomic) NSInteger stableTotal;  // 总采样次数（超时兜底）
@end

@implementation XlsxNativeBar

static const char *kNativeBarKey = "wxExcelNativeBarKey";

+ (void)showForWebView:(WKWebView *)webView url:(NSURL *)url {
    if (!webView) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        XlsxNativeBar *bar = [[XlsxNativeBar alloc] init];
        bar.webView = webView;
        bar.bridge = [[JSBridge alloc] init];

        // 1) 匹配文件：预览副本（前截断）前缀 → OpenData 完整文件（JSBridge 现成逻辑）
        NSArray<NSString *> *ordered = [bar.bridge orderedCandidates:url.absoluteString ?: @""];
        if (ordered.count == 0) return;
        NSString *path = ordered[0];

        // 2) 找第一个有数据的 sheet（表头非空；轻量解析只读前 2 行）
        NSInteger sidx = 1;
        for (NSInteger idx = 1; idx <= 64; idx++) {
            NSError *e = nil;
            NSDictionary *rows = [XLSXParser parseSheetAtPath:path sheetIndex:idx maxRows:2 error:&e];
            if (!rows) { if (e && e.code == 2) break; continue; }
            NSDictionary *h = rows[@(1)];
            if (h && h.count > 0) { sidx = idx; break; }
        }

        // 3) 流式统计每列非空数（含表头）+ 表头行
        NSError *e2 = nil;
        NSArray<NSNumber *> *counts = [XLSXParser countColumnsAtPath:path sheetIndex:sidx error:&e2];
        if (!counts || counts.count == 0) return;
        NSDictionary *headRows = [XLSXParser parseSheetAtPath:path sheetIndex:sidx maxRows:1 error:nil];
        NSDictionary *hrow = headRows[@(1)];
        NSMutableArray<NSString *> *headers = [NSMutableArray array];
        for (NSInteger c = 1; c <= (NSInteger)counts.count; c++) {
            [headers addObject:(hrow[@(c)] ?: @"")];
        }

        bar.filePath = path;
        bar.sheetIndex = sidx;
        bar.counts = counts;
        bar.headers = headers;

        dispatch_async(dispatch_get_main_queue(), ^{
            // 替换旧 bar（同一 webView 重复 show 时旧实例释放并移除旧 bar）
            XlsxNativeBar *old = objc_getAssociatedObject(webView, kNativeBarKey);
            if (old && old != bar) { [old detach]; }
            objc_setAssociatedObject(webView, kNativeBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [bar buildBar];
        });
    });
}

- (void)buildBar {
    if (!self.webView) return;
    // 大表渲染慢：统计栏要贴着表格内容出现。loading==NO 只代表 HTML 框架加载完，
    // 126MB 表格数据还在渲染（scrollView.contentSize 持续增长）——统一用一个 NSTimer
    // 轮询：等 loading 完成 且 contentSize 连续 4 次采样不再增长（渲染稳定）才叠 bar。
    // 绝不能用 KVO 监听 webView.loading（预览页中途被微信释放 → observer 未移除 → 崩）；
    // 也绝不能用递归 block + dispatch_after（自引用 block 复制有 use-after-free 风险，
    // 实测 _dispatch_Block_copy EXC_BREAKPOINT 崩）。NSTimer+selector 完全避开这两类问题。
    [self startPolling];
}

// 启动轮询 timer（0.3s 一次）
- (void)startPolling {
    [self stopPolling];
    self.stableSame = 0;
    self.lastHeight = 0;
    self.stableTotal = 0;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                      target:self
                                                    selector:@selector(pollTick)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)pollTick {
    if (!self.webView) { [self stopPolling]; return; }
    // 还在加载：不采样（contentSize 可能为 0，避免误判稳定），等下一次
    if (self.webView.loading) { return; }
    CGFloat h = self.webView.scrollView.contentSize.height;
    if (h == self.lastHeight) { self.stableSame++; }
    else { self.stableSame = 1; self.lastHeight = h; }
    self.stableTotal++;
    // 连续 4 次（约 1.2s）contentSize 不再增长 = 渲染稳定；或 100 次（30s）超时强制叠
    if (self.stableSame >= 4 || self.stableTotal >= 100) {
        [self stopPolling];
        [self doBuildBar];
    }
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)doBuildBar {
    if (!self.webView) return;
    [self.bar removeFromSuperview];
    self.bar = nil;
    self.scroll = nil;

    CGFloat barW = 68;
    CGRect f = CGRectMake(0, 0, barW, MAX(100, self.webView.bounds.size.height));
    UIView *bar = [[UIView alloc] initWithFrame:f];
    bar.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.97];
    bar.layer.shadowColor = UIColor.blackColor.CGColor;
    bar.layer.shadowOpacity = 0.25;
    bar.layer.shadowOffset = CGSizeMake(1, 0);
    bar.layer.shadowRadius = 3;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:bar.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    scroll.showsVerticalScrollIndicator = NO;
    [bar addSubview:scroll];

    NSInteger n = (NSInteger)self.counts.count;
    CGFloat itemH = 46;
    scroll.contentSize = CGSizeMake(barW, MAX(itemH * (CGFloat)n, scroll.bounds.size.height));

    for (NSInteger c = 0; c < n; c++) {
        NSInteger col = c + 1;
        CGFloat y = (CGFloat)c * itemH;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, y, barW, itemH);
        btn.backgroundColor = UIColor.clearColor;
        btn.tag = col;
        [btn addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(2, 2, barW - 4, 15)];
        l1.text = [XLSXParser columnLetter:col];
        l1.font = [UIFont boldSystemFontOfSize:11];
        l1.textAlignment = NSTextAlignmentCenter;
        l1.textColor = [UIColor colorWithWhite:0.13 alpha:1];
        l1.adjustsFontSizeToFitWidth = YES;
        l1.minimumScaleFactor = 0.5;
        [btn addSubview:l1];

        UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(2, 18, barW - 4, 14)];
        NSNumber *cnt = (col - 1 < (NSInteger)self.counts.count) ? self.counts[(NSUInteger)(col - 1)] : nil;
        l2.text = cnt ? [NSString stringWithFormat:@"%@", cnt] : @"0";
        l2.font = [UIFont systemFontOfSize:11];
        l2.textAlignment = NSTextAlignmentCenter;
        l2.textColor = [UIColor colorWithWhite:0.13 alpha:1];
        l2.adjustsFontSizeToFitWidth = YES;
        l2.minimumScaleFactor = 0.5;
        [btn addSubview:l2];

        UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(2, 32, barW - 4, 12)];
        NSString *h = (col - 1 < (NSInteger)self.headers.count) ? self.headers[(NSUInteger)(col - 1)] : @"";
        l3.text = h.length > 4 ? [h substringToIndex:4] : h;
        l3.font = [UIFont systemFontOfSize:10];
        l3.textAlignment = NSTextAlignmentCenter;
        l3.textColor = UIColor.grayColor;
        l3.adjustsFontSizeToFitWidth = YES;
        l3.minimumScaleFactor = 0.5;
        [btn addSubview:l3];

        [scroll addSubview:btn];
    }

    self.scroll = scroll;
    self.bar = bar;
    [self.webView addSubview:bar];
    [self.webView bringSubviewToFront:bar];

    // 跟随表格纵向滚动（KVO webView 内部 scrollView 的 contentOffset）
    UIScrollView *sv = self.webView.scrollView;
    if (sv && !self.observing) {
        [sv addObserver:self forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:nil];
        self.observing = YES;
    }
    [self updateOffset];

    // 表格让位：一次性把预览表格向右推 70px（统计栏宽 68px），A/B 列完整露出不被遮挡。
    // 仅执行一次样式调整，不做任何监听/处理逻辑、不挂 handler、有限重试(30×500ms=15s)后
    // 自动结束，无常驻脚本——大文件临界状态下开销可忽略。此时表格 DOM 通常已存在（loading==NO
    // 后才走到这里），重试只是兜底微信二次渲染/虚拟滚动重建表格的时机。
    NSString *shift = @"(function(){"
        "var tries=0;"
        "function go(){"
        "  var t=document.querySelector('table');"
        "  if(t){t.style.marginLeft='70px';return;}"
        "  if(++tries<30){setTimeout(go,500);}"
        "}"
        "go();"
        "})();";
    [self.webView evaluateJavaScript:shift completionHandler:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"contentOffset"]) {
        [self updateOffset];
    }
}

- (void)updateOffset {
    if (!self.webView || !self.bar) return;
    CGFloat y = -self.webView.scrollView.contentOffset.y;
    self.bar.transform = CGAffineTransformMakeTranslation(0, y);
}

// 点击列条目 → 原生流式提取该列 → 剪贴板（columnLinesAtPath 内存单列，大文件安全）
- (void)tap:(UIButton *)btn {
    NSInteger col = btn.tag;
    NSString *path = self.filePath;
    NSInteger sidx = self.sheetIndex;
    if (!path) { [Toast show:@"复制失败：文件不可用"]; return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *e = nil;
        NSArray<NSString *> *lines = [XLSXParser columnLinesAtPath:path column:col fromRow:1 sheetIndex:sidx error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!lines) { [Toast show:@"复制失败：解析异常"]; return; }
            if (lines.count == 0) { [Toast show:@"复制失败：该列无数据"]; return; }
            [UIPasteboard generalPasteboard].string = [lines componentsJoinedByString:@"\n"];
            [Toast show:[NSString stringWithFormat:@"✓ %@ sheet%ld 复制%@列共%lu条(含表头)",
                         path.lastPathComponent, (long)sidx,
                         [XLSXParser columnLetter:col], (unsigned long)lines.count]];
        });
    });
}

// 释放/替换时移除 KVO observer、停 timer、移除 bar
- (void)detach {
    [self stopPolling];
    if (self.observing && self.webView.scrollView) {
        @try {
            [self.webView.scrollView removeObserver:self forKeyPath:@"contentOffset"];
        } @catch (NSException *e) {}
        self.observing = NO;
    }
    [self.bar removeFromSuperview];
    self.bar = nil;
}

- (void)dealloc {
    [self detach];
}

@end
