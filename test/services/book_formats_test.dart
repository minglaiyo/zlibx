import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Book-formats tests (plan item 2): `GET /eapi/book/{id}/{hash}/formats`
// lists the server's formats for a book, each with its own id:hash.
// The non-empty envelope was never verified against a live account,
// so the parser accepts the enveloped form and the bare form, tolerates
// per-entry key variants, skips unusable entries, and fails loudly
// when nothing usable survives. An empty list is a success.

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

const _path = '/eapi/book/123/abc123/formats';

void main() {
  test('enveloped formats list parses id, hash, extension, size', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      _path,
      '{"success":1,"formats":[{"id":123,"hash":"abc123","extension":"EPUB","filesize":12345,"filesizeString":"12 KB"},{"id":456,"hash":"def456","extension":"pdf","filesize":99999}]}',
    );
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isTrue);
    expect(result.data!.length, 2);
    final first = result.data![0];
    expect(first.id, 123);
    expect(first.hash, 'abc123');
    expect(first.extension, 'epub');
    expect(first.filesize, 12345);
    expect(first.filesizeString, '12 KB');
    expect(result.data![1].extension, 'pdf');
    expect(result.data![1].filesizeString, isNull);
  });

  test('bare array is the list itself', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      _path,
      '[{"id":456,"hash":"def456","extension":"mobi"}]',
    );
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isTrue);
    expect(result.data!.length, 1);
    expect(result.data![0].extension, 'mobi');
  });

  test('data envelope key works too', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      _path,
      '{"success":1,"data":[{"id":456,"hash":"def456","extension":"azw3"}]}',
    );
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isTrue);
    expect(result.data![0].extension, 'azw3');
  });

  test('per-entry key variants are tolerated', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      _path,
      '{"success":1,"formats":[{"bookId":"789","hashId":"zzz999","ext":"FB2","size":42}]}',
    );
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isTrue);
    final format = result.data![0];
    expect(format.id, 789);
    expect(format.hash, 'zzz999');
    expect(format.extension, 'fb2');
    expect(format.filesize, 42);
  });

  test('empty list is a success', () async {
    final adapter = _FakeAdapter();
    adapter.serve(_path, '{"success":1,"formats":[]}');
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isTrue);
    expect(result.data, isEmpty);
  });

  test('a success:0 body fails', () async {
    final adapter = _FakeAdapter();
    adapter.serve(_path, '{"success":0,"error":"Access denied"}');
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isFalse);
  });

  test('a non-JSON body fails', () async {
    final adapter = _FakeAdapter();
    adapter.serve(_path, '<html>not json</html>');
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isFalse);
  });

  test('an entry without a hash is skipped, usable ones kept', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      _path,
      '{"success":1,"formats":[{"id":1,"extension":"pdf"},{"id":456,"hash":"def456","extension":"epub"}]}',
    );
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isTrue);
    expect(result.data!.length, 1);
    expect(result.data![0].extension, 'epub');
  });

  test('a list with no usable entry fails', () async {
    final adapter = _FakeAdapter();
    adapter.serve(
      _path,
      '{"success":1,"formats":[{"id":1,"extension":"pdf"}]}',
    );
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isFalse);
  });

  test('an unserved path fails', () async {
    final adapter = _FakeAdapter();
    final result = await _apiWith(adapter).getBookFormats('123', 'abc123');
    expect(result.success, isFalse);
  });
}
