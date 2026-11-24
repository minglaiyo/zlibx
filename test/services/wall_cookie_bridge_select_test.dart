import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/wall_cookie_bridge.dart';

// 解完墙之后，到底哪几枚 cookie 该搬进 Dio——这一步在设备外看不见，而
// 它正是 2026-11-24 那份 `Bad state: Invalid hash` 里三种彼此不同的空手
// 方式之一：WebView 过了墙，Dio 却一枚没拿到，重发必然还是墙。
//
// 选择只看名字，所以能当纯函数测；值永远留在 `setWallCookies` 那条路上。

void main() {
  test('a known clearance name is taken on its own', () {
    final pick = selectBridgedCookieNames(['remix_userid', '__diamwall']);
    expect(pick.bridged, ['__diamwall']);
    expect(pick.usedFallback, isFalse);
  });

  test('the session pair is never bridged, alone or beside a clearance', () {
    expect(selectBridgedCookieNames(['remix_userid', 'remix_userkey']).bridged,
        isEmpty);
    expect(
      selectBridgedCookieNames(['remix_userkey', 'cf_clearance']).bridged,
      ['cf_clearance'],
    );
  });

  test('an unknown clearance name still gets bridged by the fallback', () {
    // 墙那枚改名叫 `diamwall_v3` 时，白名单一条都不认——旧行为是 0 枚
    // 回灌、下载继续撞墙。兜底带的是同一台主机上的其它 cookie，会话
    // 那两枚仍然不在里面。
    final pick = selectBridgedCookieNames([
      'diamwall_v3',
      'bsrv',
      'remix_userid',
      'remix_userkey',
    ]);
    expect(pick.bridged, ['diamwall_v3', 'bsrv']);
    expect(pick.usedFallback, isTrue);
  });

  test('an empty jar bridges nothing and does not claim a fallback', () {
    final pick = selectBridgedCookieNames(const <String>[]);
    expect(pick.bridged, isEmpty);
    expect(pick.usedFallback, isFalse);
  });

  test('a session-only jar bridges nothing at all', () {
    // 只有会话 cookie 的 jar（解墙没成的形状）绝不能退化成"把会话带上"。
    final pick = selectBridgedCookieNames(['remix_userid']);
    expect(pick.bridged, isEmpty);
    expect(pick.usedFallback, isFalse);
  });
}
