# WXExcelCopy — 微信 xlsx 预览左侧列统计栏

TrollFools 注入型 dylib（微信 8.0.78，iOS 15+，arm64）。

## 功能
在微信的 xlsx 文件预览页，表格**左侧悬浮竖向统计栏**：

- 每列一个条目，三行显示：`A列`（加粗） / `数量`（非空单元格数） / `表头中文`（最多 4 字，超出省略号）
- 点击条目 → 复制**该列整列数据**（含表头行，从第 1 行开始），换行拼接，粘贴进 Excel 仍是同一列
- 复制后 Toast 提示：`复制A1-A100共100条`
- 数据直接解析**沙盒里的 xlsx 文件本体**（全量行列），不受微信预览"仅渲染前 ~200 行"限制

## 原理
1. hook 微信文件预览控制器 `FileDetailWebPreviewController` + 通用 `WKWebView` 加载探测（`WebViewProbe`），双层保障注入
2. 注入 JS：`WKUserScript`（`forMainFrameOnly:NO`，主/子 frame 都注入）
   - URL 校验只对主 frame 生效（避免误入微信搜一搜等网页表格）
   - **多 sheet 文件**：表格渲染在 `x-apple-ql-id://` iframe 内（其 URL 不含 `.xlsx`），iframe 内跳过 URL 校验直接注入 → 统计栏正常显示
   - 统计栏锚在**表头第一个单元格**（`absolute + right:100% + top:0`），跟表格走、不被容器裁切、秒显示
3. 原生：扫描微信沙盒（`Documents/<乱码>/OpenData/<乱码>/`）找 xlsx，按时间最新优先 + 预览副本前缀匹配
4. 内置 xlsx 解析器（zip 解包 → `sheet1.xml` + `sharedStrings.xml`，含 zip64 / 边界检查 / 异常兜底）读全量数据
5. 取该列从第 1 行到末尾 → 换行拼接 → 写剪贴板 → Toast

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
3. 打开任意 xlsx 预览 → 左侧统计栏出现 → 点击条目自动复制整列

## 风险
- 微信对注入有风控/检测，登录支付可能受限，自用自担
- 微信版本更新后类名可能变化，需要同步适配
