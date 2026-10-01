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
"    var el=e.target||e.srcElement; if(!el)return;"
"    if(el.nodeType===3) el=el.parentElement; if(!el)return;"
"    // 统计条列项：点 A 列 N 行 → 复制该列整列"
"    var cs=el.closest?el.closest('[data-col]'):null;"
"    if(cs){ var c=parseInt(cs.getAttribute('data-col'),10); if(!isNaN(c)&&c>0){ post({type:'col',col:c}); return; } }"
"    var info=null;"
"    var td=el.closest?el.closest('td,th'):null;"
"    if(td&&td.parentElement){"
"      var tr=td.parentElement;"
"      var row, col;"
"      if(window.__wxExcelCopyHeader){ row=tr.rowIndex; col=td.cellIndex; }"
"      else { row=tr.rowIndex+1; col=td.cellIndex+1; }"
"      if(row>=1&&col>=1) info={row:row,col:col,mode:'table'};"
"    }"
"    if(!info){"
"      var g=el.closest?el.closest('[data-row],[data-col]'):null;"
"      if(g){ var r=parseInt(g.getAttribute('data-row'),10), c2=parseInt(g.getAttribute('data-col'),10);"
"        if(!isNaN(r)&&!isNaN(c2)&&r>0&&c2>0) info={row:r,col:c2,mode:'grid'}; }"
"    }"
"    if(info) post({type:'cell',row:info.row,col:info.col,mode:info.mode});"
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
    // 当前预览页 URL 优先从 frameInfo 取（比 JS location.href 可靠），用于文件匹配
    NSString *pageURL = message.frameInfo.request.URL.absoluteString ?: @"";
    if (pageURL.length == 0) pageURL = message.webView.URL.absoluteString ?: @"";
    if (pageURL.length == 0) return;
    NSMutableDictionary *body2 = [body mutableCopy];
    body2[@"url"] = pageURL;
    if ([body2[@"type"] isEqualToString:@"cell"]) {
        [self handleCell:body2];
    } else if ([body2[@"type"] isEqualToString:@"col"]) {
        [self handleCol:body2];
    }
}

#pragma mark - 注入列标行（A/B/C）+ 行号列（表头=1），类似 WPS 表格

+ (void)injectRowColHeaderInto:(WKWebView *)webView {
    if (!webView) return;
    NSString *js =
    @"(function(){"
    "  if(window.__wxExcelCopyRowCol) return;"
    "  window.__wxExcelCopyRowCol=true;"
    "  var t=document.querySelector('table');"
    "  if(!t||!t.rows||!t.rows.length) return;"
    "  var rows=t.rows;"
    "  var colW=[]; var f=rows[0];"
    "  for(var i=0;i<f.cells.length;i++){ colW.push(f.cells[i].getBoundingClientRect().width); }"
    "  var cellStyle='padding:1px 2px;text-align:center;font-size:10px;color:#999;background:#f2f2f2;"
    "border-right:1px solid #e5e5e5;border-bottom:1px solid #e5e5e5;white-space:nowrap;width:22px;';"
    "  for(var r=0;r<rows.length;r++){"
    "    var td=document.createElement('td');"
    "    td.textContent=String(r+1);"
    "    td.style.cssText=cellStyle;"
    "    rows[r].insertBefore(td, rows[r].firstChild);"
    "  }"
    "  function colLetter(n){ var s=''; while(n>0){ n--; s=String.fromCharCode(65+(n%26))+s; n=Math.floor(n/26); } return s||'A'; }"
    "  var hr=document.createElement('tr');"
    "  var hd=document.createElement('td');"
    "  hd.textContent='';"
    "  hd.style.cssText='padding:1px 2px;width:22px;background:#f2f2f2;border-right:1px solid #e5e5e5;border-bottom:1px solid #e5e5e5;';"
    "  hr.appendChild(hd);"
    "  var headStyle='padding:3px 8px;text-align:center;font-size:11px;font-weight:600;color:#666;"
    "background:#f2f2f2;border-right:1px solid #e5e5e5;border-bottom:1px solid #e5e5e5;white-space:nowrap;';"
    "  for(var c=0;c<colW.length;c++){"
    "    var h=document.createElement('td');"
    "    h.textContent=colLetter(c+1);"
    "    h.style.cssText=headStyle;"
    "    if(colW[c]&&colW[c]>0) h.style.width=colW[c]+'px';"
    "    hr.appendChild(h);"
    "  }"
    "  t.insertBefore(hr, t.firstChild);"
    "  window.__wxExcelCopyHeader=true;"
    "})();";
    [webView evaluateJavaScript:js completionHandler:nil];
}

#pragma mark - 统计条点击列项 → 复制整列（含表头）

- (void)handleCol:(NSDictionary *)body {
    NSInteger col = [body[@"col"] integerValue];
    if (col < 1) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *ordered = [self orderedCandidates:body[@"url"] ?: @""];
        NSArray<NSString *> *lines = nil;
        NSError *lastErr = nil;
        for (NSString *p in ordered) {
            NSError *e = nil;
            NSArray *l = [XLSXParser columnLinesAtPath:p column:col fromRow:1 error:&e]; // 从第 1 行（含表头）
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
            [Toast show:[NSString stringWithFormat:@"复制%@1-%@%lu共%lu条",
                         letter, letter, (unsigned long)lines.count, (unsigned long)lines.count]];
        });
    });
}

#pragma mark - 预览页抬头下方插入列统计条（页面内容一部分，不悬浮）

+ (void)injectColumnStatsInto:(WKWebView *)webView url:(NSString *)url {
    if (!webView) return;
    JSBridge *bridge = [[JSBridge alloc] init];
    [bridge doInjectColumnStatsInto:webView url:url];
}

- (void)doInjectColumnStatsInto:(WKWebView *)webView url:(NSString *)url {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 匹配当前预览文件优先，其余兜底
        NSArray<NSString *> *ordered = [self orderedCandidates:url ?: @""];
        NSDictionary *counts = nil;
        for (NSString *p in ordered) {
            NSError *e = nil;
            NSDictionary *c = [XLSXParser columnCountsAtPath:p error:&e];
            if (c && !e) { counts = c; break; }
        }
        if (!counts || counts.count == 0) return; // 静默：无可用文件

        // 组装统计文本：A 列 200 行 · B 列 180 行 ...（每项可点击，data-col=列号）
        NSArray *sortedCols = [counts.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [a compare:b];
        }];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSNumber *col in sortedCols) {
            [parts addObject:[NSString stringWithFormat:@"<span data-col=\"%ld\" style=\"color:#576b95;text-decoration:underline;\">%@ 列 %@ 行</span>",
                              (long)col.integerValue,
                              [XLSXParser columnLetter:col.integerValue], counts[col]]];
        }
        NSString *statText = [parts componentsJoinedByString:@"&nbsp;·&nbsp;"];

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
                "word-break:break-all;line-height:1.6;';"
                "  d.innerHTML=\"%@\";"
                "  var b=document.body;"
                "  if(!b) return;"
                "  b.insertBefore(d, b.firstChild);"
                "})();", escaped];
            [webView evaluateJavaScript:js completionHandler:nil];
        });
    });
}

#pragma mark - 当前预览文件匹配（www 副本整体作为前缀，匹配 fileCache 原始文件）

// 微信预览副本 = 原始文件的前截断，前缀完全一致 → 用副本整体内容匹配原始文件；
// 匹配不到返回 nil（调用方回退到最新文件）
- (NSString *)matchXlsxForPreviewURL:(NSString *)url {
    NSString *p = url ?: @"";
    if ([p hasPrefix:@"file://"]) p = [p substringFromIndex:7];
    p = [p stringByRemovingPercentEncoding];
    if (![p.pathExtension.lowercaseString isEqualToString:@"xlsx"]) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;

    NSData *whole = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:nil];
    if (!whole || whole.length < 1024) return nil;

    NSArray<NSString *> *cands = [self allXlsxSortedByTime];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in cands) {
        if ([c isEqualToString:p]) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:c error:nil];
        if (!attrs) continue;
        if ([attrs[NSFileSize] longLongValue] < (long long)whole.length) continue;
        NSData *cHead = [NSData dataWithContentsOfFile:c options:NSDataReadingMappedIfSafe error:nil];
        if (cHead.length >= whole.length) {
            NSData *cPrefix = [cHead subdataWithRange:NSMakeRange(0, whole.length)];
            if ([cPrefix isEqualToData:whole]) return c;
        }
    }
    return nil;
}

// 解析候选顺序：匹配文件优先，其余按时间
- (NSArray<NSString *> *)orderedCandidates:(NSString *)previewURL {
    NSMutableArray *ordered = [NSMutableArray array];
    NSString *matched = [self matchXlsxForPreviewURL:previewURL];
    if (matched) [ordered addObject:matched];
    for (NSString *c in [self allXlsxSortedByTime]) {
        if (![c isEqualToString:matched]) [ordered addObject:c];
    }
    return ordered;
}

#pragma mark - 点击单元格 → 复制本列往下

- (void)handleCell:(NSDictionary *)body {
    // row/col 已由 JS 换算为 Excel 1-based（含列标行/行号列偏移）
    NSInteger row = [body[@"row"] integerValue];
    NSInteger col = [body[@"col"] integerValue];
    if (row < 1 || col < 1) return;

    // 后台解析，避免卡微信主线程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *ordered = [self orderedCandidates:body[@"url"] ?: @""];
        NSArray<NSString *> *lines = nil;
        NSError *lastErr = nil;
        for (NSString *p in ordered) {
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
