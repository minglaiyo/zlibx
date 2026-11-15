import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/services/hive_service.dart';

/// "书籍网格自适应列数"这个开关的 Hive 取值优先级。
///
/// 这个键换过三次名字，四列布局那个开关也在 1.6.0 里发布过（现在删了），
/// 所以老用户机器上留着的键必须还能读出他自己选过的那一档：
/// * 当前键 `adaptiveGridColumns` 永远优先——否则用户在这个版本里把开关
///   关掉，下次启动旧值又把它顶回去；
/// * 已经删掉的"推荐页四列布局"（`homeGridFourColumns`）和枚举档里的
///   `four` 都算"开"——那正是"我要更密的自动网格"的意思，升级后不该掉回
///   他没选过的两列。
///
/// 列数本身在 `test/widgets/app_layout_test.dart` 里钉，这里只管读数。
Directory? _hiveDir;

Future<void> _seed(Map<String, Object?> values) async {
  final box = HiveService.settingsBox;
  await box.clear();
  for (final e in values.entries) {
    await box.put(e.key, e.value);
  }
}

/// 每次新建容器：`Notifier.build()` 只在首次读取时跑，复用容器就读不到
/// 刚种进去的键。
bool _adaptiveState() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container.read(adaptiveGridProvider);
}

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('grid_switch_keys');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _hiveDir?.delete(recursive: true);
  });

  test('什么都没存过：默认关（旧版排布）', () async {
    await _seed({});
    expect(_adaptiveState(), isFalse);
  });

  test('当前键说了算：adaptiveGridColumns', () async {
    await _seed({'adaptiveGridColumns': true});
    expect(_adaptiveState(), isTrue);
    await _seed({'adaptiveGridColumns': false});
    expect(_adaptiveState(), isFalse);
  });

  test('当前键压过所有旧键', () async {
    // 关掉开关之后重启，旧值不能把它顶回来。
    await _seed({
      'adaptiveGridColumns': false,
      'homeGridAdaptive': true,
      'homeGridColumnsMode': 'auto',
      'homeGridFourColumns': true,
    });
    expect(_adaptiveState(), isFalse);
  });

  test('中间版本的 homeGridAdaptive 仍读得到', () async {
    await _seed({'homeGridAdaptive': true});
    expect(_adaptiveState(), isTrue);
  });

  test('枚举档：auto / four 算开，two / three 算关', () async {
    for (final mode in ['auto', 'four']) {
      await _seed({'homeGridColumnsMode': mode});
      expect(_adaptiveState(), isTrue, reason: mode);
    }
    for (final mode in ['two', 'three']) {
      await _seed({'homeGridColumnsMode': mode});
      expect(_adaptiveState(), isFalse, reason: mode);
    }
    // 认不出的值（枚举里删掉的档位 / 别的字符串）按默认走。
    await _seed({'homeGridColumnsMode': 'six'});
    expect(_adaptiveState(), isFalse);
  });

  test('1.6.0 的四列开关开过 = 自适应开', () async {
    await _seed({'homeGridFourColumns': true});
    expect(_adaptiveState(), isTrue);
    await _seed({'homeGridFourColumns': false});
    expect(_adaptiveState(), isFalse);
  });

  test('写一次就把旧键换成当前键', () async {
    // UI 上拨一下之后，磁盘上应留下新键；旧键留着无害（新键优先），
    // 不必再写一段删键逻辑去冒删错键的风险。
    await _seed({'homeGridFourColumns': true});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(adaptiveGridProvider.notifier).setAdaptive(false);
    expect(HiveService.settingsBox.get('adaptiveGridColumns'), isFalse);
    expect(_adaptiveState(), isFalse);
  });
}
