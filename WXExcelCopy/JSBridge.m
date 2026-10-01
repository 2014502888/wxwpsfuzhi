// JSBridge.m — WKWebView JS 注入与原生回调：点击单元格 → 复制本列往下

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "JSBridge.h"
#import "XLSXParser.h"
#import "Toast.h"

static NSString *const kBridgeName = @"wxExcelCopy";
static const char *kInjectedKey = "wxExcelCopyInjected";
static const char *kBridgeObjKey = "wxExcelCopyBridge";

static NSString *const kInjectScript =
@"(function(){"
"  if (window.__wxExcelCopyInjected) return;"
"  window.__wxExcelCopyInjected = true;"
"  function post(o){ try{ window.webkit.messageHandlers.wxExcelCopy.postMessage(o); }catch(e){} }"
"  document.addEventListener('click',function(e){"
"    var el=e.target||e.srcElement; if(!el)return; var info=null;"
"    var td=el.closest?el.closest('td,th'):null;"
"    if(td&&td.parentElement){"
"      var tr=td.parentElement;"
"      var row=tr.rowIndex, col=td.cellIndex;"
"      if(row>=0&&col>=0) info={row:row,col:col,mode:'table'};"
"    }"
"    if(!info){"
"      var g=el.closest?el.closest('[data-row],[data-col]'):null;"
"      if(g){ var r=parseInt(g.getAttribute('data-row'),10), c=parseInt(g.getAttribute('data-col'),10);"
"        if(!isNaN(r)&&!isNaN(c)) info={row:r,col:c,mode:'grid'}; }"
"    }"
"    if(info) post({type:'cell',row:info.row,col:info.col,mode:info.mode,url:location.href});"
"  },true);"
"})();";

@implementation JSBridge

+ (void)injectInto:(WKWebView *)webView {
    if (!webView) return;
    NSNumber *flag = objc_getAssociatedObject(webView, kInjectedKey);
    if (flag && flag.boolValue) return;

    JSBridge *bridge = [[JSBridge alloc] init];
    [webView.configuration.userContentController addScriptMessageHandler:bridge name:kBridgeName];

    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:kInjectScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO];
    [webView.configuration.userContentController addUserScript:script];

    objc_setAssociatedObject(webView, kInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // bridge 生命周期挂在 webView 上（bridge 不持有 webView，无循环引用）
    objc_setAssociatedObject(webView, kBridgeObjKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kBridgeName]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    if ([body[@"type"] isEqualToString:@"cell"]) {
        [self handleCell:body];
    }
}

#pragma mark - 预览页抬头下方插入列统计条（页面内容一部分，不悬浮）

+ (void)injectColumnStatsInto:(WKWebView *)webView {
    if (!webView) return;
    JSBridge *bridge = [[JSBridge alloc] init];
    [bridge doInjectColumnStatsInto:webView];
}

- (void)doInjectColumnStatsInto:(WKWebView *)webView {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 找最新可解析 xlsx（逐个试，第一个成功即可）
        NSArray<NSString *> *candidates = [self allXlsxSortedByTime];
        NSDictionary *counts = nil;
        NSInteger totalRows = 0;
        for (NSString *p in candidates) {
            NSError *e = nil;
            NSInteger mRow = 0;
            NSDictionary *c = [XLSXParser columnCountsAtPath:p maxRow:&mRow error:&e];
            if (c && !e) { counts = c; totalRows = mRow; break; }
        }
        if (!counts || counts.count == 0) return; // 静默：无可用文件

        // 组装统计文本：共 N 行 · A 列 X 行 · B 列 Y 行...
        NSArray *sortedCols = [counts.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [a compare:b];
        }];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSNumber *col in sortedCols) {
            [parts addObject:[NSString stringWithFormat:@"%@ 列 %@ 行",
                              [XLSXParser columnLetter:col.integerValue], counts[col]]];
        }
        NSString *statText = [NSString stringWithFormat:@"共 %ld 行 · %@",
                              (long)totalRows,
                              [parts componentsJoinedByString:@" · "]];

        // 主线程注入 div 到 body 最前（表格上方，紧跟页面抬头下方）
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *escaped = [statText stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
            escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
            NSString *js = [NSString stringWithFormat:
                @"(function(){"
                "  if (document.getElementById('wxExcelCopyStats')) return;"
                "  var d=document.createElement('div');"
                "  d.id='wxExcelCopyStats';"
                "  d.style.cssText='display:block;padding:9px 12px;font-size:13px;color:#333;"
                "background:#f7f7f7;border-bottom:1px solid #e8e8e8;white-space:normal;"
                "word-break:break-all;line-height:1.5;';"
                "  d.textContent=\"%@\";"
                "  var b=document.body;"
                "  if(!b) return;"
                "  b.insertBefore(d, b.firstChild);"
                "})();", escaped];
            [webView evaluateJavaScript:js completionHandler:nil];
        });
    });
}

#pragma mark - 点击单元格 → 复制本列往下

- (void)handleCell:(NSDictionary *)body {
    NSInteger row = [body[@"row"] integerValue] + 1; // DOM 0-based → Excel 1-based
    NSInteger col = [body[@"col"] integerValue] + 1;

    // 后台解析，避免卡微信主线程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 收集全沙盒 xlsx（最新在前），逐个尝试解析，第一个成功的用
        NSArray<NSString *> *candidates = [self allXlsxSortedByTime];
        NSArray<NSString *> *lines = nil;
        NSError *lastErr = nil;
        for (NSString *p in candidates) {
            NSError *e = nil;
            NSArray *l = [XLSXParser columnLinesAtPath:p column:col fromRow:row error:&e];
            if (l && !e) { lines = l; break; }
            lastErr = e;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!lines || lastErr) {
                [Toast show:@"未找到可用文件"];
                return;
            }
            if (lines.count == 0) {
                [Toast show:@"该列无数据"];
                return;
            }
            NSString *joined = [lines componentsJoinedByString:@"\n"];
            [UIPasteboard generalPasteboard].string = joined;
            NSString *letter = [XLSXParser columnLetter:col];
            NSInteger lastRow = row + (NSInteger)lines.count - 1;
            [Toast show:[NSString stringWithFormat:@"复制%@%ld-%@%ld共%lu条",
                         letter, (long)row, letter, (long)lastRow, (unsigned long)lines.count]];
        });
    });
}

#pragma mark - xlsx 扫描（轻量：只扫 fileCache/www/Documents 浅层，限量防内存爆炸）

- (NSArray<NSString *> *)allXlsxSortedByTime {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *items = [NSMutableArray array]; // {path, time}
    NSString *home = NSHomeDirectory();

    // 1) tmp/fileCache 与 tmp/www（微信预览/缓存目录，递归，限量）
    NSArray<NSString *> *subs = @[
        [home stringByAppendingPathComponent:@"tmp/fileCache"],
        [home stringByAppendingPathComponent:@"tmp/www"],
    ];
    for (NSString *root in subs) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        NSString *rel;
        NSUInteger scanned = 0;
        while ((rel = [en nextObject])) {
            if (++scanned > 20000) break;
            NSString *full = [root stringByAppendingPathComponent:rel];
            if ([full.pathExtension.lowercaseString isEqualToString:@"xlsx"]) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                NSDate *mt = attrs[NSFileModificationDate];
                if (mt) [items addObject:@{@"path": full, @"time": mt}];
                if (items.count >= 50) break;
            }
        }
    }

    // 2) Documents 浅层（只第一层文件，兜底）
    NSString *docRoot = [home stringByAppendingPathComponent:@"Documents"];
    NSArray *docFiles = [fm contentsOfDirectoryAtPath:docRoot error:nil];
    for (NSString *name in docFiles) {
        if (name.pathExtension.lowercaseString.length == 0) continue;
        if ([name.pathExtension.lowercaseString isEqualToString:@"xlsx"]) {
            NSString *full = [docRoot stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            NSDate *mt = attrs[NSFileModificationDate];
            if (mt) [items addObject:@{@"path": full, @"time": mt}];
        }
    }

    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"time"] compare:a[@"time"]]; // 最新在前
    }];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSDictionary *d in items) [paths addObject:d[@"path"]];
    return paths;
}

@end
