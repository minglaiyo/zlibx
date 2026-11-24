import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/webview_challenge_solver.dart';

/// [WebviewChallengeSolver] 的纯 Dart 部分回归测试。
///
/// 背景（2026-11-12 真机复现）：下载历史在墙后 503 时，无头 WebView
/// 抓到空 503 页就当自己过关——轮询只看标题，标题里没有验证墙关键
/// 字就交卷，可见回退被跳过，解析守卫最后把原始 503 错抛出来。这
/// 里锁住两点：标题中性但正文含验证墙标记仍算墙页；空 503 页按标
/// 记认不出是墙页（这正是解析失败后要再走可见 solver 的原因）。
void main() {
  group('WebviewChallengeSolver.isChallengePage', () {
    test('标题中性但正文含验证墙标记仍是墙页', () {
      expect(
        WebviewChallengeSolver.isChallengePage(
          title: 'Z-Library',
          bodySnippet: '<div id="cf-turnstile"></div>',
        ),
        isTrue,
      );
    });

    test('标题中性且正文干净是真页面', () {
      expect(
        WebviewChallengeSolver.isChallengePage(
          title: 'Z-Library',
          bodySnippet: '<div class="dstats-content"></div>',
        ),
        isFalse,
      );
    });

    test('验证墙标题本身就是墙页', () {
      expect(
        WebviewChallengeSolver.isChallengePage(
          title: 'Checking your browser',
          bodySnippet: '',
        ),
        isTrue,
      );
    });
  });

  group('WebviewChallengeSolver.isChallengeHtml', () {
    test('空 503 报错页按标记认不出是墙页', () {
      // 这正是下载历史解析失败后要再走可见 solver 的原因：光靠标
      // 记分不清空 503 页和真页面，只有调用方的解析守卫能发现它
      // 不是要的那页。
      const bare503 = '''
<html><head><title>503 Service Temporarily Unavailable</title></head>
<body><h1>503</h1></body></html>
''';
      expect(WebviewChallengeSolver.isChallengeHtml(bare503), isFalse);
    });

    test('验证墙页能从整份 HTML 认出来', () {
      const challenge = '''
<html><head><title>Just a moment...</title></head>
<body><div id="cf-turnstile"></div></body></html>
''';
      expect(WebviewChallengeSolver.isChallengeHtml(challenge), isTrue);
    });
  });

  group('WebviewChallengeSolver.fetchHtmlVisibleOnly', () {
    tearDown(() {
      WebviewChallengeSolver.overrideIsMobile = null;
      WebviewChallengeSolver.visibleSolverFallback = null;
    });

    test('直接走可见回退并缓存 HTML', () async {
      WebviewChallengeSolver.overrideIsMobile = true;
      WebviewChallengeSolver.visibleSolverFallback =
          (url) async => '<html><body>real page</body></html>';
      final html = await WebviewChallengeSolver.fetchHtmlVisibleOnly(
        'https://fake.test/users/downloads',
      );
      expect(html, contains('real page'));
    });

    test('没有注册回退时返回 null', () async {
      WebviewChallengeSolver.overrideIsMobile = true;
      final html = await WebviewChallengeSolver.fetchHtmlVisibleOnly(
        'https://fake.test/users/downloads',
      );
      expect(html, isNull);
    });

    test('非移动端返回 null', () async {
      WebviewChallengeSolver.overrideIsMobile = false;
      WebviewChallengeSolver.visibleSolverFallback =
          (url) async => '<html><body>real page</body></html>';
      final html = await WebviewChallengeSolver.fetchHtmlVisibleOnly(
        'https://fake.test/users/downloads',
      );
      expect(html, isNull);
    });
  });

  // 第 9 轮：`/dl/{token}` 那一跳改由浏览器领路，产出一个能落盘的直链。
  // WebView 本身在单测里跑不起来，所以这里钉的是两条纯判据：这个地址算不
  // 算"浏览器被交予的文件"，以及求解器关掉时不许凭空造出一个地址来。
  group('looksLikeFileUrl（/dl/ 落地地址的判据）', () {
    test('书名扩展名算，路径最后一段说了算', () {
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'https://dl-cdn.example.com/f/9f2c/book.epub',
        ),
        isTrue,
      );
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'https://dl-cdn.example.com/f/book.PDF',
        ),
        isTrue,
      );
      // 校验页/书页自己：看着就不是文件。
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'https://bookroom.lifestyle/dl/ABVGVr08wz',
        ),
        isFalse,
      );
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'https://bookroom.lifestyle/book/Ej8q7Dmrv9/三体.html',
        ),
        isFalse,
      );
    });

    test('没有扩展名时，attachment 参数也算', () {
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'https://dl-cdn.example.com/f/9f2c?filename=book.epub',
        ),
        isTrue,
      );
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'https://dl-cdn.example.com/f/9f2c?response-content-disposition='
          'attachment',
        ),
        isTrue,
      );
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'https://dl-cdn.example.com/f/9f2c?ts=1323',
        ),
        isFalse,
      );
    });

    test('非 https / 空串 / 相对地址一律不算', () {
      // 这个判据的下游是下载器：它会照着返回的地址写盘。
      expect(
        WebviewChallengeSolver.looksLikeFileUrl(
          'http://dl-cdn.example.com/f/book.epub',
        ),
        isFalse,
      );
      expect(WebviewChallengeSolver.looksLikeFileUrl(''), isFalse);
      expect(WebviewChallengeSolver.looksLikeFileUrl('/f/book.epub'), isFalse);
      expect(
        WebviewChallengeSolver.looksLikeFileUrl('book.epub'),
        isFalse,
        reason: '没有 host 的相对串不能当下载地址',
      );
    });
  });

  group('solveHeadlessForFileUrl（求解器不可用时）', () {
    test('平台不支持时产出空结果，不编造文件地址', () async {
      WebviewChallengeSolver.overrideIsSupported = false;
      final result = await WebviewChallengeSolver.solveHeadlessForFileUrl(
        'https://bookroom.lifestyle/dl/ABVGVr08wz',
      );
      expect(result.gotFileUrl, isFalse);
      expect(result.html, isNull);
      expect(result.fileSource, 'none');
    });

    test('后台求解被关掉时同样产出空结果', () async {
      WebviewChallengeSolver.overrideIsSupported = true;
      WebviewChallengeSolver.guiEnabled = true;
      WebviewChallengeSolver.headlessEnabled = false;
      final result = await WebviewChallengeSolver.solveHeadlessForFileUrl(
        'https://bookroom.lifestyle/dl/ABVGVr08wz',
      );
      expect(result.gotFileUrl, isFalse);
      WebviewChallengeSolver.headlessEnabled = true;
    });
  });
}
