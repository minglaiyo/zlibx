import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/domain_probe.dart';
import 'package:zlibx/services/hive_service.dart';

// Domain probe tests (plan item 4): manual redirect following with
// a wall / loop / off-family hop told apart, and anonymous adoption
// of a verified redirect target.

class _Planned {
  final int status;
  final String body;
  final Map<String, List<String>> headers;

  const _Planned(this.status, this.body, [this.headers = const {}]);
}

class _FakeAdapter implements HttpClientAdapter {
  /// host+path -> responses served in order.
  final Map<String, List<_Planned>> scripts = {};
  final List<String> requestedUrls = [];

  void script(String hostAndPath, List<_Planned> responses) {
    scripts[hostAndPath] = List.of(responses);
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUrls.add(options.uri.toString());
    final queue = scripts['${options.uri.host}${options.uri.path}'];
    if (queue == null || queue.isEmpty) {
      return ResponseBody.fromString('not found', 404);
    }
    final planned = queue.removeAt(0);
    return ResponseBody.fromString(
      planned.body,
      planned.status,
      headers: planned.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_FakeAdapter adapter) =>
    Dio()..httpClientAdapter = adapter;

const _domainsOk = _Planned(
  200,
  '{"success":1,"domains":["z-lib.fm","other.example"]}',
  {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('domain_probe_test');
    Hive.init(tempDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });
  setUp(() => Hive.box(HiveService.settingsBoxName).clear());
  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('a live root with no redirect is ok, zero hops', () async {
    final adapter = _FakeAdapter();
    adapter.script('ok.example/', [const _Planned(200, '<html/>')]);
    final result = await DomainProbe.probe(
      'ok.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.ok);
    expect(result.finalHost, 'ok.example');
    expect(result.hops, 0);
    expect(result.adoptedHost, isNull);
  });

  test('307 + Server: DiamWall is a wall, not a loop', () async {
    final adapter = _FakeAdapter();
    adapter.script('wall.example/', [
      const _Planned(307, '', {
        'server': ['DiamWall'],
        'location': ['https://wall.example/'],
        'set-cookie': ['__diamwall=abc; Path=/'],
      }),
    ]);
    final result = await DomainProbe.probe(
      'wall.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.wall);
    expect(result.finalHost, 'wall.example');
    // Never followed: exactly one request went out.
    expect(adapter.requestedUrls, hasLength(1));
  });

  test('307 + __diamwall cookie is a wall even without the Server header',
      () async {
    final adapter = _FakeAdapter();
    adapter.script('wall2.example/', [
      const _Planned(307, '', {
        'location': ['https://wall2.example/'],
        'set-cookie': ['__diamwall=abc; Path=/'],
      }),
    ]);
    final result = await DomainProbe.probe(
      'wall2.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.wall);
    expect(adapter.requestedUrls, hasLength(1));
  });

  test('the same URL twice is a redirect loop', () async {
    final adapter = _FakeAdapter();
    adapter.script('loop.example/', [
      const _Planned(302, '', {
        'location': ['https://loop.example/'],
      }),
    ]);
    final result = await DomainProbe.probe(
      'loop.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.redirectLoop);
    expect(adapter.requestedUrls, hasLength(1));
  });

  test('an off-family hop is adopted when its domains check vouches',
      () async {
    final adapter = _FakeAdapter();
    adapter.script('moved.example/', [
      const _Planned(302, '', {
        'location': ['https://newhome.example/'],
      }),
    ]);
    adapter.script('newhome.example/eapi/info/domains', [_domainsOk]);
    final result = await DomainProbe.probe(
      'moved.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.ok);
    expect(result.finalHost, 'newhome.example');
    expect(result.adoptedHost, 'newhome.example');
    expect(result.hops, 1);
    expect(DomainProbe.discoveredHosts, ['newhome.example']);
  });

  test('an off-family hop is refused when its domains check does not vouch',
      () async {
    final adapter = _FakeAdapter();
    adapter.script('moved2.example/', [
      const _Planned(302, '', {
        'location': ['https://sketchy.example/'],
      }),
    ]);
    adapter.script('sketchy.example/eapi/info/domains', [
      const _Planned(
        200,
        '{"success":1,"domains":["sketchy.example"]}',
        {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    ]);
    final result = await DomainProbe.probe(
      'moved2.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.externalRedirect);
    expect(result.finalHost, 'sketchy.example');
    expect(result.adoptedHost, isNull);
    expect(DomainProbe.discoveredHosts, isEmpty);
  });

  test('a hop to a family host is followed with no domains check',
      () async {
    final adapter = _FakeAdapter();
    adapter.script('hop.example/', [
      const _Planned(302, '', {
        'location': ['https://z-lib.fm/'],
      }),
    ]);
    adapter.script('z-lib.fm/', [const _Planned(200, '<html/>')]);
    final result = await DomainProbe.probe(
      'hop.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.ok);
    expect(result.finalHost, 'z-lib.fm');
    expect(result.adoptedHost, isNull);
    expect(
      adapter.requestedUrls,
      isNot(contains('https://z-lib.fm/eapi/info/domains')),
    );
  });

  test('more than 3 hops without terminating is too many redirects',
      () async {
    final adapter = _FakeAdapter();
    adapter.script('chain.example/', [
      const _Planned(302, '', {
        'location': ['https://chain.example/a'],
      }),
    ]);
    adapter.script('chain.example/a', [
      const _Planned(302, '', {
        'location': ['https://chain.example/b'],
      }),
    ]);
    adapter.script('chain.example/b', [
      const _Planned(302, '', {
        'location': ['https://chain.example/c'],
      }),
    ]);
    adapter.script('chain.example/c', [
      const _Planned(302, '', {
        'location': ['https://chain.example/d'],
      }),
    ]);
    final result = await DomainProbe.probe(
      'chain.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.tooManyRedirects);
    expect(result.hops, 3);
    // /d was never requested: the probe stopped at 3 hops.
    expect(adapter.requestedUrls, hasLength(4));
  });

  test('a terminal 503 is a failure, not a wall or a loop', () async {
    final adapter = _FakeAdapter();
    adapter.script('bad.example/', [const _Planned(503, 'error')]);
    final result = await DomainProbe.probe(
      'bad.example',
      dio: _dioWith(adapter),
    );
    expect(result.outcome, DomainProbeOutcome.failed);
  });

  test('cold-start re-verification keeps passing hosts, drops the rest',
      () async {
    final box = Hive.box(HiveService.settingsBoxName);
    await box.put(DomainProbe.discoveredHostsKey, [
      'good.example',
      'dead.example',
    ]);
    final adapter = _FakeAdapter();
    adapter.script('good.example/eapi/info/domains', [_domainsOk]);
    adapter.script('dead.example/eapi/info/domains', [
      const _Planned(404, 'not found'),
    ]);
    await DomainProbe.reverifyDiscoveredHosts(dio: _dioWith(adapter));
    expect(DomainProbe.discoveredHosts, ['good.example']);
  });

  test('re-verification with no discovered hosts does nothing', () async {
    final adapter = _FakeAdapter();
    await DomainProbe.reverifyDiscoveredHosts(dio: _dioWith(adapter));
    expect(adapter.requestedUrls, isEmpty);
  });
}
