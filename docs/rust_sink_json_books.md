# JSON 解析器下沉 + P0-2 MD5

## 概述

本次将最后一个未下沉的 CPU 密集热路径 —— eapi 书列表 JSON 解码（`_booksOf` + `Book.fromJson`）—— 迁移到 Rust，并新增 MD5 hex 工具模块。这是继 HTML 解析器全部下沉之后的收尾工作。

## 为什么是 `_booksOf`

HTML 解析器（fulltext / article / book_detail / booklist×3 / category / download_stats / annas×2 / libgen×2 / openlibrary）此前已全部通过 FRB hook 下沉。唯一剩下的同步重解析路径是 **JSON → Book 映射**：

```dart
// vendor/olib_api_plugin/lib/src/zlibrary_api.dart
static List<Book> _booksOf(Map<String, dynamic> json) { ... }  // 每个 feed 都跑
// 内部对每本书调用 Book.fromJson（~30 字段 + 多个 helper）
```

它被 search / getMostPopular / getUserRecommended / getRecently / getUserSaved / getUserDownloaded / similar 共 7 个 feed 端点调用，是真正的热路径。

## 架构

遵循 CLAUDE.md 的 hook 约定（Dart parser 保留为 fallback，缺 `.so` 静默降级）：

```
Dio (ResponseType.plain)
   └─ _rawFromResponse: 保留 raw body 文本（新增）
        └─ booksOfH(json, rawBody:)          ← 新异步入口
             ├─ booksParseOverride != null → Rust parse_books_json (FRB 线程池)
             └─ 否则 → Dart _booksOf(json)（原同步路径，行为不变）
```

### 关键设计点

1. **原始文本贯穿**：`_Raw` 在成功 JSON 分支也携带 `body`，Rust 侧拿到原始字符串自行 decode+map，避免 Map→String 往返。
2. **fallback 单一来源**：`ZLibraryApiBase.fallbackBooksOf(text)` 复用同一套 `_booksOf`/`Book.fromJson`，桥接失败时走它，绝不漂移。
3. **无效 JSON 不抛异常**：Rust 返回空数组；Dart fallback 用 try-catch 对齐该语义。

## 交付文件

| 文件 | 作用 |
|------|------|
| `rust/zlibx_parsers/src/json_books.rs` | JSON→Book 解析，逐字段复刻 Dart helper（`_asInt`/`_asString`/`_joinAuthor`/`_filesizeString`/`_nonEmptyString`/`_asDateTime`），含无 chrono 的 epoch→ISO 转换 |
| `rust/zlibx_parsers/src/hash_utils.rs` | MD5 hex（md-5 crate，已在依赖树中） |
| `rust/zlibx_parsers/Cargo.toml` | 新增 `serde_json = "1"`、`md-5 = "0.10"`、`hex = "0.4"` |
| `rust/zlibx_parsers/src/lib.rs` | `#[frb] parse_books_json` + `#[frb] md5_hex` 导出 |
| `lib/core/rust_books.dart` | hook 注入模块（懒初始化 + 优雅降级） |
| `vendor/.../zlibrary_api.dart` | `booksParseOverride` hook + `booksOfH` + `fallbackBooksOf` + raw body 保留 |
| `vendor/.../zlibrary_search.dart` | 6 处 `_booksOf` 调用迁移到 `await booksOfH(...)` |
| `test/services/json_books_test.dart` | 27 个差分测试（Dart baseline 契约） |

## 语义对齐细节

Rust 实现严格匹配 Dart 的边界行为，差分测试逐一锁定：

- **id**：缺失/不可解析 → 0；double 向零截断（`7.9 → 7`）；字符串数字解析
- **hash**：显式 `hash`/`hashId` 优先；空串不遮蔽 href 派生；href 非 `/book/{hash}/` 形态 → null
- **author/categories**：列表以 `", "` 连接；categories 空列表归一化为 null（author 保留 Dart 的空串语义）
- **filesizeString**：显式字段优先，否则按 B/KB(1位)/MB(2位)/GB(2位) 二进制单位格式化
- **可选字段**：空串归一化为 null；snake_case 别名（`isbn_13`/`read_online_url`/`interest_score`/`ipfs_cid`）同样映射
- **downloadedAt**：ISO 串直通；epoch 秒/毫秒转 ISO；`<=0` 或超界值 → null

## P0-2 MD5 的范围说明

诚实记录：项目中唯一的 md5 相关代码是 `externalBookId`（把已知 md5 串折叠成稳定 int），那是 O(8) 纯计算，路由到异步 FRB 反而更慢，因此**故意留在 Dart**。

`hash_utils.md5_hex` 面向的是未来真正需要的场景——大文件字节哈希（完整性校验、Anna's Archive donation-key 验证），这类工作在 Dart `crypto` 下会阻塞 UI isolate，Rust 路径则在 FRB 线程池离线程执行。当前作为可用 API 提供，暂无调用点。

## 验证结果

```
cargo test --release        → 97 passed, 0 failed
flutter test (全量)         → 813 passed, 0 failed（零回归）
flutter analyze             → No issues found!
json_books_test.dart        → 27 passed（差分契约）
```

## 生成的绑定（已提交）

- `lib/frb_generated.dart`（3921 行）
- `lib/lib.dart`（358 行，新增 `parseBooksJson` / `md5Hex`）
- `lib/hash_utils.dart`（FRB 子输出）
- `rust/zlibx_parsers/src/frb_generated.rs`（3706 行）

> 注意：CLAUDE.md 说生成文件"已提交"指的是上游仓库；本工作副本来自 zip 解压，生成文件随 codegen 重新产出，需与 `#[frb]` 改动一起提交。

## 收益预期

- 单次搜索/推荐 feed 的 ~20–50 本书 JSON 解码从 UI isolate 移到 Rust 线程池
- 消除大列表页首帧后的解码卡顿
- 与既有 HTML 解析共用同一 FRB 引擎（`ensureRustBridge()` 单例），无额外初始化成本
