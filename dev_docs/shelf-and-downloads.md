# 收藏与本地下载

## 我的图书馆（收藏页）

页面标题为「我的图书馆」（`shelf_title`，五种语言）。该页只展示 Z-Library 收藏，不再提供二维码、口令、文件的书单导入/分享入口，也没有来源筛选。

- `unifiedShelfProvider` 汇总图书馆收藏。
- 图书馆收藏使用 `getUserSaved(page, limit)` 分页加载；加载失败时顶部显示重试横幅。
- 搜索、排序、网格/列表切换（顶栏按钮）和分类筛选仅改变当前页面展示，不修改远端收藏。
- 默认视图按响应式列数把真实藏书摆在连续木质层板上；搜索、筛选、分类和排序放在同一套书柜背板与侧框内，每本书的封面朝前，分类名称写在封面标签上，书名和作者显示在层板前缘。列表模式使用连续书柜背板与薄木层板，左侧展示立体小封面，右侧按书名、作者和横向状态标签排列。
- 用户分类保存在本机 Hive `settings` box 的 `shelf_categories_v1` 键中。一个书籍至多属于一个自定义分类，分类键采用 `library:<id>`。重命名保留归属；删除分类时，书籍变为未分类，不删除远端书籍。分类当前不会跨设备同步。
- 轻点书籍打开详情；长按图书馆书籍进入多选整理，选中状态由封面边框和缓慢呼吸的绿色光晕表示（系统关闭动画时保持静态光晕），底栏集中提供分类和批量移出收藏。批量移出收藏时逐本调用取消收藏接口，全部处理完后只刷新一次收藏列表（`SavedBooksNotifier.unsaveBooks`）。书籍封面不显示常驻三点菜单。

## 本地下载页

- “进行中”包含准备、下载、失败和取消状态；“已完成”只包含有完成记录的任务。点击已完成书籍前再次检查文件是否存在，缺失时转为失败。
- 任务保存下载时间和实际文件大小供列表显示；既有历史记录从 `downloadTime` 和本地文件读取这些信息。
- 普通账号下载可在保留完整书籍信息时重试。使用一次性签名链接的下载需要回原书页重新获取链接；从历史恢复但文件缺失的记录只支持移除。
- 新下载先写入临时文件，成功后移到最终文件名；取消或失败后清理临时文件。删除已完成任务会删除设备上的文件和下载记录。

## 断点续传与下载提速（2026-11-15）

两条下载线共用 `DownloadRange` 的判定：外部直链走 `ResumableDownloader`，z 站走插件里的 `ZLibraryDownloads._downloadOnce`。能不能接着已经落地的字节继续写，按下面顺序决定：

- 首次下载把响应里的 ETag（没有则 Last-Modified）记在 `<part>.meta`，续传时当 `If-Range` 发回去；远端换了文件会答 200 全量，于是从头重写。
- 没记到验证符（线路两个头都不发，或者 .part 早于 1.6.0）照样续传：只发 `Range`，偏移由响应自己证明——206 的 `Content-Range` 必须正好从我们的偏移开始；这个头缺失或读不出时，只有 `If-Range` 被服务器接受才算证明。1.6.0 曾把“没有验证符”当成不可信而丢掉偏移，而 MediaStore 条目只能重建，于是暂停、重试、重启 App 都要重下整本书——这就是“下载变得好慢”的来源。
- 下载收尾不再要求文件头必须是 PK / `%PDF` / `BOOKMOBI`，只否掉两样确定的东西：HTML 验证页或错误页，以及与扩展名签名对不上（epub/zip、pdf、mobi/azw、fb2、djvu）。txt、rtf 这类没有固定魔数的格式一律放行——误判会把已经传完的书整本扔掉重来，代价比放过一个坏文件大得多。
- 416 且 `Content-Range: bytes */N` 的 N 等于偏移时，说明上一次其实已经下完（只是没来得及删 .meta），保留文件收尾；N 小于偏移才清空重来。
- 解析下载链接的探测请求只看响应头：拿到状态码和 Content-Type 后立刻取消 token，不再 `drain` 响应体。`drain` 会把整本书先完整传一遍，下载引擎再要一遍，一次下载等于两倍流量，慢线上看起来就像“点下载后卡住”（2026-11-15 perf）。不能改成复用探测流：那是没带 `Range` 的 200，续传偏移就没了。

回归见 `test/services/plugin_network_test.dart`（download engine 一组、“链接探测不重复传书”一条）、`test/services/resumable_downloader_test.dart` 和 `test/services/download_range_test.dart`。

## 分类树共享与本地收藏（2026-11-19，方案 C）

分类树全 app 一份（Hive `shelf_categories_v1`，书架建的分类下载页直接可用），assignments 表按 `categoryKey` 命名空间混存：

- `library:<id>` — z站收藏（书架）；`local:<id>` — 本地收藏（书架）；`download:<bookId>` — 已完成下载（下载页）。任务 id 就是 bookId（历史条目按 bookId 存），删除下载记录不清归属，重新下载回来还在原分类里。

### 本地收藏（外部源）

- Anna/LibGen 的书进不了 z站收藏体系：长按快捷面板给外部源一个「收藏到本地」，汇进「我的图书馆」与站内收藏同屏（`ShelfSource.local`）。
- 序列化的是 `BookData` 整体（含 `link`）：详情页从收藏打开时重建带 original 的 DisplayBook——`_ExternalBookDetail` 强解包 `asAnnaBookData/asLibgenBookData`，详情 URL 用 `bookData.link`，不能用 md5 现拼。存储键 `external_collection_v1`（settings box 内一个 JSON 数组，与书架分类同一模式：条目少、全量重写、落盘失败不丢内存态）。
- 书架里本地收藏条目：点击进详情、长按单书弹层（归类/移出本地收藏）；不进选择模式（无站内数字 id），批量整理只对 z站条目生效。

### 书架备份/导入（C3）

- 入口：书架 AppBar「管理分类」弹层底部「导出/导入书架数据」。内容 = 分类 + assignments + 本地收藏，`version: 1`。
- 导出走系统分享面板（临时 JSON 文件）；导入用 file_picker 13.x（`pickFiles` 直接返回 `List<PlatformFile>`，字节走 `readAsBytes()`，旧版 `withData/bytes` 已删）。
- 合并语义：分类按名字去重（同名沿用本机 id），分配关系按"导入分类 id → 本机 id"映射后逐键落键（`assignEntries` 先整体校验再写），本地收藏按 来源+md5 去重。键指向的书不在本机也无妨，语义只是归属关系。

### 下载页分类（C1）

- 「已完成」Tab 顶部加分类 chips（全部/未分类/各分类 + 计数），条目三点菜单加「加入分类」(`showKeysCategoryPicker`)。新建/改名仍在书架「管理分类」，下载页只消费同一棵树。
- 进行中 Tab 不做分类（任务还没落地，归类意义在成品）。

回归见 `test/providers/local_collection_persistence_test.dart`、`test/providers/shelf_categories_keys_test.dart`、`test/widgets/downloads_category_filter_test.dart`、`test/widgets/quick_actions_local_test.dart`。

**testWidgets 的 Hive 纪律（三次挂死换来的完整表述）**：FakeAsync 区里测试体绝不能 await 任何 Hive 写操作（clear/put 的真实文件 I/O 完成事件进不了假时钟区，future 永不完成，用例挂满超时）；widget 回调里的 put 随它挂（内存值立即可见）。需要"写后回调"类断言（如排在 `await add` 之后的 snack）时用 `tester.runAsync` 给真实 I/O 开窗口。持久化类测试一律走普通 `test()` + ProviderContainer。
