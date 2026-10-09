// XLSXParser.h
#import <Foundation/Foundation.h>

@interface XLSXParser : NSObject

// 解析 xlsx 全量数据：行号(1-based) → 列号(1-based) → 值（默认第一个 sheet）
+ (NSDictionary<NSNumber *, NSDictionary<NSNumber *, NSString *> *> *)parseRowsAtPath:(NSString *)path
                                                                                error:(NSError **)error;

// 解析指定 sheet（1-based，sheet1/sheet2/...）全量数据；sheet 不存在返回 nil（error.code==2）
+ (NSDictionary<NSNumber *, NSDictionary<NSNumber *, NSString *> *> *)parseSheetAtPath:(NSString *)path
                                                                            sheetIndex:(NSInteger)index
                                                                                 error:(NSError **)error;

// 列出 zip 内所有条目名（诊断用）
+ (NSArray<NSString *> *)zipEntriesAtPath:(NSString *)path error:(NSError **)error;

// 取 col 列从 row 行往下的所有行值（含中间空行，去掉尾部空行），每行一个元素；
// sheetIndex：1-based，指定从哪个 sheet 取（默认第一个 sheet 用 sheetIndex=1）
+ (NSArray<NSString *> *)columnLinesAtPath:(NSString *)path
                                    column:(NSInteger)col
                                   fromRow:(NSInteger)row
                                sheetIndex:(NSInteger)sheetIndex
                                     error:(NSError **)error;

// 列号 → 字母（1→A, 27→AA）
+ (NSString *)columnLetter:(NSInteger)col;

@end
