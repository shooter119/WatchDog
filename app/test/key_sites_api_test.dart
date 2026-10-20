import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/admin_login.dart';

void main() {
  test('扫码确认使用App独立认证接口POST，取消和确认凭据不进入URL', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((req) async {
      expect(req.method, 'POST');
      expect(req.uri.path, '/api/admin-app/confirm');
      expect(req.uri.hasQuery, isFalse);
      expect(req.headers.value('authorization'), 'Bearer synthetic-session');
      bodies.add(
        Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(req).join()) as Map,
        ),
      );
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"ok":true}');
      await req.response.close();
    });
    final api = ApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      incidentId: '',
      sessionToken: 'synthetic-session',
    );
    try {
      final code = AdminLoginCode.parse(
        'https://fireman119.xyz/admin/scan#12345678-1234-4123-8123-123456789abc.${'a' * 43}',
      )!;
      await api.confirmAdminLogin(code);
      await api.confirmAdminLogin(code, cancel: true);
      expect(bodies.map((body) => body['cancel']), [false, true]);
      expect(
        bodies.every(
          (body) => body['id'] == code.id && body['scan'] == code.scan,
        ),
        isTrue,
      );
    } finally {
      api.dispose();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
  test('真实HTTP请求固定资料版本、附带认证且资源路径拒绝外站URL，认证失败通知控制器', () async {
    final requests = <Uri>[];
    final authHeaders = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((req) async {
      await req.drain();
      requests.add(req.uri);
      authHeaders.add(req.headers.value('authorization'));
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path.endsWith('/access')) {
        req.response.statusCode = 401;
        req.response.write(
          jsonEncode({'code': 'KEY_SITE_AUTH_REQUIRED', 'error': '成员已停用'}),
        );
      } else if (req.uri.path.contains('/versions/')) {
        req.response.write(
          jsonEncode({
            'site_id': 'site-a',
            'version': 3,
            'latestVersion': 4,
            'published_at': 1,
            'active': true,
            'profile': {'name': '样例'},
            'content': {},
            'attachments': [],
          }),
        );
      } else {
        req.response.write(jsonEncode({'sites': [], 'hasMore': false}));
      }
      await req.response.close();
    });
    ApiException? invalidated;
    final api = ApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      incidentId: '',
      unitId: 'u',
      sessionToken: 'test-session',
      onAuthenticationFailure: (error) => invalidated = error,
    );
    try {
      await api.fetchKeySites(
        search: '医院 & 商场',
        district: '东区',
        type: '医院',
        offset: 20,
      );
      expect(requests.last.queryParameters['q'], '医院 & 商场');
      expect(requests.last.queryParameters['offset'], '20');
      final version = await api.fetchKeySite(
        'site-a',
        version: 3,
        incident: 'historic',
      );
      expect(version.version, 3);
      expect(requests.last.path, '/api/key-sites/site-a/versions/3');
      expect(requests.last.queryParameters['incidentId'], 'historic');
      await expectLater(
        api.fetchKeySiteImage(
          'site-a',
          3,
          'attachment',
          resource: 'https://evil.test/steal',
        ),
        throwsArgumentError,
      );
      expect(requests.length, 2);
      expect(authHeaders, everyElement('Bearer test-session'));
      await expectLater(api.keySiteAccess(), throwsA(isA<ApiException>()));
      expect(invalidated?.code, 'KEY_SITE_AUTH_REQUIRED');
      // Ordinary App sessions are sent only as headers; never in URI or localStorage.
      expect(
        requests.any((uri) => uri.toString().contains('test-session')),
        isFalse,
      );
    } finally {
      api.dispose();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}
