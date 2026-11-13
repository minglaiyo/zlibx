# 包名与命名迁移评估（M5）

> 评估，不是执行计划。包名至今未改；改包名是一次性大版本变更，
> 做之前先读完这篇。审查原文：`zlibx-2.md` §M5。

## 现状

| 项目 | 当前值 | 位置 |
| --- | --- | --- |
| `applicationId` / `namespace` | `com.open_library.app` | `android/app/build.gradle.kts` |
| MainActivity 包名 | `com.open_library.app` | `android/app/src/main/kotlin/com/open_library/app/MainActivity.kt` |
| vendor 插件包名 | `olib_api_plugin` | `vendor/olib_api_plugin/`，`lib/` 内几十处 `import 'package:olib_api_plugin/…'` |
| LAN token 请求头 | `X-Olib-Token`（只在注释里，S5 已确认无调用方实际发送） | `lib/providers/download_engine.dart` |
| 下载暂存目录名 | `…/Android/data/<pkg>/files/Olib` | `lib/providers/download_paths.dart` |
| 工作流 / 图标文件名 | `oliblite-build-android-arm64.yml`、`olib-app-logo.png` | `.github/workflows/`、`tool/icons/` |

包名与上游 olib-mobile 完全一致。签名是道明自己的 keystore，
与上游不同——于是：

- 装了上游 olib-mobile 的手机**装不上 zlibx**（同包名、签名不同，
  Android 拒绝覆盖安装），反过来也一样；
- 两者**不能共存**（同包名只能装一个）。

## 改包名要改什么（机械部分）

新包名建议 `com.minglaiyo.zlibx`（与 GitHub 账号 / 仓库名一致，
避免再撞上游或别的 fork）。改动点：

1. `android/app/build.gradle.kts`：`namespace` 与 `applicationId`。
2. `android/app/src/main/kotlin/com/open_library/app/MainActivity.kt`：
   包声明 + 目录改名 `com/minglaiyo/zlibx/`。
3. `android/app/src/main/AndroidManifest.xml`：`package` 属性由
   `namespace` 派生，一般不用手改，但要核对。
4. README / dev_docs 里写死的包名（如果有）。
5. CI 工作流文件名可以不动（只是个名字），但顺手改名更干净。

以上是纯机械改名，CI 的 `flutter build apk` 能直接验证编译。

## 数据影响（这才是难点）

改 `applicationId` 等于换了一个应用身份。Android 按包名隔离：

| 数据 | 改包名后 | 说明 |
| --- | --- | --- |
| 已下载的书（公共 `Downloads/zlibx/`） | **保留** | MediaStore 公共目录，不跟包名走；历史记录里的 `content://` 路径仍可打开 |
| Hive（设置、账号、书单缓存、浏览历史） | **丢失** | 在应用专属目录（按包名），新包名是全新的空目录 |
| `flutter_secure_storage`（登录 token、Anna 捐赠 key） | **丢失** | Android Keystore 按包名隔离；新包读不到旧包的密钥 |
| 下载暂存（`…/files/Olib` 下的 `.part`） | **丢失**（可重下） | 应用专属目录，随旧包卸载清除；未完成的分片要重下 |
| 阅读器 WebView 的登录态 / cookie | **丢失** | 跟应用数据走，需重新登录、重新过验证 |

也就是说：**用户要卸载旧包、装新包、重新登录、重新填 Anna 捐赠 key，
书单缓存和浏览历史全部重建；只有已经下好的书还在。**

### 迁移路径（如果决定改）

- 方案 A（推荐）：**不做自动迁移**。发一个大版本（例如 v1.6.0 或 v2.0.0），
  Release 说明里写清：旧包卸载、新包装、重新登录、重新填捐赠 key，
  已下载的书不受影响。用户量小、操作一次，简单可靠。
- 方案 B（自动迁移）：新包首次启动时读旧包数据——Android 不允许
  跨包读应用专属目录和 Keystore，只能走 `ContentProvider` + 旧包配合
  导出，两个包要同时发版、旧包先发一个带导出功能的版本。复杂度高，
  不值得。
- 无论哪种：**先发一个版本把 `Downloads/zlibx` 里的书和导出说明写清楚**，
  再改包名；不要在同一个版本里既改包名又改别的。

## `Olib` 命名清理（与包名无关，可单独做）

- `olib_api_plugin` → 改名要动 `vendor/olib_api_plugin/pubspec.yaml` 的
  `name` 和全仓库的 import（几十处），纯机械，但改完要全量回归
  （import 改名 CI 能验）。
- `X-Olib-Token` → 只在注释里，改注释即可（S5 已确认无实际发送）。
- 暂存目录 `Olib` → 改成 `zlibx`，一行；旧目录的 `.part` 残留随旧包
  卸载清除，不用处理。
- 工作流 / 图标文件名 → 只是名字，随意。

这几项不改包名也能做，风险低；但**不要和包名迁移混在同一个版本里**，
免得出问题分不清是谁的锅。

## 建议

1. **先不改包名。** 用户量小、一直在 GitHub 直装，撞上游的概率低；
   改包名的代价（全员重新登录 + 丢缓存）比收益大。
2. **至少在 README 里说明与上游不能共存**（审查原文的要求）。
   已加：`README.md` 与 `README_ZH.md` 的 Disclaimer 附近。
3. 如果以后要改：选一个大版本（v1.6.0 / v2.0.0），按上表走方案 A，
   Release 说明写清迁移步骤；`Olib` 命名清理单独一个版本先做。
