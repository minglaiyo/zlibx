# 📚 zlibx

<div align="center">

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white)
![Android](https://img.shields.io/badge/Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Open Source](https://img.shields.io/badge/Open%20Source-❤️-green?style=for-the-badge)
![License](https://img.shields.io/badge/License-AGPL--3.0-green?style=for-the-badge)

**A slim, Android-only ebook reader — 64-bit, no AI features, no WeRead**

**Third-party client • Frontend interface only • All data from external sources**

[Download](https://github.com/minglaiyo/zlibx/releases) • [Report Bug](../../issues) • [Request Feature](../../issues)

**English** | **[简体中文](README_ZH.md)** | **[日本語](README_JA.md)** | **[한국어](README_KO.md)**

</div>

---

> ⚠️ **Disclaimer**: zlibx is an independent, open-source third-party client. It is NOT an official client and is not affiliated with any official service. This project only provides the frontend interface - all book data comes from external sources. Use at your own discretion.
>
> **Coexistence**: zlibx keeps the upstream package name (`com.open_library.app`), so it **cannot be installed alongside** shiyi-0x7f/olib-mobile, and it cannot overwrite an upstream install (different signing key). Uninstall the upstream app first if you want to try zlibx.

## ✨ Features

| Feature | Description |
|---------|-------------|
| 📖 **Book Search** | Search books by title, author, ISBN, or keywords |
| 🌙 **Dark Mode** | Eye-friendly reading experience |
| 🌍 **Multi-language** | Supports 5 languages including English, 中文, 日本語, 한국어 |
| 🔐 **Multi-Account** | Switch between multiple accounts seamlessly |
| 🔗 **Multi-Domain** | Choose from multiple server lines |
| 🆓 **100% Free** | No ads, no subscriptions, no hidden costs |

## ✂️ About this fork

zlibx is a heavily-modded fork of shiyi-0x7f/olib-mobile:
- Android only, 64-bit (`arm64-v8a`) only
- AI features removed (prescriber, AI search, backend auth)
- WeRead removed
- The original private plugin was rewritten from scratch in this repo

## 📱 Screenshots

<div align="center">
<i>Coming soon...</i>
</div>

## 🚀 Quick Start

### Prerequisites

- Flutter SDK 3.10+
- Android Studio / VS Code
- Android device or emulator

### Installation

```bash
# Clone the repository
git clone https://github.com/minglaiyo/zlibx.git

# Navigate to project directory
cd zlibx

# Install dependencies
flutter pub get

# Run the app
flutter run
```

### Build APK

```bash
flutter build apk --release --target-platform android-arm64
```

## 🏗️ Project Structure

```
lib/
├── constants/      # App constants
├── core/           # Core logic (book data, mirrors)
├── l10n/           # Localization files (5 languages)
├── models/         # Data models
├── providers/      # State management (Riverpod)
├── routes/         # App navigation
├── screens/        # UI screens
├── services/       # API & storage services
├── theme/          # App theme configuration
├── utils/          # Helper utilities
└── widgets/        # Reusable components

vendor/
└── olib_api_plugin/  # In-repo rewrite of the original private plugin
```

## 🛠️ Tech Stack

- **Framework**: Flutter
- **State Management**: Riverpod
- **Local Storage**: Hive
- **HTTP Client**: Dio (package:http only for search suggestions and update checks)
- **Localization**: 5 languages

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0) - see the [LICENSE](LICENSE) file for details. Portions derived from shiyi-0x7f/olib-mobile remain under the MIT License (preserved in the LICENSE file).

> ⚠️ **Legal Notice**: 
> - This is an independent third-party client, NOT an official application
> - All book data comes from external sources; this project provides frontend only
> - Users are responsible for ensuring compliance with applicable laws
> - By using this software, you acknowledge these terms

## 💖 Acknowledgments

- Based on shiyi-0x7f/olib-mobile (MIT), slimmed down
- Anna's Archive / LibGen sources from warreth/OpenlibExtended (AGPL-3.0)
- 💙 Flutter framework
- ❤️ Open source community

---

<div align="center">

**[⬆ Back to Top](#-zlibx)**

Open Source • Free Forever

</div>
