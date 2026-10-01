// XLSXParser.h
#import <Foundation/Foundation.h>

@interface XLSXParser : NSObject

// 解析 xlsx 全量数据：行号(1-based) → 列号(1-based) → 值
+ (NSDictionary<NSNumber *, NSDictionary<NSNumber *, NSString *> *> *)parseRowsAtPath:(NSString *)path
                                                                                error:(NSError **)error;

// 取 col 列从 row 行往下的所有行值（含中间空行，去掉尾部空行），每行一个元素
+ (NSArray<NSString *> *)columnLinesAtPath:(NSString *)path
                                    column:(NSInteger)col
                                   fromRow:(NSInteger)row
                                     error:(NSError **)error;

// 列号 → 字母（1→A, 27→AA）
+ (NSString *)columnLetter:(NSInteger)col;

@end
