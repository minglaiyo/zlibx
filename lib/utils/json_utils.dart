import 'dart:convert';
import 'dart:isolate';

/// JSON 解码的统一出口（审查 P1-2）：小文本直接在原地解，超过阈值的
/// 大文本走后台 isolate，免得一次解码堵住 UI 线程。解码结果是纯数据，
/// 可跨 isolate 传递；调用方仍按原样处理返回值与 FormatException。
///
/// 阈值按字符数算（JSON 文本基本是 ASCII，字符数约等于字节数）；
/// 默认 64 KB，和搜索响应（zlibrary_api.dart）的阈值一致。
Future<Object?> decodeJsonMaybeIsolate(
  String raw, {
  int threshold = 64 * 1024,
}) {
  if (raw.length > threshold) {
    return Isolate.run(() => jsonDecode(raw));
  }
  // Future(...) 而不是 Future.value(jsonDecode(raw))：后者会先在
  // 同步求值，格式错误就同步抛出；包一层 future 后错误走异步，
  // 调用方 await 时在原有的 try/catch 里接住，行为和原来一致。
  return Future(() => jsonDecode(raw));
}
