import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Info-endpoint tests (plan item 6): `GET /eapi/info/languages` and
// `GET /eapi/info/extensions` feed the filter UI. Both parsers accept
// the enveloped form and the bare form; anything else fails loudly.

class _FakeAdapter implements HttpClientAdapter {
  final Map<String, String> bodies = {};
  final Map<String, int> statuses = {};

  void serve(String path, String body, [int status = 200]) {
    bodies[path] = body;
    statuses[path] = status;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = bodies[options.uri.path];
    if (body == null) {
      return ResponseBody.fromString(
        jsonEncode({'success': 0, 'error': 'not found'}),
        404,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    return ResponseBody.fromString(
      body,
      statuses[options.uri.path] ?? 200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_FakeAdapter adapter) {
  return ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
}

void main() {
  test('languages: enveloped code -> name object', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      '/eapi/info/languages',
      '{"success":1,"languages":{"english":"English","klingon":"Klingon"}}',
    );
    final result = await _apiWith(adapter).getInfoLanguages();
    expect(result.success, isTrue);
    expect(result.data, {'english': 'English', 'klingon': 'Klingon'});
  });

  test('languages: bare code -> name object, no envelope', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      '/eapi/info/languages',
      '{"english":"English","klingon":"Klingon"}',
    );
    final result = await _apiWith(adapter).getInfoLanguages();
    expect(result.success, isTrue);
    expect(result.data, {'english': 'English', 'klingon': 'Klingon'});
  });

  test('languages: a success:0 body fails', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      '/eapi/info/languages',
      '{"success":0,"error":"Access denied"}',
    );
    final result = await _apiWith(adapter).getInfoLanguages();
    expect(result.success, isFalse);
  });

  test('languages: a non-JSON body fails', () async {
    final adapter = _FakeAdapter();
    adapter.serve('/eapi/info/languages', '<html>not json</html>');
    final result = await _apiWith(adapter).getInfoLanguages();
    expect(result.success, isFalse);
  });

  test('extensions: enveloped string array, lowercased', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      '/eapi/info/extensions',
      '{"success":1,"extensions":["epub","pdf","AZW3"]}',
    );
    final result = await _apiWith(adapter).getInfoExtensions();
    expect(result.success, isTrue);
    expect(result.data, ['epub', 'pdf', 'azw3']);
  });

  test('extensions: a non-list body fails', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      '/eapi/info/extensions',
      '{"success":1,"extensions":"epub"}',
    );
    final result = await _apiWith(adapter).getInfoExtensions();
    expect(result.success, isFalse);
  });
}
