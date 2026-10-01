// XLSXParser.m — 最小 xlsx 解析器：zip 解包 → sheet1.xml + sharedStrings.xml → 全量行列

#import <Foundation/Foundation.h>
#import <zlib.h>
#import "XLSXParser.h"

#pragma mark - 小端读取 helpers

static inline uint16_t R16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t R32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24)); }

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
    uint32_t p = cdStart;

    for (uint16_t e = 0; e < cdEntries; e++) {
        if (p + 46 > len) break;
        if (R32(bytes + p) != kCentralDirSig) break;
        uint16_t method = R16(bytes + p + 10);
        uint32_t compSize = R32(bytes + p + 20);
        uint32_t uncompSize = R32(bytes + p + 24);
        uint16_t nameLen = R16(bytes + p + 28);
        uint16_t extraLen = R16(bytes + p + 30);
        uint16_t commentLen = R16(bytes + p + 32);
        uint32_t localOff = R32(bytes + p + 42);

        NSString *n = [[NSString alloc] initWithBytes:(bytes + p + 46) length:nameLen encoding:NSUTF8StringEncoding];
        if (n && [n.lowercaseString isEqualToString:name.lowercaseString]) {
            if (localOff + 30 > len) return nil;
            uint16_t lNameLen = R16(bytes + localOff + 26);
            uint16_t lExtraLen = R16(bytes + localOff + 28);
            uint32_t dataOff = localOff + 30 + lNameLen + lExtraLen;
            if (dataOff + compSize > len) return nil;
            NSData *comp = [zip subdataWithRange:NSMakeRange(dataOff, compSize)];
            if (method == 0) return comp;
            if (method == 8) return InflateRaw(comp, uncompSize);
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
    uint32_t p = cdStart;
    NSMutableArray *names = [NSMutableArray array];
    for (uint16_t e = 0; e < cdEntries; e++) {
        if (p + 46 > len) break;
        if (R32(bytes + p) != kCentralDirSig) break;
        uint16_t nameLen = R16(bytes + p + 28);
        uint16_t extraLen = R16(bytes + p + 30);
        uint16_t commentLen = R16(bytes + p + 32);
        NSString *n = [[NSString alloc] initWithBytes:(bytes + p + 46) length:nameLen encoding:NSUTF8StringEncoding];
        if (n) [names addObject:n];
        p += 46 + nameLen + extraLen + commentLen;
    }
    return names;
}

+ (NSDictionary<NSNumber *, NSDictionary<NSNumber *, NSString *> *> *)parseRowsAtPath:(NSString *)path
                                                                                error:(NSError **)error {
    NSData *zip = [NSData dataWithContentsOfFile:path];
    if (!zip) {
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取文件"}];
        return nil;
    }

    NSData *ssXml = ZipEntryData(zip, @"xl/sharedStrings.xml");
    NSData *sheetXml = ZipEntryData(zip, @"xl/worksheets/sheet1.xml");
    if (!sheetXml) {
        // 放宽：遍历条目找任意 sheet/worksheet 开头的 xml
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
        if (error) *error = [NSError errorWithDomain:@"WXExcelCopy" code:2 userInfo:@{NSLocalizedDescriptionKey:@"未找到 sheet1.xml"}];
        return nil;
    }

    // sharedStrings
    NSMutableArray<NSString *> *shared = [NSMutableArray array];
    if (ssXml) {
        WXXMLParser *sp = [[WXXMLParser alloc] initWithSharedMode:YES];
        NSXMLParser *xp = [[NSXMLParser alloc] initWithData:ssXml];
        xp.delegate = sp;
        [xp parse];
        shared = sp.sharedStrings;
    }

    // sheet1
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
}

+ (NSArray<NSString *> *)columnLinesAtPath:(NSString *)path
                                    column:(NSInteger)col
                                   fromRow:(NSInteger)row
                                     error:(NSError **)error {
    NSDictionary *rows = [self parseRowsAtPath:path error:error];
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

+ (NSDictionary<NSNumber *, NSNumber *> *)columnCountsAtPath:(NSString *)path error:(NSError **)error {
    NSDictionary *rows = [self parseRowsAtPath:path error:error];
    if (!rows) return nil;
    // 非空计数：parseRowsAtPath 已 trim，非空才入库（数字/点/符号都算内容；纯空格算空白被剔除）
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSNumber *r in rows) {
        NSDictionary *rowDict = rows[r];
        for (NSNumber *c in rowDict) {
            NSString *v = rowDict[c];
            if (v.length > 0) {
                NSNumber *prev = counts[c];
                counts[c] = @(prev.integerValue + 1);
            }
        }
    }
    return counts;
}

@end
