import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/screens/auth/login_failure.dart';

void main() {
  group('classifyLoginFailure: 网络 / 密码错误 / 账号错误 / 其他', () {
    test('网络：超时、连接、握手、cf 拦截都归网络', () {
      for (final error in [
        'Connection timed out',
        'SocketException: Failed host lookup',
        'Connection reset by peer',
        'Network is unreachable',
        'HandshakeException: Connection terminated during handshake',
        'cf_blocked',
        'line_error',
      ]) {
        expect(
          classifyLoginFailure(error),
          LoginFailureKind.network,
          reason: error,
        );
      }
    });

    test('密码错误：Incorrect email or password 与 Authorization failed', () {
      for (final error in [
        'Incorrect email or password',
        'Authorization failed',
        'wrong password',
        'Invalid password',
      ]) {
        expect(
          classifyLoginFailure(error),
          LoginFailureKind.wrongPassword,
          reason: error,
        );
      }
    });

    test('账号错误：账号不存在类文案', () {
      for (final error in [
        'User not found',
        'Account not found',
        'User not registered',
        '用户未注册',
        '账号不存在',
      ]) {
        expect(
          classifyLoginFailure(error),
          LoginFailureKind.accountError,
          reason: error,
        );
      }
    });

    test('其他：空串与无法识别的服务端错误', () {
      expect(classifyLoginFailure(null), LoginFailureKind.other);
      expect(classifyLoginFailure(''), LoginFailureKind.other);
      expect(
        classifyLoginFailure('Something unexpected happened'),
        LoginFailureKind.other,
      );
    });
  });
}
