# 📚 zlibx

<div align="center">

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white)
![Android](https://img.shields.io/badge/Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Open Source](https://img.shields.io/badge/开源-❤️-green?style=for-the-badge)
![License](https://img.shields.io/badge/License-AGPL--3.0-green?style=for-the-badge)

**精简的纯安卓电子书阅读器 —— 仅 64 位，无 AI 功能，无微信读书**

**第三方客户端 • 仅提供前端界面 • 数据来自外部源**

[下载 APK](https://github.com/minglaiyo/zlibx/releases) • [报告问题](../../issues) • [功能建议](../../issues)

**[English](README.md)** | **简体中文** | **[日本語](README_JA.md)** | **[한국어](README_KO.md)**

</div>

---

> ⚠️ **免责声明**: zlibx 是一个独立的开源第三方客户端，**不是**官方客户端，与任何官方服务无关。本项目仅提供前端界面，所有书籍数据来自外部源。请谨慎使用。
>
> **与上游不能共存**：zlibx 沿用了上游的包名（`com.open_library.app`），所以**不能和 shiyi-0x7f/olib-mobile 同时安装**，也不能覆盖安装上游的包（签名不同）。想试 zlibx 请先卸载上游应用。

## ✨ 功能特点

| 功能 | 说明 |
|------|------|
| 📖 **书籍搜索** | 支持书名、作者、ISBN 等多种搜索方式 |
| 🌙 **夜间模式** | 护眼阅读体验 |
| 🌍 **多语言** | 支持 5 种语言，包括中文、英文、日文、韩文 |
| 🔐 **多账号** | 支持多账号切换，轻松管理 |
| 🔗 **多线路** | 多个服务器线路可选 |
| 🆓 **完全免费** | 无广告、无订阅、无隐藏费用 |

## ✂️ 关于本精简版

zlibx 是 shiyi-0x7f/olib-mobile 的魔改版：
- 仅安卓，仅 64 位（`arm64-v8a`）
- 已去除 AI 功能（寻书、AI 搜索、后端鉴权）
- 已去除微信读书
- 原私有插件已在本仓库内重写

## 📱 截图

<div align="center">
<i>即将推出...</i>
</div>

## 🚀 快速开始

### 环境要求

- Flutter SDK 3.10+
- Android Studio / VS Code
- Android 设备或模拟器

### 安装步骤

```bash
# 克隆仓库
git clone https://github.com/minglaiyo/zlibx.git

# 进入项目目录
cd zlibx

# 安装依赖
flutter pub get

# 运行应用
flutter run
```

### 构建 APK

```bash
flutter build apk --release --target-platform android-arm64
```

## 🏗️ 项目结构

```
lib/
├── constants/      # 常量
├── core/           # 核心逻辑（书籍数据、线路）
├── l10n/           # 多语言文件 (5 种语言)
├── models/         # 数据模型
├── providers/      # 状态管理 (Riverpod)
├── routes/         # 路由导航
├── screens/        # 界面
├── services/       # API 和存储服务
├── theme/          # 主题配置
├── utils/          # 工具函数
└── widgets/        # 可复用组件

vendor/
└── olib_api_plugin/  # 原私有插件的仓库内重写
```

## 🛠️ 技术栈

- **框架**: Flutter
- **状态管理**: Riverpod
- **本地存储**: Hive
- **网络请求**: Dio（http 包仅用于搜索建议和更新检查）
- **多语言**: 5 种语言

## 🤝 贡献指南

欢迎贡献代码！请随时提交 Pull Request。

1. Fork 本项目
2. 创建功能分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 发起 Pull Request

## 📄 许可证

本项目采用 GNU Affero 通用公共许可证 v3.0（AGPL-3.0）- 详见 [LICENSE](LICENSE) 文件。源自 shiyi-0x7f/olib-mobile 的部分仍采用 MIT 许可证（已保留在 LICENSE 文件中）。

> ⚠️ **法律声明**: 
> - 这是一个独立的第三方客户端，**非**官方应用
> - 所有书籍数据来自外部源，本项目仅提供前端界面
> - 用户须自行确保使用符合相关法律法规
> - 使用本软件即表示您了解并接受以上条款

## 💖 致谢

- 基于 shiyi-0x7f/olib-mobile（MIT）精简修改
- 安娜 / LibGen 书源来自 warreth/OpenlibExtended（AGPL-3.0）
- 💙 Flutter 框架
- ❤️ 开源社区

---

<div align="center">

**[⬆ 返回顶部](#-zlibx)**

开源 • 永久免费

</div>
