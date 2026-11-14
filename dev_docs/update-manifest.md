# 更新清单（强制更新 + 下载渠道）

> 2026-10-09 引入，1.4.0 起生效，格式与桌面端 OlibTauri 一致。
> 实现：`lib/services/update/update_manifest.dart`（解析）、`lib/providers/update_provider.dart`（检查 + 缓存）、
> `lib/widgets/update_dialog.dart`（对话框）。

客户端请求公开仓库最新 Release（`api.github.com/repos/minglaiyo/zlibx/releases/latest`），
解析 Release 正文末尾的**隐藏注释**（GitHub 页面上不可见）：

```text
<!-- olib-update
min_version: 1.4.0
百度网盘: https://pan.baidu.com/s/xxxx?pwd=xxxx
夸克网盘: https://pan.quark.cn/s/xxxx?pwd=xxxx
迅雷网盘: https://pan.xunlei.com/s/xxxx?pwd=xxxx
-->
```

| 行                   | 含义                                                                                     |
| -------------------- | ---------------------------------------------------------------------------------------- |
| `min_version: x.y.z` | 当前版本**低于**它 → 强制更新。省略 = 不强制                                             |
| `名称: 链接`         | 对话框里的下载渠道，按书写顺序排列，第一个为主按钮。**仅 https 且域名须在白名单内**（见下），名称 ≤ 20 字，最多 8 个 |
| `[FORCE]`            | 旧标记（≤1.3.0 客户端只认它）：比最新版低的客户端一律强制。**必须独占一行**（行内提及，如“移除了 [FORCE] 标记”，不触发）。新发版优先用 `min_version`    |

- 对话框总会追加「官网下载」（本项目 Releases 页）和「GitHub」（Release 页）两个兜底渠道。
- 强制更新时：对话框不可关闭，搜索与下载被拦截（`updateProvider.isBlocked`）。
  但这是一把**远程熔断开关**，不是要把用户锁在应用外：对话框上有逃生口，
  随时可以打开**已下载的书**和**设置页**；搜索与新下载仍被拦截，冷启动时
  对话框还会再出现。

## 链接域名白名单

清单是 Release 正文里的纯文本；为防止仓库/账号被入侵后下发任意链接，只接受
`UpdateManifest.allowedLinkHosts` 中的域名（及其子域）：`pan.baidu.com`、`pan.quark.cn`、
`pan.xunlei.com`、`github.com`。含 `user@host` 形式、`http://`、或后缀仿冒（`pan.baidu.com.evil.com`）
的链接会被丢弃，但不会静默丢：客户端会在更新对话框里提示忽略了几个渠道，被忽略的
渠道名也会记在更新检查的日志里。**要用新的网盘，先在代码里加域名并发版，再在 Release 里写链接。**
注意这个循环：需要新网盘的那个版本本身还发不出带它的链接，要等下一个版本才能用上。
对话框里每个渠道按钮都会显示真实域名。

`github.com` 只有域名不够：只放行本仓库的路径（`github.com/minglaiyo/zlibx` 及其子路径，
如 `/releases`、`/releases/download/…`）。其他仓库、gist、子域名一律丢弃——否则入侵者
只需改一行 Release 正文，就能把强制更新的对话框指向自己仓库的 APK。

## 版本比较

`isNewerVersion` 按语义化版本比较：先比数字核心，再比预发布后缀，最后比 build 号。
同版本高 build 号也算更新（`1.5.8+10509` > `1.5.8+10508`），热修复重发才能触达用户；
预发布版低于同版本正式版（`1.5.8-beta` < `1.5.8`）。

## 缓存与检查频率

- 首页每 24h 请求一次（登录页、设置页「检查更新」每次都请求）。
- 每次请求成功后把 tag / 正文 / Release 链接写入 Hive `settings` box（`update_cached_*`）；
  跳过请求或请求失败时用缓存重新计算，**强制更新在重启后依然生效**。
- 从未成功请求过（无缓存）且检测失败 → 放行。

## 兼容旧客户端

≤1.3.0 只认正文中的 `[FORCE]`，且会把整段正文（含注释块）原样显示在对话框里。
需要强制旧客户端时，把 `[FORCE]` 写进注释块内（GitHub 页面看不到），并接受旧客户端会看到清单原文。

## 发版时怎么写

1. CI 构建完成后，PanSync 把 APK 上传到网盘（见 [refs/pansync.md](refs/pansync.md)），拿到分享链接。
2. 写好 notes（面向用户），末尾追加清单块，`gh release edit vX.Y.Z -R minglaiyo/zlibx --notes-file <文件>`。
3. **只在必要时设置 `min_version`**（旧版接口失效、安全问题等），平时只写网盘链接。
