// P2-5：InstanceManager 的直接引用测试——此前 test/ 里没有任何文件
// 提到它，而它是镜像选择的主路径（决定搜书/下载走哪些站、按什么
// 顺序）。不走网络：SlumCatalogue 喂一个假 Dio，返回固定的 SLUM
// 页面夹具；用户选择存在 MemoryPreferenceStore 里。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/instance_manager.dart';
import 'package:zlibx/services/preference_store.dart';
import 'package:zlibx/services/slum_catalogue.dart';

/// 三条 Z-Library 镜像：a 无保护、b 走 DiamWall、c 已下线。
/// 其余三个服务页返回空（本文件只测 zlibrary）。
const _zlibraryPage = '''
<div class="card" id="zlibrary.a.example">
  <a class="card-title" href="https://a.example/">a.example</a>
  <span class="status-badge up"></span>
</div>
<div class="card" id="zlibrary.b.example">
  <a class="card-title" href="https://b.example/">b.example</a>
  <span class="status-badge up"></span>
  <strong>Protected Site</strong><span>DiamWall</span>
</div>
<div class="card" id="zlibrary.c.example">
  <a class="card-title" href="https://c.example/">c.example</a>
  <span class="status-badge down"></span>
</div>
''';

Dio _fakeDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final page = options.path.split('/').last;
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: page == 'zlibrary.html' ? _zlibraryPage : '',
          ),
        );
      },
    ),
  );
  return dio;
}

InstanceManager _manager() {
  final catalogue = SlumCatalogue(
    dio: _fakeDio(),
    store: MemoryPreferenceStore(),
  );
  return InstanceManager.forTest(
    catalogue: catalogue,
    store: MemoryPreferenceStore(),
  );
}

void main() {
  test('enabledUrls：下线镜像不在，无保护的排在 DiamWall 前面', () async {
    final manager = _manager();
    final urls = await manager.enabledUrls(MirrorService.zlibrary);
    expect(urls, ['https://a.example', 'https://b.example']);
    expect(
      await manager.hasUnprotectedMirror(MirrorService.zlibrary),
      isTrue,
    );
  });

  test('setEnabled 关掉的镜像退出 enabledUrls，再打开又回来', () async {
    final manager = _manager();
    await manager.setEnabled(MirrorService.zlibrary, 'a.example', false);
    expect(
      await manager.disabledHosts(MirrorService.zlibrary),
      {'a.example'},
    );
    expect(
      await manager.enabledUrls(MirrorService.zlibrary),
      ['https://b.example'],
    );
    expect(
      await manager.hasUnprotectedMirror(MirrorService.zlibrary),
      isFalse,
    );

    await manager.setEnabled(MirrorService.zlibrary, 'a.example', true);
    expect(
      await manager.disabledHosts(MirrorService.zlibrary),
      isEmpty,
    );
    expect(
      await manager.enabledUrls(MirrorService.zlibrary),
      ['https://a.example', 'https://b.example'],
    );
  });

  test('手动模式：setManualOrder 的顺序生效，下线镜像仍列在末尾', () async {
    final manager = _manager();
    expect(await manager.isAutoMode(), isTrue);
    await manager.setAutoMode(false);
    await manager.setManualOrder(
      MirrorService.zlibrary,
      ['b.example', 'a.example'],
    );
    expect(await manager.isAutoMode(), isFalse);
    expect(
      await manager.manualOrder(MirrorService.zlibrary),
      ['b.example', 'a.example'],
    );
    final views = await manager.instances(MirrorService.zlibrary);
    // 手动钉住的 b、a 在前，没钉住的 c（已下线）排在自动尾巴。
    expect(
      views.map((v) => v.host).toList(),
      ['b.example', 'a.example', 'c.example'],
    );
    expect(views.map((v) => v.enabled).toList(), [true, true, true]);
  });

  test('instances：下线镜像照常列出（UI 置灰），但 enabledUrls 不要它',
      () async {
    final manager = _manager();
    final views = await manager.instances(MirrorService.zlibrary);
    expect(views.map((v) => v.host).toList(), [
      'a.example',
      'b.example',
      'c.example',
    ]);
    expect(views.last.isDown, isTrue);
    expect(
      await manager.enabledUrls(MirrorService.zlibrary),
      ['https://a.example', 'https://b.example'],
    );
  });
}
