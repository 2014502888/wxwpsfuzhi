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
"  if (document.__wxExcelCopyInjected) return;"
"  document.__wxExcelCopyInjected = true;"
"  function post(o){ try{ window.webkit.messageHandlers.wxExcelCopy.postMessage(o); }catch(e){} }"
"  /* ===== 序列号：插进每行首个单元格内 absolute 悬浮在行左侧，行对齐交给浏览器，不占列宽 ===== */"
"  function findPreviewTable(){"
"    var tables = document.getElementsByTagName('table');"
"    for (var i=0;i<tables.length;i++){"
"      var t = tables[i];"
"      if (t.rows && t.rows.length >= 2) return t;"
"    }"
"    return null;"
"  }"
"  function injectRowNumbers(){"
"    if (document.__wxExcelRowNumInjected) return true;"
"    var table = findPreviewTable();"
"    if (!table || !table.parentNode) return false;"
"    var rows = table.rows;"
"    /* 量出 '99999' 五个数字的实际像素宽度作序列号宽度 */"
"    var probe = document.createElement('span');"
"    probe.style.cssText = 'font-size:13px;font-variant-numeric:tabular-nums;white-space:nowrap;visibility:hidden;position:absolute;';"
"    probe.textContent = '99999';"
"    document.body.appendChild(probe);"
"    var pad = Math.ceil(probe.offsetWidth) + 4;"
"    document.body.removeChild(probe);"
"    /* 表格整体右移让出序列号空间（列宽/行高不变）*/"
"    table.style.marginLeft = pad + 'px';"
"    /* 每个序列号插进该行第一个单元格：absolute+right:100% 悬浮在行左侧，行对齐交给浏览器，不占列宽不挤列 */"
"    for (var r=0;r<rows.length;r++){"
"      var rowEl = rows[r];"
"      if (!rowEl.cells || !rowEl.cells[0]) continue;"
"      var td = rowEl.cells[0];"
"      td.style.position = 'relative';"
"      var num = document.createElement('div');"
"      num.style.cssText = 'position:absolute;right:100%;top:0;bottom:0;width:'+pad+'px;margin:0;padding:0;display:flex;align-items:center;justify-content:center;font-size:13px;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;';"
"      num.textContent = (r === 0) ? '' : String(r); /* 抬头行留空，数据行从 1 开始 */"
"      td.appendChild(num);"
"    }"
"    document.__wxExcelRowNumInjected = true;"
"    return true;"
"  }"
"  /* ===== 列标悬浮：插进表头行每个单元格内 absolute 悬浮在 td 上方（跟序列号同款插法，不占位不挤表）===== */"
"  function colLetter(n){ var s=''; while(n>0){ n--; s=String.fromCharCode(65+(n%26))+s; n=Math.floor(n/26);} return s||'A'; }"
"  function injectColHeader(){"
"    if (document.__wxExcelColHeaderInjected) return true;"
"    var table = findPreviewTable();"
"    if (!table || !table.rows || table.rows.length < 1) return false;"
"    var head = table.rows[0];"
"    if (!head.cells || head.cells.length < 1) return false;"
"    /* 数量=该列非空单元格数，从当前表格 DOM 直接数（跟序列号同源；抬头行除外、空白格不计）*/"
"    var counts = {};"
"    for (var r=1;r<table.rows.length;r++){"
"      var rr = table.rows[r];"
"      for (var c=0;c<rr.cells.length;c++){"
"        var tv = rr.cells[c].textContent || '';"
"        if (tv.replace(/^\\s+|\\s+$/g,'').length > 0) counts[c+1] = (counts[c+1]||0) + 1;"
"      }"
"    }"
"    for (var c=0;c<head.cells.length;c++){"
"      var td = head.cells[c];"
"      td.style.position = 'relative';"
"      var letter = colLetter(c+1);"
"      var n = counts[c+1];"
"      /* 容器：absolute 贴 td 上方，内部从上到下：3行空位(留给文件名抬头) → A+数量 → A(紧贴表格) */"
"      var box = document.createElement('div');"
"      box.style.cssText = 'position:absolute;left:0;right:0;bottom:100%;margin:0;padding:0;';"
"      var sp = document.createElement('div');"
"      sp.style.cssText = 'height:42px;margin:0;padding:0;pointer-events:none;';"
"      box.appendChild(sp);"
"      var cap = document.createElement('div');"
"      cap.style.cssText = 'margin:0;padding:0;text-align:center;font-size:10px;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;cursor:pointer;';"
"      cap.textContent = n ? (letter + ' ' + n) : letter;"
"      box.appendChild(cap);"
"      var lab = document.createElement('div');"
"      lab.style.cssText = 'margin:0;padding:0;text-align:center;font-size:11px;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;pointer-events:none;';"
"      lab.textContent = letter;"
"      box.appendChild(lab);"
"      td.appendChild(box);"
"      /* 点击 A+数量 → 复制该列（含表头行）*/"
"      cap.addEventListener('click',(function(cc){ return function(){ post({type:'colcopy',col:cc}); }; })(c+1));"
"    }"
"    document.__wxExcelColHeaderInjected = true;"
"    return true;"
"  }"
"  function kick(){ var a=injectRowNumbers(); var b=injectColHeader(); return a && b; }"
"  if (document.readyState === 'interactive' || document.readyState === 'complete') kick();"
"  document.addEventListener('DOMContentLoaded', kick);"
"  var tries = 0;"
"  var timer = setInterval(function(){ tries++; if (kick() || tries > 30) clearInterval(timer); }, 200);"
"})();";

@implementation JSBridge

// 挂接消息 handler：以 userContentController 为粒度防重复（同名重复注册会崩溃；
// controller 被微信替换时新 controller 无标记，会重新挂上）
+ (void)attachBridgeToWebView:(WKWebView *)webView {
    if (!webView) return;
    WKUserContentController *ctrl = webView.configuration.userContentController;
    if (!ctrl) return;
    if (!objc_getAssociatedObject(ctrl, kBridgeObjKey)) {
        JSBridge *bridge = [[JSBridge alloc] init];
        [ctrl addScriptMessageHandler:bridge name:kBridgeName];
        objc_setAssociatedObject(ctrl, kBridgeObjKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

+ (void)injectInto:(WKWebView *)webView {
    if (!webView) return;
    NSNumber *flag = objc_getAssociatedObject(webView, kInjectedKey);
    if (flag && flag.boolValue) return;

    [self attachBridgeToWebView:webView];

    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:kInjectScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO];
    [webView.configuration.userContentController addUserScript:script];

    objc_setAssociatedObject(webView, kInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kBridgeName]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    // 当前预览页 URL 优先从 frameInfo 取；拿不到也不能丢弃消息（回退空串，由文件匹配自动回退最新文件）
    NSString *pageURL = message.frameInfo.request.URL.absoluteString ?: @"";
    if (pageURL.length == 0) pageURL = message.webView.URL.absoluteString ?: @"";
    NSMutableDictionary *body2 = [body mutableCopy];
    body2[@"url"] = pageURL ?: @"";
    if ([body2[@"type"] isEqualToString:@"colcopy"]) {
        [self handleColCopy:body2];
    }
}

#pragma mark - 补注入（didFinishNavigation 时调用，防 WKUserScript 时序/controller 被替换）

+ (void)ensureInjected:(WKWebView *)webView {
    if (!webView) return;
    // 补挂消息 handler：controller 粒度防重复（微信替换 controller 时新 controller 会重新挂上）
    [self attachBridgeToWebView:webView];
    // 直接在当前 document 运行点击注入脚本（WKUserScript 只在导航前注入，此时补一次立即生效）
    [webView evaluateJavaScript:kInjectScript completionHandler:nil];
}

#pragma mark - 当前预览文件匹配（www 副本整体作为前缀，匹配 OpenData 完整文件）

// 微信预览副本 = 原始文件的前截断，前缀完全一致 → 用副本整体内容匹配 OpenData 完整文件；
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

#pragma mark - 点击列标（A+数量）→ 复制整列（含表头行，从第 1 行开始）

- (void)handleColCopy:(NSDictionary *)body {
    NSInteger col = [body[@"col"] integerValue];
    if (col < 1) return;

    // 后台解析，避免卡微信主线程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *ordered = [self orderedCandidates:body[@"url"] ?: @""];
        NSArray<NSString *> *lines = nil;
        NSError *lastErr = nil;
        for (NSString *p in ordered) {
            NSError *e = nil;
            NSArray *l = [XLSXParser columnLinesAtPath:p column:col fromRow:1 error:&e];
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
            NSInteger lastRow = (NSInteger)lines.count;
            [Toast show:[NSString stringWithFormat:@"复制%@1-%@%ld共%lu条",
                         letter, letter, (long)lastRow, (unsigned long)lines.count]];
        });
    });
}

#pragma mark - xlsx 扫描（只读 Documents/<乱码>/OpenData/<乱码>/<xlsx>，不递归其他目录）

- (NSArray<NSString *> *)allXlsxSortedByTime {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *items = [NSMutableArray array]; // {path, time}
    NSString *home = NSHomeDirectory();
    NSString *docRoot = [home stringByAppendingPathComponent:@"Documents"];

    // 微信"下载/另存"的 xlsx 固定存于 Documents/<乱码文件夹>/OpenData/<乱码日期文件夹>/<改名xlsx>
    // 只枚举这两层，目录名大小写不敏感匹配 OpenData（OpenData/openDATA/opendata 都认）
    NSArray *sub1 = [fm contentsOfDirectoryAtPath:docRoot error:nil];
    for (NSString *d1 in sub1) {
        NSString *p1 = [docRoot stringByAppendingPathComponent:d1];
        BOOL isDir1 = NO;
        if (![fm fileExistsAtPath:p1 isDirectory:&isDir1] || !isDir1) continue;
        NSArray *sub1names = [fm contentsOfDirectoryAtPath:p1 error:nil];
        for (NSString *odName in sub1names) {
            // OpenData 大小写不敏感匹配：iOS 枚举返回的实际目录名可能与显示的不完全一致（OpenData/openDATA/opendata 都认）
            if (![odName.lowercaseString isEqualToString:@"opendata"]) continue;
            NSString *od = [p1 stringByAppendingPathComponent:odName];
            BOOL odDir = NO;
            if (![fm fileExistsAtPath:od isDirectory:&odDir] || !odDir) continue;
            NSArray *sub2 = [fm contentsOfDirectoryAtPath:od error:nil];
            for (NSString *d2 in sub2) {
                NSString *p2 = [od stringByAppendingPathComponent:d2];
                BOOL isDir2 = NO;
                if (![fm fileExistsAtPath:p2 isDirectory:&isDir2] || !isDir2) continue;
                NSArray *files = [fm contentsOfDirectoryAtPath:p2 error:nil];
                for (NSString *name in files) {
                    if (![name.pathExtension.lowercaseString isEqualToString:@"xlsx"]) continue;
                    NSString *full = [p2 stringByAppendingPathComponent:name];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                    NSDate *mt = attrs[NSFileModificationDate];
                    if (mt) [items addObject:@{@"path": full, @"time": mt}];
                }
            }
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
