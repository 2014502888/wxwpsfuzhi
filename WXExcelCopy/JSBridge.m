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
"  function dump(){"
"    var tables=document.querySelectorAll('table').length;"
"    var tds=document.querySelectorAll('td,th').length;"
"    var grids=document.querySelectorAll('[data-row],[data-col]').length;"
"    var canvases=document.querySelectorAll('canvas').length;"
"    var sample='';"
"    var td0=document.querySelector('td,th');"
"    if(td0){ sample=(td0.innerText||td0.textContent||'').slice(0,40); }"
"    post({type:'dump',url:location.href,tables:tables,tds:tds,grids:grids,canvases:canvases,sample:sample,title:document.title||'',cls:(document.body?document.body.className||'':'')});"
"  }"
"  setTimeout(dump,600);"
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
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"dump"]) {
        [self handleDump:body];
    } else if ([type isEqualToString:@"cell"]) {
        [self handleCell:body];
    }
}

#pragma mark - dump 诊断（弹窗展示 + 复制，沙盒文件普通方式看不到）

+ (UIViewController *)topVC {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (UIViewController *)topViewController {
    return [JSBridge topVC];
}

- (BOOL)isHitURL:(NSString *)url {
    NSString *lower = url.lowercaseString;
    return [lower containsString:@"xlsx"] ||
           [lower containsString:@"spreadsheet"] ||
           [lower containsString:@"sheet"] ||
           [lower containsString:@"preview"] ||
           [lower containsString:@"file"];
}

- (void)handleDump:(NSDictionary *)body {
    NSString *diag = [NSString stringWithFormat:
        @"URL: %@\ntables: %@  tds: %@  grids: %@  canvases: %@\ntitle: %@\nbodyCls: %@\nsample: %@",
        body[@"url"] ?: @"", body[@"tables"] ?: @"0", body[@"tds"] ?: @"0",
        body[@"grids"] ?: @"0", body[@"canvases"] ?: @"0",
        body[@"title"] ?: @"", body[@"cls"] ?: @"", body[@"sample"] ?: @""];

    // 备份到沙盒日志（有文件工具时可用）
    NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/wxExcelCopy_log.txt"];
    NSString *line = [NSString stringWithFormat:@"\n[%@]\n%@\n", [NSDate date], diag];
    @synchronized (self) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        }
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) {}
        }
    }

    // 非预览页（普通 H5）不弹窗，避免打扰
    if (![self isHitURL:body[@"url"] ?: @""]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"WXExcelCopy 诊断"
                                                                    message:diag
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"复制诊断信息"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = diag;
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
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
        NSString *usedPath = nil;
        NSArray<NSString *> *lines = nil;
        NSError *lastErr = nil;
        for (NSString *p in candidates) {
            NSError *e = nil;
            NSArray *l = [XLSXParser columnLinesAtPath:p column:col fromRow:row error:&e];
            if (l && !e) { usedPath = p; lines = l; break; }
            lastErr = e;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!lines || lastErr) {
                [self showParseError:lastErr path:usedPath ?: @"(无可用文件)" candidates:candidates];
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
            [Toast show:[NSString stringWithFormat:@"已复制 %@%ld:%@%lu · %lu 行",
                         letter, (long)row, letter, (unsigned long)lastRow, (unsigned long)lines.count]];
        });
    });
}

// 从 file:// URL 提取 xlsx 路径
- (NSString *)xlsxPathFromURL:(NSString *)url {
    if (!url.length) return nil;
    NSString *p = url;
    if ([p hasPrefix:@"file://"]) p = [p substringFromIndex:7];
    p = [p stringByRemovingPercentEncoding];
    if (![p.pathExtension.lowercaseString isEqualToString:@"xlsx"]) return nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    return nil;
}

// zip 条目列表（诊断用）
- (NSString *)zipEntryList:(NSString *)path {
    NSArray *entries = [XLSXParser zipEntriesAtPath:path error:nil];
    if (!entries) return @"(无法读取)";
    if (entries.count == 0) return @"(空 zip 或无条目)";
    NSArray *head = entries.count > 25 ? [entries subarrayWithRange:NSMakeRange(0, 25)] : entries;
    NSString *list = [head componentsJoinedByString:@"\n"];
    if (entries.count > 25) list = [list stringByAppendingFormat:@"\n... 共 %lu 条", (unsigned long)entries.count];
    return list;
}

- (NSString *)hexDump:(NSData *)d {
    if (!d || d.length == 0) return @"(空)";
    NSMutableString *s = [NSMutableString string];
    const uint8_t *b = d.bytes;
    NSUInteger n = MIN(d.length, 96);
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02X ", b[i]];
    return s;
}

// 探测 EOCD：返回偏移，未找到返回 -1
- (NSInteger)findEOCDOffset:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    if (len < 22) return -1;
    NSUInteger scanMin = (len > 65535 + 22) ? (len - 65535 - 22) : 0;
    for (NSUInteger i = len - 22; i >= scanMin; i--) {
        if (bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06) {
            return (NSInteger)i;
        }
    }
    return -1;
}

// 解析失败 → 弹详细错误（含文件魔数判断是否标准 xlsx + 全沙盒候选列表）
- (void)showParseError:(NSError *)err path:(NSString *)path candidates:(NSArray<NSString *> *)candidates {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    long long size = [attrs[NSFileSize] longLongValue];
    NSData *fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSString *magic = @"(读不到)";
    if (fileData.length >= 4) {
        const uint8_t *b = fileData.bytes;
        magic = [NSString stringWithFormat:@"%02X %02X %02X %02X", b[0], b[1], b[2], b[3]];
    } else if (fileData.length == 0) {
        magic = @"(空文件)";
    } else {
        magic = [NSString stringWithFormat:@"(%lu 字节)", (unsigned long)fileData.length];
    }
    NSInteger eocdOff = [self findEOCDOffset:fileData];
    NSData *head = fileData.length > 96 ? [fileData subdataWithRange:NSMakeRange(0, 96)] : fileData;
    NSData *tail = fileData.length > 96 ? [fileData subdataWithRange:NSMakeRange(fileData.length - 96, 96)] : fileData;
    NSMutableString *candList = [NSMutableString string];
    if (candidates.count) {
        for (NSUInteger i = 0; i < MIN(candidates.count, 15); i++) {
            [candList appendFormat:@"%lu. %@\n", (unsigned long)(i + 1), candidates[i]];
        }
        if (candidates.count > 15) [candList appendFormat:@"... 共 %lu 个", (unsigned long)candidates.count];

        // 第一个候选文件的真实结构（判断是否标准 zip / 微信是否改过）
        NSString *first = candidates.firstObject;
        NSData *fdata = [NSData dataWithContentsOfFile:first options:NSDataReadingMappedIfSafe error:nil];
        if (fdata.length) {
            NSData *fhead = fdata.length > 64 ? [fdata subdataWithRange:NSMakeRange(0, 64)] : fdata;
            NSInteger feocd = [self findEOCDOffset:fdata];
            NSArray *fentries = [XLSXParser zipEntriesAtPath:first error:nil];
            [candList appendFormat:@"\n---- 第 1 个文件实际结构 ----\n路径: %@\n大小: %lu B\nEOCD: %ld\n头 64B: %@\n条目(%lu): %@\n",
                first, (unsigned long)fdata.length, (long)feocd,
                [self hexDump:fhead], (unsigned long)(fentries ? fentries.count : 0),
                fentries.count ? [fentries componentsJoinedByString:@", "] : @"(空)"];
        }
    } else {
        [candList appendString:@"(沙盒内未找到 xlsx)"];
    }
    NSString *msg = [NSString stringWithFormat:
        @"错误: %@\n路径: %@\n大小: %lld 字节\n文件头: %@ (标准 zip 应为 50 4B 03 04)\nEOCD 偏移: %ld\n\n文件头 96B hex:\n%@\n\n文件尾 96B hex:\n%@\n\n沙盒内 xlsx 候选:\n%@",
        err ? err.localizedDescription : @"解析返回空",
        path, size, magic, (long)eocdOff,
        [self hexDump:head], [self hexDump:tail],
        candList];
    UIViewController *top = [JSBridge topVC];
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"解析失败详情"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = msg;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
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

// 兼容旧调用
- (NSString *)findLatestXlsx {
    NSArray *all = [self allXlsxSortedByTime];
    return all.firstObject;
}

@end
