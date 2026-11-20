import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 第三方镜像页后台 WebView 的安全基线（审查 2026-11-21 5.4）：与阅读
/// 器（reader_screen，同一个信任级别上跑镜像页并已验证）对齐——不放开
/// 本地文件/内容访问，混合内容禁止。挑战页（Cloudflare/DDoS-Guard）与
/// Anna 慢速下载倒计时页都不需要这些能力。
///
/// 刻意未收紧的两项（需真机回归后再说）：
///  * `shouldOverrideUrlLoading` 的 https-only：挑战页的跳转链形态各
///    家镜像不同，收错一根就把恢复链路静默打断；
///  * 其它能力开关逐项最小化：等 flutter_inappwebview 升级后按新版
///    默认值重新盘点。
final InAppWebViewSettings kThirdPartyWebViewSettings = InAppWebViewSettings(
  javaScriptEnabled: true,
  supportZoom: false,
  allowFileAccess: false,
  allowContentAccess: false,
  mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
);
