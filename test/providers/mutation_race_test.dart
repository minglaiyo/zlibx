import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/hive_service.dart';

/// 审查3 回归：状态竞争与异步生命周期。
///
/// 1. AuthState.copyWith 的 clearError 语义（P1-1）：新登录必须
///    清掉上一次失败留下的错误，而不是靠 `error: null`（copyWith
///    惯用语里 null 意为"保留"）。
/// 2. 书单乐观 mutation 的字段级回滚（P1-2）：同一书单上两个操作
///    重叠时，先发起者失败不得把后发起者已成功的字段一起回滚掉。
/// 3. loadMore 在 provider dispose 后的 finally（P2-2）：不得写状态
///    （旧写法在 dispose 后仍 `state =`，依赖 Riverpod 宽容才没炸）。
///
/// 沿用 test/providers/booklists_state_test.dart 的 harness 形态：
/// fake ZLibraryApi（implements + noSuchMethod）、fake AuthNotifier、
/// 一次性 Hive 目录。
const _userA = User(
  id: '35899435',
  email: 'a@example.com',
  name: 'userA',
  remixUserkey: 'keyA',
);

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this._state);

  final AuthState _state;

  @override
  AuthState build() => _state;

  @override
  Future<bool> login(String email, String password) async {
    // 真 login 的开头动作，供 clearError 行为测试直接调用。
    state = state.copyWith(isLoading: true, clearError: true);
    return true;
  }
}

Booklist _list(String id, {int? color = 1, bool isPrivate = false}) => Booklist(
  id: id,
  name: 'List $id',
  color: color,
  isPrivate: isPrivate,
  url: 'https://example.com/booklist/$id',
);

BooklistsPage _minePage({int page = 1}) => BooklistsPage(
  lists: [_list('7001'), _list('7002')],
  totalPages: 2,
);

/// 可布防的 mutation 网关：每个写操作按 key 排队一个 Completer，
/// 测试精确控制成功/失败的完成时机，制造两个操作的交错窗口。
class _FakeZLibraryApi implements ZLibraryApi {
  /// key → 下一次该操作的完成时机。缺省立即成功。
  final colorGates = <int, Completer<ApiResponse<bool>>>{};
  final publicGates = <int, Completer<ApiResponse<bool>>>{};

  /// page>1 的排队网关（dispose 竞态测试用）。
  final loadMoreGates = <Completer<ApiResponse<BooklistsPage>>>[];

  /// 下一次 mine 首屏刷新返回的列表颜色（P2-3：模拟刷新已替换数据）。
  int? refreshColor;

  @override
  Future<ApiResponse<BooklistsPage>> searchMyBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) async {
    if (page > 1 && loadMoreGates.isNotEmpty) {
      return loadMoreGates.removeAt(0).future;
    }
    final override = refreshColor;
    if (override != null) {
      refreshColor = null;
      return ApiResponse.ok(
        BooklistsPage(
          lists: [_list('7001', color: override), _list('7002')],
          totalPages: 2,
        ),
      );
    }
    return ApiResponse.ok(_minePage(page: page));
  }

  @override
  String booklistsPageUrl({
    required bool mine,
    bool favorite = false,
    String query = '',
    String? order,
    int page = 1,
  }) => 'https://example.com/booklists/my?page=$page';

  @override
  Future<ApiResponse<bool>> setBooklistColor({
    required int id,
    required int color,
  }) async {
    final gate = colorGates.remove(id);
    if (gate != null) return gate.future;
    return ApiResponse.ok(true);
  }

  @override
  Future<ApiResponse<bool>> toggleBooklistPublic(int id) async {
    final gate = publicGates.remove(id);
    if (gate != null) return gate.future;
    return ApiResponse.ok(true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected call: ${invocation.memberName}');
}

Directory? _hiveDir;

ProviderContainer _container(_FakeZLibraryApi api) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => _FakeAuthNotifier(AuthState(user: _userA))),
    ],
  );
  container.listen(booklistsControllerProvider, (_, _) {});
  addTearDown(container.dispose);
  return container;
}

Future<void> _waitUntil(
  ProviderContainer container,
  bool Function(BooklistsState) condition,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (condition(container.read(booklistsControllerProvider))) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met');
}

Booklist? _find(ProviderContainer container, String id) {
  for (final l in container.read(booklistsControllerProvider).lists) {
    if (l.id == id) return l;
  }
  return null;
}

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('mutation_race_test');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openLazyBox(HiveService.booklistHtmlBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await _hiveDir!.delete(recursive: true);
  });

  group('AuthState clearError（P1-1）', () {
    test('copyWith(error: null) 保留旧错误（惯用语不变）', () {
      final s = AuthState(error: 'bad password');
      expect(s.copyWith(isLoading: true, error: null).error, 'bad password');
    });

    test('clearError 显式清空', () {
      final s = AuthState(error: 'bad password');
      expect(s.copyWith(isLoading: true, clearError: true).error, isNull);
    });

    test('登录开始即清除上一次失败', () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FakeAuthNotifier(AuthState(error: 'bad password')),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).login('a@b.c', 'pw');
      expect(container.read(authProvider).error, isNull);
      expect(container.read(authProvider).isLoading, isTrue);
    });
  });

  group('书单字段级回滚（P1-2）', () {
    test('颜色操作失败不覆盖同期成功的公开状态改动', () async {
      final api = _FakeZLibraryApi();
      final container = _container(api);
      await _waitUntil(
        container,
        (s) => s.phase == BooklistsPhase.ready && s.lists.isNotEmpty,
      );

      final list = _find(container, '7001')!;
      // 操作 1：改色 → 网关挂起（稍后由测试亲手判失败）。
      final colorGate = Completer<ApiResponse<bool>>();
      api.colorGates[7001] = colorGate;
      final colorOp = container
          .read(booklistsControllerProvider.notifier)
          .setBooklistColor(list, 4);
      await Future<void>.delayed(Duration.zero);
      expect(_find(container, '7001')!.color, 4, reason: '乐观更新生效');

      // 操作 2：公开切换 → 立即成功；作用在含乐观 color=4 的当前对象上。
      final publicOp = await container
          .read(booklistsControllerProvider.notifier)
          .toggleBooklistPublic(_find(container, '7001')!);
      expect(publicOp.success, isTrue);
      expect(_find(container, '7001')!.isPrivate, isTrue);
      expect(_find(container, '7001')!.color, 4, reason: 'op2 不得动 color');

      // 现在才让操作 1 失败：回滚只恢复 color，op2 的成功必须留下。
      colorGate.completeError(StateError('network down'));
      final first = await colorOp;
      expect(first.success, isFalse);
      final after = _find(container, '7001')!;
      expect(after.color, 1, reason: 'color 回滚到快照值');
      expect(after.isPrivate, isTrue, reason: '同期成功字段不得被整旧对象覆盖');
    });
  });

  group('刷新后的迟到回滚（P2-3）', () {
    test('乐观改色挂起期间页面刷新：失败不得写回旧快照值', () async {
      final api = _FakeZLibraryApi();
      final container = _container(api);
      await _waitUntil(
        container,
        (s) => s.phase == BooklistsPhase.ready && s.lists.isNotEmpty,
      );

      final list = _find(container, '7001')!;
      final gate = Completer<ApiResponse<bool>>();
      api.colorGates[7001] = gate;
      final colorOp = container
          .read(booklistsControllerProvider.notifier)
          .setBooklistColor(list, 4);
      await Future<void>.delayed(Duration.zero);
      expect(_find(container, '7001')!.color, 4);

      // 刷新：新数据把该列表颜色置 9（服务器已换状态），generation 前移。
      api.refreshColor = 9;
      await container.read(booklistsControllerProvider.notifier).loadFirst();
      await _waitUntil(
        container,
        (s) => _find(container, '7001')?.color == 9,
      );

      // 迟到的失败回滚：generation 守卫必须拦住（旧代码会把 9 抹成
      // 快照里的 1——拿"操作前"覆盖刷新后的新真值）。
      gate.complete(ApiResponse.fail('server said no'));
      final resp = await colorOp;
      expect(resp.success, isFalse);
      expect(
        _find(container, '7001')!.color,
        9,
        reason: '刷新后的数据是权威，过期回滚不得落笔',
      );
    });
  });

  group('dispose 守卫（P2-2）', () {
    test('loadMore 在途时 dispose：响应完成不得写已销毁的状态', () async {
      final api = _FakeZLibraryApi();
      final container = _container(api);
      await _waitUntil(
        container,
        (s) => s.phase == BooklistsPhase.ready && s.lists.isNotEmpty,
      );

      final gate = Completer<ApiResponse<BooklistsPage>>();
      api.loadMoreGates.add(gate);
      // 发起 loadMore：响应被网关扣住，此刻 provider 被销毁。
      unawaited(container.read(booklistsControllerProvider.notifier).loadMore());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      container.dispose();

      // 迟到的响应完成——旧写法会在 finally 里对已销毁的 Notifier
      // 写状态并异步抛 StateError；守卫后必须安静吞掉。未捕获的
      // 异步错误会让本 test 自动失败（flutter_test zone 兜底）。
      gate.complete(ApiResponse.ok(_minePage(page: 2)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
}
