import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/random_feed_history.dart';

/// 随机推荐疲劳名单（首页"看过的别再推"的那份记录）。
///
/// 守两件事：名单是**内存镜像 + 异步落盘**，所以刚展示的一批立刻就能
/// 被下一次抽样看见（预取紧跟着抽样，只认硬盘会有竞态）；以及它有上
/// 限、坏值不抛——首页永远不该因为一份疲劳名单而报错。
Directory? _dir;

List<String> _ids(int from, int count) => [
  for (var i = from; i < from + count; i++) '$i',
];

void main() {
  setUpAll(() async {
    _dir = await Directory.systemTemp.createTemp('random_feed_history');
    Hive.init(_dir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  setUp(() async {
    await RandomFeedHistory.clear();
    RandomFeedHistory.resetCacheForTest();
  });

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _dir?.delete(recursive: true);
  });

  test('展示的批次按顺序进名单：最久在前、最新在后', () {
    RandomFeedHistory.recordShown(_ids(1, 3));
    RandomFeedHistory.recordShown(_ids(4, 3));
    expect(RandomFeedHistory.readSync(), _ids(1, 6));
  });

  test('重复展示只挪到队尾，不在名单里占两个坑', () {
    RandomFeedHistory.recordShown(['1', '2', '3']);
    RandomFeedHistory.recordShown(['2', '9']);
    expect(RandomFeedHistory.readSync(), ['1', '3', '2', '9']);
  });

  test('空 id 与空批次不写名单', () {
    RandomFeedHistory.recordShown(<String>[]);
    RandomFeedHistory.recordShown(['', '5']);
    expect(RandomFeedHistory.readSync(), ['5']);
  });

  test('名单有上限：超了就砍最久没看的', () {
    for (var batch = 0; batch < 10; batch++) {
      RandomFeedHistory.recordShown(_ids(batch * 50 + 1, 50));
    }
    final kept = RandomFeedHistory.readSync();
    // 记过 1..500，每批都当场砍到 400：最后停在 101..500。
    expect(kept.length, RandomFeedHistory.cap);
    expect(kept.first, '101');
    expect(kept.last, '500');
  });

  test('落盘：flush 之后盒里就是内存内容，冷读能接上', () async {
    RandomFeedHistory.recordShown(_ids(1, 50));
    await RandomFeedHistory.flush();
    final onDisk = HiveService.settingsBox.get(RandomFeedHistory.boxKey);
    expect(onDisk, _ids(1, 50));
    // 模拟下次启动：内存镜像没了，从盒里读回来。
    RandomFeedHistory.resetCacheForTest();
    expect(RandomFeedHistory.readSync(), _ids(1, 50));
  });

  test('盒里是坏值：读成空名单，不抛', () async {
    await HiveService.settingsBox.put(RandomFeedHistory.boxKey, 42);
    RandomFeedHistory.resetCacheForTest();
    expect(RandomFeedHistory.readSync(), isEmpty);
    // 坏名单不影响继续记账。
    RandomFeedHistory.recordShown(['7']);
    expect(RandomFeedHistory.readSync(), ['7']);
  });
}
