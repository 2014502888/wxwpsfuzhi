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
"  /* URL校验只对主frame生效（避免误入微信搜一搜等网页表格）；iframe内跳过——多sheet文件表格在x-apple-ql-id:// iframe里，其URL不含.xlsx/.xls */"
"  if (window === window.top) {"
"    var href = (location.href || '').toLowerCase();"
"    if (href.indexOf('.xlsx') < 0 && href.indexOf('.xls') < 0) return;"
"  }"
"  document.__wxExcelCopyInjected = true;"
"  function post(o){ try{ window.webkit.messageHandlers.wxExcelCopy.postMessage(o); }catch(e){} }"
"  /* 读单元格纯文本：排除统计栏(#__wxExcelBar挂在A列第一格内)，否则textContent会把统计栏文字也读进去 */"
"  function cellText(cell){"
"    try{"
"      var parts = [];"
"      var cns = cell.childNodes;"
"      for (var i=0;i<cns.length;i++){"
"        var nd = cns[i];"
"        if (nd.nodeType === 3){ parts.push(nd.textContent); }"
"        else if (nd.nodeType === 1 && nd.id !== '__wxExcelBar'){ parts.push(nd.textContent); }"
"      }"
"      return parts.join('').replace(/^\\s+|\\s+$/g,'');"
"    }catch(e){ return (cell.textContent || '').replace(/^\\s+|\\s+$/g,''); }"
"  }"
"  /* 序列号已按用户要求删除：不注入行号列，表格回归原始布局 */"
"  function findPreviewTable(){"
"    var tables = document.getElementsByTagName('table');"
"    var best = null, bestCells = -1;"
"    for (var i=0;i<tables.length;i++){"
"      var t = tables[i];"
"      if (!t.rows || t.rows.length < 2) continue;"
"      /* 多sheet文件：非激活sheet的表格是隐藏的，跳过不可见的 */"
"      var st = getComputedStyle(t);"
"      if (st.display === 'none' || st.visibility === 'hidden') continue;"
"      var rc = t.getBoundingClientRect();"
"      if (rc.width === 0 || rc.height === 0) continue;"
"      /* 可见表里选非空单元格最多的（真正的数据表，空白sheet不会入选）*/"
"      var cnt = 0;"
"      for (var rr=0;rr<t.rows.length;rr++){"
"        var cells = t.rows[rr].cells;"
"        for (var cc=0;cc<cells.length;cc++){"
"          if ((cells[cc].textContent || '').replace(/\\s+/g,'').length > 0) cnt++;"
"        }"
"      }"
"      if (cnt > bestCells){ best = t; bestCells = cnt; }"
"    }"
"    if (best) return best;"
"    /* 兜底：非空数据表没找到时，取第一个可见表格（防止多sheet全空场景完全找不到）*/"
"    for (var i=0;i<tables.length;i++){"
"      var t2 = tables[i];"
"      if (!t2.rows || t2.rows.length < 2) continue;"
"      var s2 = getComputedStyle(t2);"
"      if (s2.display === 'none' || s2.visibility === 'hidden') continue;"
"      var r2 = t2.getBoundingClientRect();"
"      if (r2.width === 0 || r2.height === 0) continue;"
"      return t2;"
"    }"
"    return null;"
"  }"
"  /* ===== 列统计：学序列号模式 —— 栏锚在表头第一个单元格，absolute+right:100% 悬浮在表格左侧，跟表格走、不被容器裁切、秒显示；点击条目复制该列 ===== */"
"  function colLetter(n){ var s=''; while(n>0){ n--; s=String.fromCharCode(65+(n%26))+s; n=Math.floor(n/26);} return s||'A'; }"
"  function injectColHeader(){"
"    if (document.__wxExcelColHeaderInjected && document.getElementById('__wxExcelBar')) return true;"
"    var table = findPreviewTable();"
"    if (!table || !table.rows || table.rows.length < 1) return false;"
"    var head = table.rows[0];"
"    if (!head.cells || head.cells.length < 1) return false;"
"    /* 表头指纹：各格文本以 SOH(\\u0001) 分隔，原生据此匹配当前激活sheet */"
"    var headSig = '';"
"    for (var hc=0;hc<head.cells.length;hc++){"
"      headSig += cellText(head.cells[hc]) + '\\u0001';"
"    }"
"    /* 数据指纹：A列前3行数据值(SOH分隔)，原生据此区分同表头的不同文件(微信下载后文件名变数字,只能靠数据识别) */"
"    var dataSig = '';"
"    for (var di=1; di<=3 && di<table.rows.length; di++){"
"      var c0 = table.rows[di].cells[0];"
"      dataSig += cellText(c0) + '\\u0001';"
"    }"
"    /* 数量=该列非空单元格数，从当前表格 DOM 直接数（抬头行也计入，与复制口径一致；空白格不计）*/"
"    var counts = {};"
"    for (var r=0;r<table.rows.length;r++){"
"      var rr = table.rows[r];"
"      for (var c=0;c<rr.cells.length;c++){"
"        var tv = cellText(rr.cells[c]);"
"        if (tv.length > 0) counts[c+1] = (counts[c+1]||0) + 1;"
"      }"
"    }"
"    /* 栏宽按表头中文4字估算（11px粗体）*/"
"    var probe = document.createElement('span');"
"    probe.style.cssText = 'font-size:11px;font-weight:bold;font-variant-numeric:tabular-nums;white-space:nowrap;visibility:hidden;position:absolute;';"
"    probe.textContent = '字字字字';"
"    document.body.appendChild(probe);"
"    var barW = Math.ceil(probe.offsetWidth) + 12;"
"    document.body.removeChild(probe);"
"    /* 学序列号：表格整体右移让位，栏锚在表头第一个单元格（absolute+right:100%+top:0 悬浮表格左侧，跟表格走、不被容器裁切）*/"
"    table.style.marginLeft = (barW + 6) + 'px';"
"    var anchor = head.cells[0];"
"    anchor.style.position = 'relative';"
"    var bar = document.createElement('div');"
"    bar.id = '__wxExcelBar';"
"    bar.style.cssText = 'position:absolute;right:100%;top:0;width:'+barW+'px;background:rgba(250,250,250,0.97);box-shadow:0 1px 3px rgba(0,0,0,0.25);z-index:9999;font-size:11px;color:#222;font-family:-apple-system,sans-serif;';"
"    for (var c=0;c<head.cells.length;c++){"
"      var n = counts[c+1] || 0;"
"      var hText = cellText(head.cells[c]);"
"      var item = document.createElement('div');"
"      item.style.cssText = 'padding:4px 6px;border-bottom:1px solid rgba(0,0,0,0.08);text-align:center;cursor:pointer;line-height:1.3;';"
"      var l1 = document.createElement('div');"
"      l1.style.cssText = 'font-weight:bold;';"
"      l1.textContent = colLetter(c+1) + '列';"
"      item.appendChild(l1);"
"      var l2 = document.createElement('div');"
"      l2.style.cssText = 'font-variant-numeric:tabular-nums;';"
"      l2.textContent = String(n);"
"      item.appendChild(l2);"
"      /* 第三行：表头中文（数量在中间，最下面表头字符），最多显示4字符，超出省略号 */"
"      var l3 = document.createElement('div');"
"      l3.style.cssText = 'font-size:10px;color:#666;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';"
"      l3.textContent = hText.length > 4 ? (hText.slice(0,4) + '…') : hText;"
"      item.appendChild(l3);"
"      (function(cc, hs, ds, tb){ item.addEventListener('click', function(){"
"        /* DOM直取：从预览表格读该列全部非空值（含表头行 r=0，与统计口径一致）*/"
"        var dv = [];"
"        try{"
"          var rows = tb.rows;"
"          for (var r=0;r<rows.length;r++){"
"            var cells = rows[r].cells;"
"            if (cc-1 < cells.length){"
"              var v = cellText(cells[cc-1]);"
"              if (v) dv.push(v);"
"            }"
"          }"
"        }catch(e){}"
"        post({type:'colcopy',col:cc,header:hs,df:ds,domVals:dv,tableRows:tb.rows.length});"
"      }); })(c+1, headSig, dataSig, table);"
"      bar.appendChild(item);"
"    }"
"    anchor.appendChild(bar);"
"    document.__wxExcelColHeaderInjected = true;"
"    /* 大文件统计修正：预览只渲染前~4096行（渲染上限），DOM计数会少——发stat请求让原生读文件统计每列真实数量后回填 */"
"    if (table.rows.length >= 4000){"
"      window.__wxUpdateCounts = function(arr){"
"        try{"
"          if (!arr || !arr.length) return;"
"          var items = document.querySelectorAll('#__wxExcelBar > div');"
"          for (var i=0;i<items.length;i++){"
"            var cc = i+1;"
"            if (cc-1 < arr.length && arr[cc-1] != null){"
"              var l2 = items[i].querySelectorAll('div')[1];"
"              if (l2) l2.textContent = String(arr[cc-1]);"
"            }"
"          }"
"        }catch(e){}"
"      };"
"      post({type:'stat', header:headSig, df:dataSig});"
"    }"
"    return true;"
"  }"
"  function kick(){ return injectColHeader(); }"
"  if (document.readyState === 'interactive' || document.readyState === 'complete') kick();"
"  document.addEventListener('DOMContentLoaded', kick);"
"  var tries = 0;"
"  var timer = setInterval(function(){ tries++; if (kick() || tries > 150) clearInterval(timer); }, 200);"
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
    if ([body2[@"type"] isEqualToString:@"stat"]) {
        // 大文件统计修正：读文件统计每列真实数量（预览渲染截断时 DOM 计数不全），回填统计栏
        [self handleStat:body2 webView:message.webView];
        return;
    }
    if ([body2[@"type"] isEqualToString:@"colcopy"]) {
        [self handleColCopy:body2];
    }
}

// 大文件（预览只渲染前~4096行）统计修正：匹配文件→流式统计每列非空数（含表头）→回传JS更新统计栏
- (void)handleStat:(NSDictionary *)body webView:(WKWebView *)wv {
    if (!wv) return;
    NSArray<NSString *> *domHeader = [self splitHeaderSig:body[@"header"]];
    NSArray<NSString *> *domData = [self splitHeaderSig:body[@"df"]];
    NSString *fp = [NSString stringWithFormat:@"%@%@", (body[@"header"] ?: @""), (body[@"df"] ?: @"")];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *ordered = [self orderedCandidates:body[@"url"] ?: @""];
        NSString *path = nil;
        NSInteger sidx = 1;
        // 1) 缓存命中
        NSDictionary *cached = [self cachedMatchForFingerprint:fp];
        if (cached) {
            NSString *cp = cached[@"path"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:cp]) {
                path = cp; sidx = [cached[@"sheet"] integerValue];
            }
        }
        // 2) 精确：表头+A列前3行
        if (!path && domHeader.count > 0 && domData.count > 0) {
            for (NSString *p in ordered) {
                NSInteger s = [self matchedSheetIndexForHeader:domHeader data:domData col:1 file:p];
                if (s > 0) { path = p; sidx = s; [self cacheMatchFingerprint:fp path:p sheet:s]; break; }
            }
        }
        // 3) 表头匹配
        if (!path && domHeader.count > 0) {
            for (NSString *p in ordered) {
                NSInteger s = [self matchedSheetIndexForHeader:domHeader file:p];
                if (s > 0) { path = p; sidx = s; break; }
            }
        }
        // 4) 兜底最新
        if (!path && ordered.count > 0) { path = ordered[0]; sidx = 1; }
        if (!path) return;
        NSError *e = nil;
        NSArray<NSNumber *> *counts = [XLSXParser countColumnsAtPath:path sheetIndex:sidx error:&e];
        if (!counts || counts.count == 0) return;
        NSData *jsData = [NSJSONSerialization dataWithJSONObject:counts options:0 error:nil];
        if (!jsData) return;
        NSString *jsArr = [[NSString alloc] initWithData:jsData encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            [wv evaluateJavaScript:[NSString stringWithFormat:@"window.__wxUpdateCounts && window.__wxUpdateCounts(%@);", jsArr]
                 completionHandler:nil];
        });
    });
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

    // 表格 DOM 行数：小文件(<4000行)微信完整渲染→DOM直取（所见即所得，.xls/.xlsx通吃）；
    // 大文件(>=4000行)预览只渲染前~4096行(渲染上限)，DOM 不全→必须走文件解析拿完整数据
    NSInteger tableRows = [body[@"tableRows"] integerValue];
    if (tableRows < 4000) {
        // DOM 直取：JS 已从预览表格读出该列全部非空值（含表头行 r=0），不依赖文件匹配
        NSArray *domVals = body[@"domVals"];
        if ([domVals isKindOfClass:[NSArray class]] && domVals.count >= 2) {
            NSMutableArray *clean = [NSMutableArray array];
            for (id v in domVals) {
                if ([v isKindOfClass:[NSString class]]) {
                    NSString *s = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (s.length > 0) [clean addObject:s];
                }
            }
            if (clean.count >= 2) {
                [UIPasteboard generalPasteboard].string = [clean componentsJoinedByString:@"\n"];
                [Toast show:[NSString stringWithFormat:@"✓ 预览复制 %lu 条(含表头)", (unsigned long)clean.count]];
                return;
            }
        }
    }

    // 文件解析（缓存→精确→表头→回退）——大文件必须走这里拿完整数据；小文件 DOM 未取到/取不全时也兜底
    // DOM 表头指纹（JS 以 SOH 分隔各格文本），用于匹配当前激活 sheet
    NSArray<NSString *> *domHeader = [self splitHeaderSig:body[@"header"]];
    // DOM 数据指纹（A列前3行，SOH 分隔）：微信下载后文件名变数字，靠数据识别预览对应的下载文件
    NSArray<NSString *> *domData = [self splitHeaderSig:body[@"df"]];
    // 缓存指纹 = 表头指纹+数据指纹拼接（同一文件多 sheet 因 A 列前3行不同而区分）
    NSString *fp = [NSString stringWithFormat:@"%@%@", (body[@"header"] ?: @""), (body[@"df"] ?: @"")];

    // 后台解析，避免卡微信主线程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *ordered = [self orderedCandidates:body[@"url"] ?: @""];
        NSArray<NSString *> *lines = nil;
        NSInteger usedFile = -1, usedSheet = 1;
        // 第零遍：缓存命中（数据指纹→文件路径+sheet，命中直接解析这一个文件，不搜库；文件被删自动失效）
        NSDictionary *cached = [self cachedMatchForFingerprint:fp];
        if (cached) {
            NSString *path = cached[@"path"];
            NSInteger sidx = [cached[@"sheet"] integerValue];
            NSError *e = nil;
            NSArray *l = [XLSXParser columnLinesAtPath:path column:col fromRow:1 sheetIndex:sidx error:&e];
            if (l && !e) {
                NSInteger idx = (NSInteger)[ordered indexOfObject:path];
                lines = l; usedFile = (idx == NSNotFound ? -1 : idx); usedSheet = sidx;
            }
        }
        // 第一遍：表头+A列前3行数据 都匹配 → 精确命中预览对应文件（同表头不同数据的文件跳过）。
        // 搜全部（轻量解析只读前4行，快）；最近30里没有下载版时也能命中
        if (!lines && domHeader.count > 0 && domData.count > 0) {
            for (NSString *p in ordered) {
                NSInteger sidx = [self matchedSheetIndexForHeader:domHeader data:domData col:1 file:p];
                if (sidx > 0) {
                    NSError *e = nil;
                    NSArray *l = [XLSXParser columnLinesAtPath:p column:col fromRow:1 sheetIndex:sidx error:&e];
                    if (l && !e) {
                        lines = l; usedFile = (NSInteger)[ordered indexOfObject:p]; usedSheet = sidx;
                        [self cacheMatchFingerprint:fp path:p sheet:sidx];
                        break;
                    }
                }
            }
        }
        // 第二遍：仅表头匹配（无数据指纹或精确未中时，表头一致的文件也能用——比回退更接近预览内容）
        if (!lines && domHeader.count > 0) {
            for (NSString *p in ordered) {
                NSInteger sidx = [self matchedSheetIndexForHeader:domHeader file:p];
                if (sidx > 0) {
                    NSError *e = nil;
                    NSArray *l = [XLSXParser columnLinesAtPath:p column:col fromRow:1 sheetIndex:sidx error:&e];
                    if (l && !e) { lines = l; usedFile = (NSInteger)[ordered indexOfObject:p]; usedSheet = sidx; break; }
                }
            }
        }
        // 第三遍：匹配不到（预览文件未另存进沙盒/表头差异）→ 回退最近里第一个能解析的文件(sheet1)，保证功能可用
        if (!lines) {
            for (NSString *p in ordered) {
                NSError *e = nil;
                NSArray *l = [XLSXParser columnLinesAtPath:p column:col fromRow:1 sheetIndex:1 error:&e];
                if (l && !e) { lines = l; usedFile = (NSInteger)[ordered indexOfObject:p]; usedSheet = 1; break; }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!lines) {
                [Toast show:@"复制失败：未找到匹配的文件"];
                return;
            }
            if (lines.count == 0) {
                [Toast show:@"复制失败：该列无数据"];
                return;
            }
            NSString *joined = [lines componentsJoinedByString:@"\n"];
            [UIPasteboard generalPasteboard].string = joined;
            NSString *letter = [XLSXParser columnLetter:col];
            if (usedFile >= 0 && usedFile < (NSInteger)ordered.count) {
                [Toast show:[NSString stringWithFormat:@"✓ %@ sheet%ld 复制%@列共%lu条(含表头)",
                             ordered[(NSUInteger)usedFile].lastPathComponent, (long)usedSheet,
                             letter, (unsigned long)lines.count]];
            } else {
                [Toast show:[NSString stringWithFormat:@"✓ 复制%@列共%lu条(含表头)", letter, (unsigned long)lines.count]];
            }
        });
    });
}

#pragma mark - 复制匹配缓存（数据指纹 → 文件路径+sheet；老文件不用每次全库搜）

#define kWXMatchCacheKey @"WXExcelMatchCacheV1"
#define kWXMatchCacheLimit 50

// 命中返回缓存条目 {fp,path,sheet}；文件已删除则视为未命中
- (NSDictionary *)cachedMatchForFingerprint:(NSString *)fp {
    if (!fp || fp.length == 0) return nil;
    NSArray *arr = [[NSUserDefaults standardUserDefaults] arrayForKey:kWXMatchCacheKey];
    for (NSDictionary *d in arr) {
        if ([d[@"fp"] isEqualToString:fp]) {
            NSString *path = d[@"path"];
            if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) return d;
        }
    }
    return nil;
}

// 写入缓存（同指纹更新路径，最多保留最近 50 条）
- (void)cacheMatchFingerprint:(NSString *)fp path:(NSString *)path sheet:(NSInteger)sheet {
    if (!fp || fp.length == 0 || !path) return;
    NSMutableArray *arr = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:kWXMatchCacheKey] ?: @[]];
    for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
        if ([arr[(NSUInteger)i][@"fp"] isEqualToString:fp]) [arr removeObjectAtIndex:(NSUInteger)i];
    }
    [arr insertObject:@{@"fp": fp, @"path": path, @"sheet": @(sheet)} atIndex:0];
    while (arr.count > kWXMatchCacheLimit) [arr removeLastObject];
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:kWXMatchCacheKey];
}

#pragma mark - 多 sheet 匹配（复制时按当前预览 sheet 取数）

// 拆 JS 表头指纹：SOH 分隔 → 各格文本（去首尾空白，去掉末尾空串）
- (NSArray<NSString *> *)splitHeaderSig:(NSString *)sig {
    if (!sig || sig.length == 0) return @[];
    NSArray<NSString *> *parts = [sig componentsSeparatedByString:@"\x01"];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *s in parts) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [out addObject:t];
    }
    while (out.count > 0 && out.lastObject.length == 0) [out removeLastObject];
    return out;
}

// 在文件里找与 DOM 表头匹配的 sheet 索引（1-based）；找不到返回 0
- (NSInteger)matchedSheetIndexForHeader:(NSArray<NSString *> *)domHeader file:(NSString *)path {
    for (NSInteger idx = 1; idx <= 64; idx++) {
        NSError *e = nil;
        NSDictionary *rows = [XLSXParser parseSheetAtPath:path sheetIndex:idx error:&e];
        if (!rows) {
            if (e && e.code == 2) break; // sheetN.xml 不存在 → 枚举结束
            continue;                     // 空表/解析异常 → 下一个 sheet
        }
        NSDictionary *h = rows[@(1)];
        if (h && [self headerMatches:domHeader sheetRow:h]) return idx;
    }
    return 0;
}

// 表头 + 数据指纹（指定列前N行）都匹配 → 精确命中；找不到返回 0（轻量解析只读前4行，可全库遍历）
- (NSInteger)matchedSheetIndexForHeader:(NSArray<NSString *> *)domHeader data:(NSArray<NSString *> *)domData col:(NSInteger)col file:(NSString *)path {
    for (NSInteger idx = 1; idx <= 64; idx++) {
        NSError *e = nil;
        NSDictionary *rows = [XLSXParser parseSheetAtPath:path sheetIndex:idx maxRows:4 error:&e];
        if (!rows) {
            if (e && e.code == 2) break;
            continue;
        }
        NSDictionary *h = rows[@(1)];
        if (!h || ![self headerMatches:domHeader sheetRow:h]) continue;
        if ([self dataMatches:domData col:col rows:rows]) return idx;
    }
    return 0;
}

// DOM 数据指纹（A列前N行）与文件同列前N行（表头下第1行起）逐行一致 → 匹配
- (BOOL)dataMatches:(NSArray<NSString *> *)domData col:(NSInteger)col rows:(NSDictionary *)rows {
    NSInteger nonEmpty = 0, matched = 0;
    for (NSInteger i = 0; i < domData.count; i++) {
        NSString *d = domData[i];
        if (d.length == 0) continue;
        nonEmpty++;
        NSString *v = [rows[@(i + 2)][@(col)] ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([d isEqualToString:v]) matched++;
    }
    return nonEmpty > 0 && matched == nonEmpty;
}

// DOM 表头非空格全部与文件表头同位置文本一致 → 匹配
- (BOOL)headerMatches:(NSArray<NSString *> *)domHeader sheetRow:(NSDictionary *)sheetRow {
    NSInteger nonEmpty = 0, matched = 0;
    for (NSInteger i = 0; i < domHeader.count; i++) {
        NSString *d = domHeader[i];
        if (d.length == 0) continue;
        nonEmpty++;
        NSString *s = [(sheetRow[@(i + 1)] ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([d isEqualToString:s]) matched++;
    }
    return nonEmpty > 0 && matched == nonEmpty;
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
