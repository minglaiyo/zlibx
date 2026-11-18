import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/providers/settings_provider.dart';
import 'package:zlibx/services/hive_service.dart';

/// 无痕模式的持久化（Hive `incognitoMode` 键）与取值优先级。
///
/// 开关的视觉接线在 `test/widgets/settings_privacy_incognito_test.dart`
/// 里钉；这里只管读写，用普通 `test()` + ProviderContainer——
/// testWidgets 的 FakeAsync 区里 Hive put 的落盘 Future 永远不会
/// 完成（写队列卡死，tearDownAll 的 Hive.close 会跟着挂），仓库里
/// 所有 Hive 写入测试都走这条普通 test() 通道。
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
bool _incognitoState() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container.read(incognitoModeProvider);
}

void main() {
  setUpAll(() async {
    _hiveDir = await Directory.systemTemp.createTemp('incognito_persistence');
    Hive.init(_hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _hiveDir?.delete(recursive: true);
  });

  test('什么都没存过：默认关', () async {
    await _seed({});
    expect(_incognitoState(), isFalse);
  });

  test('开关打开：落盘当前键', () async {
    await _seed({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(incognitoModeProvider), isFalse);

    await container.read(incognitoModeProvider.notifier).setEnabled(true);
    expect(HiveService.settingsBox.get('incognitoMode'), true);
  });

  test('重启后从落盘值启动', () async {
    await _seed({'incognitoMode': true});
    expect(_incognitoState(), isTrue);
    await _seed({'incognitoMode': false});
    expect(_incognitoState(), isFalse);
  });

  test('脏值（非布尔）按默认关处理', () async {
    await _seed({'incognitoMode': 'yes'});
    expect(_incognitoState(), isFalse);
  });
}
