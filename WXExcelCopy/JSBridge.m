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
"  document.addEventListener('click',function(e){"
"    var el=e.target||e.srcElement; if(!el)return;"
"    if(el.nodeType===3) el=el.parentElement; if(!el)return;"
"    var td=el.closest?el.closest('td,th'):null;"
"    if(!td||!td.parentElement) return;"
"    var tr=td.parentElement;"
"    var row=tr.rowIndex+1, col=td.cellIndex+1;"
"    if(row<1||col<1) return;"
"    post({type:'cell',row:row,col:col});"
"  },true);"
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
    if ([body2[@"type"] isEqualToString:@"cell"]) {
        [self handleCell:body2];
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
    // row/col 已由 JS 换算为 Excel 1-based（DOM 0-based + 1）
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

#pragma mark - xlsx 扫描（只读 Documents/<乱码>/OpenData/<乱码>/<xlsx>，不递归其他目录）

- (NSArray<NSString *> *)allXlsxSortedByTime {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *items = [NSMutableArray array]; // {path, time}
    NSString *home = NSHomeDirectory();
    NSString *docRoot = [home stringByAppendingPathComponent:@"Documents"];

    // 微信"下载/另存"的 xlsx 固定存于 Documents/<乱码文件夹>/OpenData/<乱码日期文件夹>/<改名xlsx>
    // 只枚举这两层，目录名精确匹配 OpenData（OD 大写、其余小写）
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
