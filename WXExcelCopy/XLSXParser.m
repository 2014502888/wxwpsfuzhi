// XLSXParser.m — 最小 xlsx 解析器：zip 解包 → sheet1.xml + sharedStrings.xml → 全量行列

#import <Foundation/Foundation.h>
#import <zlib.h>
#import "XLSXParser.h"

#pragma mark - 小端读取 helpers

static inline uint16_t R16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t R32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24)); }
static inline uint64_t R64(const uint8_t *p) { return (uint64_t)R32(p) | ((uint64_t)R32(p + 4) << 32); }

// zip 签名（注意：字节流是小端存储，数值必须反写）
// 中央目录条目签名：字节 50 4B 01 02 → 小端数值 0x02014b50
static const uint32_t kCentralDirSig = 0x02014b50u;

#pragma mark - zip: raw deflate 解压

static NSData *InflateRaw(NSData *comp, NSUInteger expected) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2_(&strm, -MAX_WBITS, ZLIB_VERSION, (int)sizeof(z_stream)) != Z_OK) return nil;
    strm.next_in = (Bytef *)comp.bytes;
    strm.avail_in = (uInt)comp.length;
    NSUInteger cap = expected ? expected : (comp.length * 4 + 4096);
    if (cap > 64 * 1024 * 1024) cap = 64 * 1024 * 1024; // 上限保护：防损坏文件声明的超大解压长度
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    strm.next_out = out.mutableBytes;
    strm.avail_out = (uInt)out.length;
    int r = inflate(&strm, Z_FINISH);
    if (r != Z_STREAM_END) { inflateEnd(&strm); return nil; }
    [out setLength:strm.total_out];
    inflateEnd(&strm);
    return out;
}

#pragma mark - zip: 找 EOCD（带验证，防文件内部字节误命中；带下溢保护）

// 返回 EOCD 偏移；未找到返回 -1
static NSInteger FindEOCD(const uint8_t *bytes, NSUInteger len) {
    if (len < 22) return -1;
    NSUInteger scanMin = (len > 65535 + 22) ? (len - 65535 - 22) : 0;
    for (NSUInteger i = len - 22; i >= scanMin; i--) {
        if (bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06) {
            uint32_t cdSize = R32(bytes + i + 12);
            uint16_t entries = R16(bytes + i + 10);
            uint32_t cdStart = R32(bytes + i + 16);
            BOOL valid = (cdStart + cdSize <= len);
            if (valid) {
                if (entries == 0 || (cdStart + 4 <= len && R32(bytes + cdStart) == kCentralDirSig)) {
                    return (NSInteger)i;
                }
            }
            // 校验失败：可能是内部误命中，继续往前找
        }
        if (i == 0) break;
    }
    return -1;
}

#pragma mark - zip: 按文件名取条目

static NSData *ZipEntryData(NSData *zip, NSString *name) {
    const uint8_t *bytes = zip.bytes;
    NSUInteger len = zip.length;
    if (len < 22) return nil;

    NSInteger eocd = FindEOCD(bytes, len);
    if (eocd < 0) return nil;

    uint16_t cdEntries = R16(bytes + eocd + 10);
    uint32_t cdStart = R32(bytes + eocd + 16);
    uint64_t p = cdStart; // 64 位游标：防损坏文件 cdStart/nameLen 污染后 32 位溢出回绕

    for (uint16_t e = 0; e < cdEntries; e++) {
        if (p + 46 > (uint64_t)len) break;
        if (R32(bytes + (NSUInteger)p) != kCentralDirSig) break;
        uint16_t method = R16(bytes + (NSUInteger)p + 10);
        uint32_t compSize = R32(bytes + (NSUInteger)p + 20);
        uint32_t uncompSize = R32(bytes + (NSUInteger)p + 24);
        uint16_t nameLen = R16(bytes + (NSUInteger)p + 28);
        uint16_t extraLen = R16(bytes + (NSUInteger)p + 30);
        uint16_t commentLen = R16(bytes + (NSUInteger)p + 32);
        uint32_t localOff = R32(bytes + (NSUInteger)p + 42);

        if (p + 46 + nameLen > (uint64_t)len) break; // 读文件名前边界检查
        NSString *n = [[NSString alloc] initWithBytes:(bytes + (NSUInteger)p + 46) length:nameLen encoding:NSUTF8StringEncoding];
        if (n && [n.lowercaseString isEqualToString:name.lowercaseString]) {
            // zip64 支持：compSize/uncompSize/localOff 为 0xFFFFFFFF 占位时，真实值在 zip64 extra 字段(id 0x0001)
            uint64_t compSizeU = compSize, uncompSizeU = uncompSize, localOffU = localOff;
            if (compSize == 0xFFFFFFFFu || uncompSize == 0xFFFFFFFFu || localOff == 0xFFFFFFFFu) {
                uint64_t ex = (uint64_t)p + 46 + nameLen;
                uint64_t exEnd = ex + extraLen;
                if (exEnd > (uint64_t)len) exEnd = (uint64_t)len;
                while (ex + 4 <= exEnd) {
                    uint16_t hId = R16(bytes + (NSUInteger)ex);
                    uint16_t hLen = R16(bytes + (NSUInteger)ex + 2);
                    uint64_t hEnd = ex + 4 + hLen;
                    if (hEnd > exEnd) break;
                    if (hId == 0x0001) { // zip64 extra：字段按 uncomp→comp→localOff 顺序依次出现
                        uint64_t epos = ex + 4;
                        if (uncompSize == 0xFFFFFFFFu && epos + 8 <= hEnd) { uncompSizeU = R64(bytes + (NSUInteger)epos); epos += 8; }
                        if (compSize == 0xFFFFFFFFu && epos + 8 <= hEnd) { compSizeU = R64(bytes + (NSUInteger)epos); epos += 8; }
                        if (localOff == 0xFFFFFFFFu && epos + 8 <= hEnd) { localOffU = R64(bytes + (NSUInteger)epos); epos += 8; }
                    }
                    ex = hEnd;
                }
            }
            if (localOffU + 30 > (uint64_t)len) return nil;
            uint16_t lNameLen = R16(bytes + (NSUInteger)localOffU + 26);
            uint16_t lExtraLen = R16(bytes + (NSUInteger)localOffU + 28);
            uint64_t dataOff = localOffU + 30 + lNameLen + lExtraLen;
            // 本地头声明的压缩长度若与中央目录不一致：0 表示流式写入（真实大小在中央目录/data descriptor），
            // 直接采用中央目录值；非 0 且更小（截断/错位文件）才取较小且落在文件内的值
            uint32_t lCompSize = R32(bytes + (NSUInteger)localOffU + 18);
            uint64_t remain = (uint64_t)len - (uint64_t)dataOff;
            if (lCompSize != compSize) {
                if (lCompSize == 0) {
                    if (compSizeU > remain) return nil;
                } else if ((uint64_t)lCompSize < compSizeU && (uint64_t)lCompSize <= remain) {
                    compSizeU = lCompSize;
                } else if (compSizeU > remain) {
                    return nil;
                }
            }
            // 64 位比较防加法溢出（损坏文件 compSize 可被污染为超大值）
            if (dataOff + compSizeU > (uint64_t)len) return nil;
            NSData *comp = [zip subdataWithRange:NSMakeRange((NSUInteger)dataOff, (NSUInteger)compSizeU)];
            if (method == 0) return comp;
            if (method == 8) return InflateRaw(comp, (NSUInteger)uncompSizeU);
            return nil;
        }
        p += 46 + nameLen + extraLen + commentLen;
    }
    return nil;
}

#pragma mark - 列字母 ↔ 数字
static NSInteger ColumnNumberFromRef(NSString *ref) {
    NSInteger num = 0;
    for (NSUInteger i = 0; i < ref.length; i++) {
        unichar c = [ref characterAtIndex:i];
        if (c >= 'A' && c <= 'Z') {
            num = num * 26 + (c - 'A' + 1);
        } else if (c >= '0' && c <= '9') {
            break;
        } else {
            break;
        }
    }
    return num;
}

static NSInteger RowNumberFromRef(NSString *ref) {
    NSInteger num = 0;
    BOOL inDigit = NO;
    for (NSUInteger i = 0; i < ref.length; i++) {
        unichar c = [ref characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            inDigit = YES;
            num = num * 10 + (c - '0');
        } else if (inDigit) {
            break;
        }
    }
    return num;
}

#pragma mark - XML 解析

@interface WXXMLParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, NSString *> *> *rows;
@property (nonatomic, strong) NSMutableArray<NSString *> *sharedStrings;
@property (nonatomic) BOOL sharedMode;

// 状态机
@property (nonatomic, strong) NSString *curCellRef;
@property (nonatomic, strong) NSString *curCellType;
@property (nonatomic, strong) NSMutableString *curText;
@property (nonatomic) BOOL inValue;
@property (nonatomic) BOOL inText;
@property (nonatomic) BOOL inSi;
@property (nonatomic) BOOL inInlineStr;
@property (nonatomic, strong) NSMutableString *siBuffer;
@end

@implementation WXXMLParser

- (instancetype)initWithSharedMode:(BOOL)shared {
    self = [super init];
    if (self) {
        _sharedMode = shared;
        _rows = [NSMutableDictionary dictionary];
        _sharedStrings = [NSMutableArray array];
        _curText = [NSMutableString string];
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {

    if (self.sharedMode) {
        if ([elementName isEqualToString:@"si"]) {
            self.inSi = YES;
            self.siBuffer = [NSMutableString string];
        } else if ([elementName isEqualToString:@"t"]) {
            self.inText = YES;
        }
        return;
    }

    if ([elementName isEqualToString:@"c"]) {
        self.curCellRef = attributeDict[@"r"];
        self.curCellType = attributeDict[@"t"];
        self.inValue = NO;
        self.inInlineStr = NO;
        [self.curText setString:@""];
    } else if ([elementName isEqualToString:@"v"]) {
        if (self.curCellRef) { self.inValue = YES; [self.curText setString:@""]; }
    } else if ([elementName isEqualToString:@"is"]) {
        if (self.curCellRef) { self.inInlineStr = YES; [self.curText setString:@""]; }
    } else if ([elementName isEqualToString:@"t"]) {
        if (self.inInlineStr) self.inText = YES;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (self.sharedMode) {
        if (self.inSi && self.inText && self.siBuffer) [self.siBuffer appendString:string];
        return;
    }
    if ((self.inValue || self.inText) && self.curText) [self.curText appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {

    if (self.sharedMode) {
        if ([elementName isEqualToString:@"si"]) {
            [self.sharedStrings addObject:(self.siBuffer ? [self.siBuffer copy] : @"")];
            self.siBuffer = nil;
            self.inSi = NO;
            self.inText = NO;
        } else if ([elementName isEqualToString:@"t"]) {
            self.inText = NO;
        }
        return;
    }

    if ([elementName isEqualToString:@"v"]) {
        self.inValue = NO;
    } else if ([elementName isEqualToString:@"t"]) {
        if (self.inInlineStr) self.inText = NO;
    } else if ([elementName isEqualToString:@"c"]) {
        if (!self.curCellRef) return;
        NSString *raw = [self.curText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *value = raw;
        if ([self.curCellType isEqualToString:@"s"]) {
            NSInteger idx = raw.integerValue;
            if (idx >= 0 && idx < (NSInteger)self.sharedStrings.count) value = self.sharedStrings[idx];
        }
        if (value.length == 0) {
            self.curCellRef = nil;
            return;
        }
        NSInteger rowNum = RowNumberFromRef(self.curCellRef);
        NSInteger colNum = ColumnNumberFromRef(self.curCellRef);
        if (rowNum <= 0 || colNum <= 0) {
            self.curCellRef = nil;
            return;
        }
        NSMutableDictionary<NSNumber *, NSString *> *rowDict = self.rows[@(rowNum)];
        if (!rowDict) {
            rowDict = [NSMutableDictionary dictionary];
            self.rows[@(rowNum)] = rowDict;
        }
        rowDict[@(colNum)] = value;
        self.curCellRef = nil;
        self.curCellType = nil;
    }
}

@end

#pragma mark - 对外接口

@implementation XLSXParser

+ (NSArray<NSString *> *)zipEntriesAtPath:(NSString *)path error:(NSError **)error {
    NSData *zip = [NSData dataWithContentsOfFile:path];
    if (!zip) {
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取文件"}];
        return nil;
    }
    const uint8_t *bytes = zip.bytes;
    NSUInteger len = zip.length;
    if (len < 22) return @[];

    NSInteger eocd = FindEOCD(bytes, len);
    if (eocd < 0) return @[];

    uint16_t cdEntries = R16(bytes + eocd + 10);
    uint32_t cdStart = R32(bytes + eocd + 16);
    uint64_t p = cdStart; // 64 位游标：防损坏文件 cdStart/nameLen 污染后 32 位溢出回绕
    NSMutableArray *names = [NSMutableArray array];
    for (uint16_t e = 0; e < cdEntries; e++) {
        if (p + 46 > (uint64_t)len) break;
        if (R32(bytes + (NSUInteger)p) != kCentralDirSig) break;
        uint16_t nameLen = R16(bytes + (NSUInteger)p + 28);
        uint16_t extraLen = R16(bytes + (NSUInteger)p + 30);
        uint16_t commentLen = R16(bytes + (NSUInteger)p + 32);
        if (p + 46 + nameLen > (uint64_t)len) break; // 读文件名前边界检查
        NSString *n = [[NSString alloc] initWithBytes:(bytes + (NSUInteger)p + 46) length:nameLen encoding:NSUTF8StringEncoding];
        if (n) [names addObject:n];
        p += 46 + nameLen + extraLen + commentLen;
    }
    return names;
}

+ (NSDictionary<NSNumber *, NSDictionary<NSNumber *, NSString *> *> *)parseSheetAtPath:(NSString *)path
                                                                            sheetIndex:(NSInteger)index
                                                                                 error:(NSError **)error {
    @try {
    if (index < 1) index = 1;
    NSData *zip = [NSData dataWithContentsOfFile:path];
    if (!zip) {
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取文件"}];
        return nil;
    }

    NSString *sheetName = [NSString stringWithFormat:@"xl/worksheets/sheet%ld.xml", (long)index];
    NSData *sheetXml = ZipEntryData(zip, sheetName);
    if (!sheetXml && index == 1) {
        // 放宽：遍历条目找任意 sheet/worksheet 开头的 xml（兼容非标准命名）
        NSArray *entries = [self zipEntriesAtPath:path error:nil];
        for (NSString *e in entries) {
            NSString *low = e.lowercaseString;
            if ([low hasSuffix:@".xml"] &&
                ([low containsString:@"sheet"] || [low containsString:@"worksheet"])) {
                sheetXml = ZipEntryData(zip, e);
                if (sheetXml) break;
            }
        }
    }
    if (!sheetXml) {
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:2
                                            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"未找到 sheet%ld.xml", (long)index]}];
        return nil;
    }

    // sharedStrings
    NSData *ssXml = ZipEntryData(zip, @"xl/sharedStrings.xml");
    NSMutableArray<NSString *> *shared = [NSMutableArray array];
    if (ssXml) {
        WXXMLParser *sp = [[WXXMLParser alloc] initWithSharedMode:YES];
        NSXMLParser *xp = [[NSXMLParser alloc] initWithData:ssXml];
        xp.delegate = sp;
        [xp parse];
        shared = sp.sharedStrings;
    }

    // sheet
    WXXMLParser *shp = [[WXXMLParser alloc] initWithSharedMode:NO];
    shp.sharedStrings = shared;
    NSXMLParser *xp2 = [[NSXMLParser alloc] initWithData:sheetXml];
    xp2.delegate = shp;
    [xp2 parse];

    if (shp.rows.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:3 userInfo:@{NSLocalizedDescriptionKey:@"表格无数据"}];
        return nil;
    }
    return shp.rows;
    } @catch (NSException *e) {
        // 任何解析异常（损坏文件/越界/畸形 XML）都不允许崩：转 NSError 返回，调用方静默跳过
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:98
                                            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"解析异常(%@)", e.name]}];
        return nil;
    }
}

+ (NSDictionary<NSNumber *, NSDictionary<NSNumber *, NSString *> *> *)parseRowsAtPath:(NSString *)path
                                                                                error:(NSError **)error {
    return [self parseSheetAtPath:path sheetIndex:1 error:error];
}

+ (NSArray<NSString *> *)columnLinesAtPath:(NSString *)path
                                    column:(NSInteger)col
                                   fromRow:(NSInteger)row
                                sheetIndex:(NSInteger)sheetIndex
                                     error:(NSError **)error {
    @try {
    NSDictionary *rows = [self parseSheetAtPath:path sheetIndex:sheetIndex error:error];
    if (!rows) return nil;

    NSInteger maxRow = 0;
    for (NSNumber *r in rows.allKeys) {
        if (r.integerValue > maxRow) maxRow = r.integerValue;
    }
    if (row < 1) row = 1;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger lastNonEmpty = -1;
    for (NSInteger r = row; r <= maxRow; r++) {
        NSString *v = rows[@(r)][@(col)] ?: @"";
        [lines addObject:v];
        if (v.length > 0) lastNonEmpty = r;
    }
    if (lastNonEmpty < 0) return @[];
    NSInteger count = lastNonEmpty - row + 1;
    return [lines subarrayWithRange:NSMakeRange(0, (NSUInteger)count)];
    } @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:98
                                            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"解析异常(%@)", e.name]}];
        return nil;
    }
}

+ (NSString *)columnLetter:(NSInteger)col {
    NSMutableString *s = [NSMutableString string];
    NSInteger c = col;
    while (c > 0) {
        c--;
        unichar ch = (unichar)('A' + (c % 26));
        [s insertString:[NSString stringWithFormat:@"%c", ch] atIndex:0];
        c /= 26;
    }
    return s.length ? s : @"A";
}

@end
