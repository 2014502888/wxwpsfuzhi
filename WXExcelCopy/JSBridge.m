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
        // 优先用预览 URL 直接定位文件（最可靠），找不到再扫沙盒
        NSString *path = [self xlsxPathFromURL:body[@"url"]];
        if (!path) path = [self findLatestXlsx];
        if (!path) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [Toast show:@"未找到 xlsx 文件"];
            });
            return;
        }
        NSError *err = nil;
        NSArray<NSString *> *lines = [XLSXParser columnLinesAtPath:path
                                                            column:col
                                                           fromRow:row
                                                             error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !lines) {
                [self showParseError:err path:path];
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

// 解析失败 → 弹详细错误（含文件魔数判断是否标准 xlsx）
- (void)showParseError:(NSError *)err path:(NSString *)path {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    long long size = [attrs[NSFileSize] longLongValue];
    NSData *head = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSString *magic = @"(读不到)";
    if (head.length >= 4) {
        const uint8_t *b = head.bytes;
        magic = [NSString stringWithFormat:@"%02X %02X %02X %02X", b[0], b[1], b[2], b[3]];
    } else if (head.length == 0) {
        magic = @"(空文件)";
    } else {
        magic = [NSString stringWithFormat:@"(%lu 字节)", (unsigned long)head.length];
    }
    NSString *msg = [NSString stringWithFormat:
        @"错误: %@\n路径: %@\n大小: %lld 字节\n文件头: %@\n(标准 xlsx 应为 50 4B 03 04)",
        err ? err.localizedDescription : @"解析返回空",
        path, size, magic];
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

#pragma mark - 沙盒扫描最近 xlsx

- (NSString *)findLatestXlsx {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *roots = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"],
    ];
    NSString *bestPath = nil;
    NSDate *bestTime = nil;
    for (NSString *root in roots) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        NSString *rel;
        while ((rel = [en nextObject])) {
            NSString *full = [root stringByAppendingPathComponent:rel];
            if ([full.pathExtension.lowercaseString isEqualToString:@"xlsx"]) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                NSDate *mt = attrs[NSFileModificationDate];
                if (!bestTime || [mt compare:bestTime] == NSOrderedDescending) {
                    bestTime = mt;
                    bestPath = full;
                }
            }
        }
    }
    return bestPath;
}

@end
