# WXExcelCopy — 微信 xlsx 预览"点击单元格复制本列往下"

TrollFools 注入型 dylib（微信 8.0.78，iOS 15+，arm64）。

## 功能
在微信的 xlsx 文件预览页，**点击任意单元格** → 自动复制**该列从该单元格往下的所有行**（等效 WPS 的 A1→A999），Tab/换行保留原始结构，粘贴进 Excel/表格仍是同一列。

- 不受微信预览"仅渲染前 ~200 行"的限制：数据直接解析**沙盒里的 xlsx 文件本体**（全量行列）
- 点单元格只取"坐标"（第几行第几列），数据从文件取，所以 200 行外的也能复制到底
- 复制后 Toast 提示：`已复制 A1:A999 · 999 行`

## 原理
1. hook 微信文件预览控制器 `FileDetailWebPreviewController`（WKWebView）
2. 注入 JS：捕获 `click` → 从 `td/th` 或 `data-row/data-col` 网格拿行列 → 回调原生
3. 原生：扫描微信沙盒（Documents/Library/tmp）找最近修改的 `.xlsx`
4. 内置 xlsx 解析器（zip 解包 → `sheet1.xml` + `sharedStrings.xml`）读全量数据
5. 取该列从点击行到末尾 → 换行拼接 → 写剪贴板 → Toast

## 诊断
每次打开预览会自动向沙盒 `Documents/wxExcelCopy_log.txt` 追加一条诊断记录
（URL、DOM 表格/td/canvas 数量、首格内容样本），用于适配不同渲染结构。

## 构建
GitHub Actions（macos-latest + Xcode）编译：
```bash
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=15.0 -fobjc-arc \
  -framework Foundation -framework UIKit -framework WebKit -framework CoreGraphics -lz \
  WXExcelCopy/*.m -dynamiclib -o out/WXExcelCopy.dylib
```

## 注入
1. 下载 Actions 产物 `WXExcelCopy.dylib`
2. TrollFools 选择微信 → 注入该 dylib → 重启微信
3. 打开任意 xlsx 预览 → 点击单元格 → 自动复制

## 风险
- 微信对注入有风控/检测，登录支付可能受限，自用自担
- 微信版本更新后类名可能变化，需要同步适配
