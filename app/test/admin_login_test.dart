import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/admin_login.dart';
import 'package:watchdog/state/app_controller.dart';

const _capability = AdminCapability(
  memberId: 'm',
  name: '合成成员',
  unitName: '合成消防单位',
  unitRole: 'admin',
  role: 'unit_admin',
);

final _qr =
    'https://fireman119.xyz/admin/scan#12345678-1234-4123-8123-123456789abc.${'a' * 43}';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test', incidentId: '');
  AdminCapability? grant = _capability;

  @override
  Future<AdminCapability?> fetchAdminCapability() async => grant;
}

class _DelayedApi extends _Api {
  final requests = <Completer<AdminCapability?>>[];

  @override
  Future<AdminCapability?> fetchAdminCapability() {
    final request = Completer<AdminCapability?>();
    requests.add(request);
    return request.future;
  }
}

class _Controller extends AppController {
  bool allowed = true;
  bool guest = false;
  int epoch = 0;

  _Controller(_Api client) {
    api = client;
    adminCapability = client.grant;
  }

  @override
  bool get canReadKeySites => allowed && !guest;

  @override
  bool get isGuest => guest;

  @override
  bool get needsAuthentication => !allowed;

  @override
  bool get protectedDataRevoked => !allowed;

  @override
  int get protectedDataEpoch => epoch;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('扫码严格匹配本站规范，不接受跨站、跳转、端口或额外内容', () {
    expect(
      AdminLoginCode.parse(_qr)?.id,
      '12345678-1234-4123-8123-123456789abc',
    );
    for (final invalid in [
      _qr.replaceFirst('https:', 'http:'),
      _qr.replaceFirst('fireman119.xyz', 'fireman119.xyz.evil.test'),
      _qr.replaceFirst('/admin/scan', '/admin/scan?next=evil'),
      _qr.replaceFirst('xyz/', 'xyz:443/'),
      '$_qr\n',
      '$_qr.extra',
      'javascript:alert(1)',
      'https://example.test',
    ]) {
      expect(AdminLoginCode.parse(invalid), isNull, reason: '非规范二维码必须拒绝');
    }
  });

  test('后台权限请求乱序时，迟到的旧授权不能覆盖已撤销状态', () async {
    final api = _DelayedApi();
    final controller = _Controller(api);
    addTearDown(() {
      controller.dispose();
      api.dispose();
    });
    final first = controller.refreshAdminCapability();
    final second = controller.refreshAdminCapability();
    api.requests[1].complete(null);
    await second;
    expect(controller.adminCapability, isNull);
    api.requests[0].complete(_capability);
    await first;
    expect(controller.adminCapability, isNull);
  });
}
