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
@property (nonatomic) BOOL shifted;           // 表格让位是否已执行
@property (nonatomic) BOOL filled;            // 统计栏内容是否已填充
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
    // 文件解析完（数据就绪）直接创建并显示统计栏——不再等表格渲染完成。
    // 表格让位（shiftTable）：loading==NO 后执行，此时 table 必在、让位必然生效
    // （代价是表格内容已渲染才被推、有一次移动视觉；但 A/B 列完整露出不被遮挡）。
    // 统计栏内容随让位脚本命中 table 填充（与表格数据渲染基本同时出现）。
    // 绝不能用 KVO 监听 webView.loading（预览页中途被微信释放 → observer 未移除 → 崩）；
    // 也绝不能用递归 block + dispatch_after（自引用 block 复制有 use-after-free 风险，
    // 实测 _dispatch_Block_copy EXC_BREAKPOINT 崩）。NSTimer+selector 完全避开这两类问题。
    [self prepareBar];
    [self startPolling];
}

// 创建统计栏 UI 并直接显示 + 挂滚动跟随
- (void)prepareBar {
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

    self.scroll = scroll;
    self.bar = bar;
    // 壳先就位：只显示统计栏区域（内容由 fillContent 在让位脚本命中 table 时填充，
    // 与表格数据渲染基本同时出现——避免壳+内容+表格+让位四个视觉差）
    [self.webView addSubview:bar];
    [self.webView bringSubviewToFront:bar];

    // 跟随表格纵向滚动（KVO webView 内部 scrollView 的 contentOffset）
    UIScrollView *sv = self.webView.scrollView;
    if (sv && !self.observing) {
        [sv addObserver:self forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:nil];
        self.observing = YES;
    }
    [self updateOffset];
}

// 填充统计栏内容（列字母/数量/表头）——在页面完全加载（loading==NO）、
// 表格数据开始渲染时调用，统计栏内容与表格数据同时出现
- (void)fillContent {
    if (!self.webView || !self.scroll || self.filled) return;
    self.filled = YES;
    UIScrollView *scroll = self.scroll;
    CGFloat barW = scroll.bounds.size.width;
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
}

// 启动轮询 timer（0.3s 一次）——只负责等 loading==NO 后让位
- (void)startPolling {
    [self stopPolling];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                      target:self
                                                    selector:@selector(pollTick)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)pollTick {
    if (!self.webView) { [self stopPolling]; return; }
    // 页面完全加载（loading==NO）后执行让位——table 必在，让位必然生效；
    // 统计栏内容随让位脚本命中 table 填充（与表格数据渲染基本同时出现）
    if (!self.webView.loading) {
        [self shiftTable];
        [self stopPolling];
    }
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"contentOffset"]) {
        [self updateOffset];
    }
}

// 滚动跟随（KVO webView 内部 scrollView 的 contentOffset）
- (void)updateOffset {
    if (!self.webView || !self.bar) return;
    CGFloat y = -self.webView.scrollView.contentOffset.y;
    self.bar.transform = CGAffineTransformMakeTranslation(0, y);
}

// 表格让位：把预览表格向右推 70px（统计栏宽 68px），A/B 列完整露出不被遮挡。
// 仅执行一次样式调整，不做任何监听/处理逻辑、不挂 handler、有限重试(50×100ms=5s)后
// 自动结束，无常驻脚本——大文件临界状态下开销可忽略。在 loading==NO 后执行（此时
// table 必在、让位必然生效）；重试 100ms 兜底微信二次渲染/虚拟滚动重建表格的时机。
// JS 返回 table 是否命中 → 原生据此填充统计栏内容（与表格数据渲染基本同时出现）。
- (void)shiftTable {
    if (!self.webView || self.shifted) return;
    self.shifted = YES;
    __weak typeof(self) ws = self;
    NSString *shift = @"(function(){"
        "var tries=0;"
        "function go(){"
        "  var t=document.querySelector('table');"
        "  if(t){t.style.marginLeft='70px';return true;}"
        "  if(++tries<50){setTimeout(go,100);return null;}"
        "  return false;"
        "}"
        "return go();"
        "})();";
    [self.webView evaluateJavaScript:shift completionHandler:^(id result, NSError *error) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        // 无论表格 DOM 是否命中都填充统计栏内容（命中=与表格数据同时；超时=5s兜底照填）
        dispatch_async(dispatch_get_main_queue(), ^{
            [s fillContent];
        });
    }];
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
