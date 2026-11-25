// ReaderProgressStore: reading position in Hive (settings box,
// key reader_progress_v1). Real Hive box in a temp dir, same
// pattern as the downloads category-filter test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/reader_progress.dart';

void main() {
  Directory? hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('reader_progress_test');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir!.delete(recursive: true);
  });

  setUp(() async {
    ReaderProgressStore.resetThrottleForTest();
    await HiveService.settingsBox.delete('reader_progress_v1');
  });

  test('read returns null before any save', () {
    expect(ReaderProgressStore.readCfi('1'), isNull);
  });

  test('save then read returns the CFI', () async {
    await ReaderProgressStore.save(
      '1',
      'epubcfi(/6/2[chap1]!)',
      0.25,
      now: DateTime(2026, 11, 25, 22, 0),
    );
    expect(
      ReaderProgressStore.readCfi('1'),
      'epubcfi(/6/2[chap1]!)',
    );
    // Another book is untouched.
    expect(ReaderProgressStore.readCfi('2'), isNull);
  });

  test('a newer save overwrites the old position', () async {
    await ReaderProgressStore.save(
      '1',
      'epubcfi(/6/2!)',
      0.1,
      now: DateTime(2026, 11, 25, 22, 0),
    );
    await ReaderProgressStore.save(
      '1',
      'epubcfi(/6/4!)',
      0.5,
      now: DateTime(2026, 11, 25, 22, 5),
    );
    expect(ReaderProgressStore.readCfi('1'), 'epubcfi(/6/4!)');
  });

  test('saves within the throttle window are dropped', () async {
    final t0 = DateTime(2026, 11, 25, 22, 0);
    await ReaderProgressStore.save('1', 'epubcfi(/6/2!)', 0.1, now: t0);
    // 1s later: inside the 2s window, dropped.
    await ReaderProgressStore.save(
      '1',
      'epubcfi(/6/3!)',
      0.2,
      now: t0.add(const Duration(seconds: 1)),
    );
    expect(ReaderProgressStore.readCfi('1'), 'epubcfi(/6/2!)');
    // 3s later: outside the window, kept.
    await ReaderProgressStore.save(
      '1',
      'epubcfi(/6/4!)',
      0.3,
      now: t0.add(const Duration(seconds: 3)),
    );
    expect(ReaderProgressStore.readCfi('1'), 'epubcfi(/6/4!)');
  });

  test('clear drops one book and leaves the others', () async {
    final t0 = DateTime(2026, 11, 25, 22, 0);
    await ReaderProgressStore.save('1', 'epubcfi(/6/2!)', 0.1, now: t0);
    await ReaderProgressStore.save('2', 'epubcfi(/6/2!)', 0.1, now: t0);
    await ReaderProgressStore.clear('1');
    expect(ReaderProgressStore.readCfi('1'), isNull);
    expect(ReaderProgressStore.readCfi('2'), 'epubcfi(/6/2!)');
  });

  test('a corrupt blob reads as null instead of throwing', () async {
    await HiveService.settingsBox.put('reader_progress_v1', 'not-json{');
    expect(ReaderProgressStore.readCfi('1'), isNull);
  });
}
