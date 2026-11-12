import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/books_provider.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/utils/seeded_shuffle.dart';

/// [seededShuffle] / [daySeed] 的伪随机推荐排序测试，以及
/// [homeRecommendedProvider] 在开关两态下的行为。
///
/// 同一种子必须永远得到同一顺序（"伪随机"的确定性承诺），且结果是
/// 原列表的一个重排（不丢书、不重复）。
void main() {
  List<int> ints(int count) => List<int>.generate(count, (i) => i);

  test('daySeed：纯数值日期拼合，同日相同、跨日不同', () {
    expect(daySeed(DateTime(2026, 11, 13)), 20261113);
    expect(daySeed(DateTime(2026, 1, 2)), 20260102);
    expect(
      daySeed(DateTime(2026, 11, 13)),
      isNot(daySeed(DateTime(2026, 11, 14))),
    );
  });

  test('seededShuffle：同一种子得到同一顺序', () {
    final input = ints(50);
    final a = seededShuffle(input, 20261113);
    final b = seededShuffle(input, 20261113);
    expect(a, b);
  });

  test('seededShuffle：结果是原列表的重排（不丢、不重）', () {
    final input = ints(50);
    final shuffled = seededShuffle(input, 20261113);
    expect(shuffled.toSet(), input.toSet());
    expect(shuffled.length, input.length);
  });

  test('seededShuffle：空列表与单元素列表原样返回', () {
    expect(seededShuffle<int>([], 1), isEmpty);
    expect(seededShuffle<int>([7], 1), [7]);
  });

  test('seededShuffle：不同种子产生不同顺序', () {
    final input = ints(50);
    final a = seededShuffle(input, 20261113);
    final b = seededShuffle(input, 20261114);
    expect(a, isNot(b));
  });

  test('homeRecommendedProvider：开关关 = 站点原序，开 = 日种子洗牌', () async {
    final books = List<Book>.generate(
      20,
      (i) => Book(id: i + 1, title: 'Book ${i + 1}'),
    );
    final expectedIds = books.map((b) => b.id.toString());

    // homeRecommendedProvider 是同步 Provider<AsyncValue<…>>：等底层
    // recommendedBooksProvider 的替身解析完成再取值。
    Future<List<String>> resolved(ProviderContainer c) async {
      var av = c.read(homeRecommendedProvider);
      for (var i = 0; i < 50 && av.value == null; i++) {
        await Future<void>.delayed(Duration.zero);
        av = c.read(homeRecommendedProvider);
      }
      return av.value!.map((b) => b.id).toList();
    }

    // 关：保持站点原序。
    final off = ProviderContainer(overrides: [
      recommendedBooksProvider.overrideWith((ref) => books),
      pseudoRandomRecommendProvider
          .overrideWith(() => _FixedPseudoRandom(false)),
    ]);
    addTearDown(off.dispose);
    expect(await resolved(off), expectedIds);

    // 开：与 daySeed 洗牌结果一致（同一天内任何时刻读都一样）。
    final on = ProviderContainer(overrides: [
      recommendedBooksProvider.overrideWith((ref) => books),
      pseudoRandomRecommendProvider
          .overrideWith(() => _FixedPseudoRandom(true)),
    ]);
    addTearDown(on.dispose);
    final shuffledIds =
        seededShuffle(books, daySeed(DateTime.now())).map((b) => b.id
            .toString());
    expect(await resolved(on), shuffledIds);
  });
}

/// 固定值的伪随机开关替身：跳过 Hive 读，直接给 homeRecommendedProvider
/// 提供两态输入。
class _FixedPseudoRandom extends PseudoRandomRecommendNotifier {
  _FixedPseudoRandom(this.value);
  final bool value;

  @override
  bool build() => value;
}
