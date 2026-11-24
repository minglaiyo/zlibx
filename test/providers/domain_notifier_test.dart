// P2-5：DomainNotifier.setDomain 的信任确认测试——这是安全承诺：
// 已存会话绝不能自动发给未确认的镜像。切到未确认的线路时，
// setDomain 必须走 flagLineUnavailable（让用户重新登录），而不是
// reverify（那会把 remix_userkey 发到新域名上）。
//
// Harness 照 test/providers/booklists_state_test.dart：假 API
// （implements + noSuchMethod）+ 假 AuthNotifier + 临时 Hive 目录。
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/domain_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/mirror_trust.dart';

class _FakeApi implements ZLibraryApi {
  int setDomainCalls = 0;
  String? lastDomain;
  int clearSessionCalls = 0;

  @override
  void setDomain(String domain) {
    setDomainCalls++;
    lastDomain = domain;
  }

  @override
  void clearSession() {
    clearSessionCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected call: ${invocation.memberName}');
}

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this._state);

  AuthState _state;

  int reverifyCalls = 0;
  int flagLineUnavailableCalls = 0;

  @override
  AuthState build() => _state;

  @override
  Future<void> reverify() async {
    reverifyCalls++;
  }

  @override
  void flagLineUnavailable() {
    flagLineUnavailableCalls++;
    state = state.copyWith(lineUnavailable: true);
  }
}

ProviderContainer _container(_FakeApi api, _FakeAuthNotifier auth) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => auth),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// setDomain 的后续刷新是 fire-and-forget（_refreshAfterSwitch 不 await），
/// 所以等条件成立而不是等某个 future；和 booklists_state_test 的
/// _waitForList 同一个形状。
Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for condition');
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('domain_notifier_test');
    Hive.init(tempDir.path);
    await Hive.openBox('settings');
    await Hive.openBox('auth');
  });

  setUp(() async {
    // 确认记录存在 settings 盒里：每个用例从“无确认”开始。
    await Hive.box('settings').clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('未确认的内置镜像：不发会话，只标记线路不可用', () async {
    final api = _FakeApi();
    final auth = _FakeAuthNotifier(const AuthState());
    final container = _container(api, auth);
    // 触发 DomainNotifier.build()：初始线路是默认域名。
    expect(container.read(domainProvider), defaultDomain);

    // bibliotheca.world 在内置列表里，但不是 Z-Library 站群
    // （isZlibFamilyHost 不认），且没有存过确认记录。
    container.read(domainProvider.notifier).setDomain('bibliotheca.world');
    await _waitFor(() => auth.flagLineUnavailableCalls == 1);

    expect(container.read(domainProvider), 'bibliotheca.world');
    // 关键断言：会话没有发出去。
    expect(auth.reverifyCalls, 0);
    expect(auth.flagLineUnavailableCalls, 1);
    // 内存里的会话先清掉，API 再切到新域名。
    expect(api.clearSessionCalls, 1);
    expect(api.lastDomain, 'bibliotheca.world');
  });

  test('已确认的内置镜像：重新验证会话', () async {
    await MirrorTrust.confirm('bibliotheca.world');
    final api = _FakeApi();
    final auth = _FakeAuthNotifier(const AuthState());
    final container = _container(api, auth);
    expect(container.read(domainProvider), defaultDomain);

    container.read(domainProvider.notifier).setDomain('bibliotheca.world');
    await _waitFor(() => auth.reverifyCalls == 1);

    expect(container.read(domainProvider), 'bibliotheca.world');
    expect(auth.reverifyCalls, 1);
    expect(auth.flagLineUnavailableCalls, 0);
    expect(api.clearSessionCalls, 1);
    expect(api.lastDomain, 'bibliotheca.world');
  });

  test('未确认的非内置域名（如下架/ SLUM 来的镜像）：不发会话', () async {
    final api = _FakeApi();
    final auth = _FakeAuthNotifier(const AuthState());
    final container = _container(api, auth);
    expect(container.read(domainProvider), defaultDomain);

    // 不在内置列表、不是站群、没人输过——三条确认路径全不满足。
    container
        .read(domainProvider.notifier)
        .setDomain('mirror-from-slum.example');
    await _waitFor(() => auth.flagLineUnavailableCalls == 1);

    expect(container.read(domainProvider), 'mirror-from-slum.example');
    expect(auth.reverifyCalls, 0);
    expect(auth.flagLineUnavailableCalls, 1);
    expect(api.clearSessionCalls, 1);
    expect(api.lastDomain, 'mirror-from-slum.example');
  });
}
