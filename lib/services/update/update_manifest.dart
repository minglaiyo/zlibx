/// 解析 GitHub Release 正文里的「更新清单」隐藏块（与桌面端 OlibTauri 同格式）。
///
/// 发布时在 Release 正文末尾写一段 HTML 注释（GitHub 页面上不可见）：
///
/// ```text
/// <!-- olib-update
/// min_version: 1.4.0
/// 百度网盘: https://pan.baidu.com/s/xxx?pwd=xxxx
/// 夸克网盘: https://pan.quark.cn/s/xxx?pwd=xxxx
/// -->
/// ```
///
/// - `min_version`：低于此版本的客户端强制更新（可省略 = 不强制）
/// - 其余 `名称: 链接` 行：更新对话框里的下载渠道（仅接受 http/https）
/// - 正文独占一行的 `[FORCE]` / `[FORCE_UPDATE]`：旧版强制更新标记，仍兼容
///   （行内提及，如“移除了 [FORCE] 标记”，不再触发；见 [_forceRe]）。
///   新版发布优先用 `min_version`。
///
/// 格式说明见 `dev_docs/update-manifest.md`。
library;

class UpdateLink {
  final String name;
  final String url;

  const UpdateLink(this.name, this.url);
}

class UpdateManifest {
  final String? minVersion;
  final List<UpdateLink> links;

  /// Names of `名称: 链接` lines that were dropped (non-https, host off
  /// the allow-list, name too long, or over the link cap). The update
  /// dialog warns about the count instead of silently dropping them.
  final List<String> droppedLinkNames;

  /// How many link lines were dropped (see [droppedLinkNames]).
  int get droppedLinkCount => droppedLinkNames.length;

  /// 正文有独占一行的 `[FORCE]` 标记：比最新版低的客户端一律强制更新
  final bool forceAll;

  /// 去掉清单块与强制标记后的正文，用作更新说明
  final String notes;

  const UpdateManifest({
    this.minVersion,
    this.links = const [],
    this.droppedLinkNames = const [],
    this.forceAll = false,
    this.notes = '',
  });

  static const _blockStart = '<!-- olib-update';
  static const _blockEnd = '-->';
  static const _maxLinks = 8;

  /// Hosts a release-notes link may point to (exact host or a subdomain).
  /// The manifest is plain text in a GitHub Release body; if the repo or
  /// the publishing account were ever compromised, an attacker could
  /// otherwise push ANY https link into the update dialog (and into a
  /// forced, app-blocking update). Add a netdisk here when you start
  /// using it in a release — an unknown host is dropped and counted in
  /// [droppedLinkCount] so the dialog can warn about it.
  ///
  /// `github.com` is narrower than a host entry: only this repo's paths
  /// (see [isAllowedLink]) — a compromised Release body must not be
  /// able to point the dialog at another account's releases.
  static const allowedLinkHosts = <String>[
    'pan.baidu.com',
    'pan.quark.cn',
    'pan.xunlei.com',
    'github.com',
  ];

  /// Whether [url] is https AND on an allow-listed host.
  ///
  /// `github.com` only passes for this repo's paths
  /// (`github.com/minglaiyo/zlibx/...`); any other repo, gist or
  /// subdomain is dropped, so a compromised Release body cannot point
  /// the update dialog at someone else's releases.
  static bool isAllowedLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    if (uri.userInfo.isNotEmpty) return false; // https://good.com@evil.com
    final host = uri.host.toLowerCase();
    if (host == 'github.com' || host.endsWith('.github.com')) {
      return host == 'github.com' && _isThisRepoPath(uri.path);
    }
    return allowedLinkHosts.any((h) => host == h || host.endsWith('.$h'));
  }

  /// `github.com/minglaiyo/zlibx` itself or anything under it
  /// (`/releases`, `/releases/download/…`, …). GitHub resolves repo
  /// paths case-insensitively, so compare lowercased.
  static bool _isThisRepoPath(String path) {
    const repo = '/minglaiyo/zlibx';
    final p = path.toLowerCase();
    return p == repo || p.startsWith('$repo/');
  }
  static const _maxNameChars = 20;
  // [FORCE] 只认独占一行的标记（multiLine + ^...$）：正文里行内提及
  // “移除了 [FORCE] 标记”之类的措辞不再误触发强制更新。发布时若要
  // 强制更新，把 [FORCE] 单独写一行（或用 min_version）。
  static final _forceRe = RegExp(
    r'^\s*\[FORCE(_UPDATE)?\]\s*$',
    caseSensitive: false,
    multiLine: true,
  );

  factory UpdateManifest.parse(String body) {
    String? minVersion;
    final links = <UpdateLink>[];
    final droppedLinkNames = <String>[];
    var notes = body;

    final start = body.indexOf(_blockStart);
    if (start >= 0) {
      final contentStart = start + _blockStart.length;
      final endIdx = body.indexOf(_blockEnd, contentStart);
      final contentEnd = endIdx >= 0 ? endIdx : body.length;
      final blockEnd = endIdx >= 0 ? endIdx + _blockEnd.length : body.length;

      for (final line in body.substring(contentStart, contentEnd).split('\n')) {
        final kv = _splitKeyValue(line);
        if (kv == null) continue;
        final (key, value) = kv;
        if (key.toLowerCase() == 'min_version') {
          final v = value.startsWith('v') ? value.substring(1) : value;
          if (v.isNotEmpty) minVersion = v;
        } else if (_isHttpsUrl(value) &&
            isAllowedLink(value) &&
            key.isNotEmpty &&
            key.runes.length <= _maxNameChars &&
            links.length < _maxLinks) {
          links.add(UpdateLink(key, value));
        } else if (key.isNotEmpty && _looksLikeUrl(value)) {
          // A link line that was not accepted (non-https, host off the
          // allow-list, name too long, or over the link cap). Record the
          // name only — the URL may carry a ?pwd= code — so the update
          // dialog can warn instead of silently dropping it.
          droppedLinkNames.add(key);
        }
      }
      notes = body.substring(0, start) + body.substring(blockEnd);
    }

    return UpdateManifest(
      minVersion: minVersion,
      links: links,
      droppedLinkNames: droppedLinkNames,
      forceAll: _forceRe.hasMatch(body),
      notes: notes.replaceAll(_forceRe, '').trim(),
    );
  }

  /// 在第一个半角或全角冒号处切分（链接里的 `https:` 在其后，不受影响）
  static (String, String)? _splitKeyValue(String line) {
    final trimmed = line.trim();
    final idx = trimmed.indexOf(RegExp('[:：]'));
    if (idx < 0) return null;
    return (
      trimmed.substring(0, idx).trim(),
      trimmed.substring(idx + 1).trim(),
    );
  }

  /// Update-channel links must be https: an http:// link can be hijacked
  /// by a middlebox onto a malicious download page.
  static bool _isHttpsUrl(String s) =>
      s.startsWith('https://') && !s.contains(RegExp(r'\s'));

  /// Whether [s] looks like a link attempt at all (http or https). Used
  /// only to decide whether a rejected line counts as a dropped link.
  static bool _looksLikeUrl(String s) {
    final lower = s.toLowerCase();
    return (lower.startsWith('http://') || lower.startsWith('https://')) &&
        !s.contains(RegExp(r'\s'));
  }
}

/// 语义化版本比较：`latest` 是否比 `current` 新。
///
/// 先比数字核心（`1.5.8`），再比预发布后缀，最后比 build 号：
/// - `1.5.9` > `1.5.8`；`1.5.8+10509` > `1.5.8+10508`（同版本高 build
///   号也算更新，热修复重发才能触达用户）。
/// - 预发布版低于同版本正式版：`1.5.8-beta` < `1.5.8`；
///   `1.5.8-beta.2` > `1.5.8-beta.1`。
/// - 核心里的非数字段按 0 计（保持旧的宽容行为）。
bool isNewerVersion(String latest, String current) =>
    _compareVersions(latest, current) > 0;

/// Like [Comparable.compareTo]: <0 if [a] is older, 0 if equal, >0 if newer.
int _compareVersions(String a, String b) {
  final (aCore, aPre, aBuild) = _splitVersion(a);
  final (bCore, bPre, bBuild) = _splitVersion(b);
  final n = aCore.length > bCore.length ? aCore.length : bCore.length;
  for (var i = 0; i < n; i++) {
    final av = i < aCore.length ? aCore[i] : 0;
    final bv = i < bCore.length ? bCore[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  // Pre-release: a version without one is newer than the same core with one.
  if (aPre == null && bPre != null) return 1;
  if (aPre != null && bPre == null) return -1;
  if (aPre != null && bPre != null) {
    final r = _comparePreRelease(aPre, bPre);
    if (r != 0) return r;
  }
  // Build metadata: numeric when both parse, else lexical.
  final aBuildNum = int.tryParse(aBuild ?? '');
  final bBuildNum = int.tryParse(bBuild ?? '');
  if (aBuildNum != null && bBuildNum != null) {
    return aBuildNum.compareTo(bBuildNum);
  }
  return (aBuild ?? '').compareTo(bBuild ?? '');
}

/// Splits `1.5.8-beta.1+10508` into core `[1, 5, 8]`, pre `beta.1`,
/// build `10508`. Missing pre/build are null.
(List<int>, String?, String?) _splitVersion(String s) {
  var rest = s.trim();
  String? build;
  final plus = rest.indexOf('+');
  if (plus >= 0) {
    build = rest.substring(plus + 1);
    rest = rest.substring(0, plus);
  }
  String? pre;
  final dash = rest.indexOf('-');
  if (dash >= 0) {
    pre = rest.substring(dash + 1);
    rest = rest.substring(0, dash);
  }
  final core = rest.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  return (core, pre, build);
}

/// Semver pre-release comparison: identifiers split on `.`; numeric
/// identifiers compare numerically and sort before alphanumeric ones;
/// a shorter pre-release is older when it is a prefix of the other.
int _comparePreRelease(String a, String b) {
  final aParts = a.split('.');
  final bParts = b.split('.');
  final n = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < n; i++) {
    if (i >= aParts.length) return -1;
    if (i >= bParts.length) return 1;
    final ap = aParts[i];
    final bp = bParts[i];
    if (ap == bp) continue;
    final aNum = int.tryParse(ap);
    final bNum = int.tryParse(bp);
    if (aNum != null && bNum != null) return aNum.compareTo(bNum);
    if (aNum != null) return -1; // numeric < alphanumeric
    if (bNum != null) return 1;
    return ap.compareTo(bp);
  }
  return 0;
}
