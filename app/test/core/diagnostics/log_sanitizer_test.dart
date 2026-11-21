import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/core/diagnostics/app_logger.dart';
import 'package:watchdog/core/diagnostics/log_sanitizer.dart';
import 'package:watchdog/services/diagnostic_log_service.dart';
import 'package:watchdog/services/op_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LogSanitizer.redactText', () {
    test('掩码全部敏感键（headers / key=value / camelCase）与 Bearer 令牌', () {
      const raw =
          'headers Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.aaa.bbb, '
          'x-api-token: api-key-01, api_token=api-key-02, '
          'session_token=sess-03, sessionToken: sess-04, '
          'access_token=acc-05, unit_code=1001, X-Unit-Code: 2002, '
          'password="p@ss word", secret=sec-06, client_secret=sec-07';

      final clean = LogSanitizer.redactText(raw, isReleaseMode: false);

      for (final leaked in const <String>[
        'eyJhbGciOiJIUzI1NiJ9',
        'api-key-01',
        'api-key-02',
        'sess-03',
        'sess-04',
        'acc-05',
        '1001',
        '2002',
        'p@ss word',
        'sec-06',
        'sec-07',
      ]) {
        expect(clean, isNot(contains(leaked)), reason: '不应泄露: $leaked');
      }
      expect(clean, contains('[REDACTED]'));
      expect(clean, contains('Authorization: [REDACTED]'));
      expect(clean, contains('x-api-token: [REDACTED]'));
      expect(clean, contains('unit_code=[REDACTED]'));
      expect(clean, contains('X-Unit-Code: [REDACTED]'));
      expect(clean, contains('password="[REDACTED]"'));
    });

    test('掩码无键名独立 Bearer 令牌与 Basic 认证头', () {
      const raw =
          'Token failed: Bearer tok_ABC-123.xyz/+= and Authorization: Basic dXNlcjpwYXNz';
      final clean = LogSanitizer.redactText(raw, isReleaseMode: false);

      expect(clean, isNot(contains('tok_ABC-123')));
      expect(clean, isNot(contains('dXNlcjpwYXNz')));
      expect(clean, contains('Bearer [REDACTED]'));
      expect(clean, contains('Authorization: [REDACTED]'));
    });

    test('精确掩码 URL 查询参数并保留非敏感参数', () {
      const url =
          'https://api.example.com/ws?session_token=sess_999&x-unit-code=1001'
          '&api_token=tok_888&device_id=dev-0001&incident_id=42';

      final debugClean = LogSanitizer.redactText(url, isReleaseMode: false);
      expect(
        debugClean,
        'https://api.example.com/ws?session_token=[REDACTED]&x-unit-code=[REDACTED]'
        '&api_token=[REDACTED]&device_id=dev-0001&incident_id=42',
      );

      final releaseClean = LogSanitizer.redactText(url, isReleaseMode: true);
      expect(
        releaseClean,
        'https://api.example.com/ws?session_token=[REDACTED]&x-unit-code=[REDACTED]'
        '&api_token=[REDACTED]&device_id=[REDACTED]&incident_id=42',
      );
    });

    test('掩码 JSON 字符串中的字符串与数字敏感字段', () {
      const jsonText =
          '{"session_token": "tok_abc", "x-api-token": "key_1", '
          '"unit_code": 1001, "access_token": "acc_9", "ok": true}';

      final clean = LogSanitizer.redactText(jsonText, isReleaseMode: false);
      expect(
        clean,
        '{"session_token": "[REDACTED]", "x-api-token": "[REDACTED]", '
        '"unit_code": [REDACTED], "access_token": "[REDACTED]", "ok": true}',
      );
    });

    test('device_id / deviceId / x-device-id 仅在 isReleaseMode=true 时脱敏', () {
      const raw =
          'device_id=dev-a1, deviceId: dev-b2, x-device-id: dev-c3, '
          '{"deviceId": "dev-d4", "x-device-id": "dev-e5"}';

      final debugClean = LogSanitizer.redactText(raw, isReleaseMode: false);
      expect(debugClean, contains('dev-a1'));
      expect(debugClean, contains('dev-b2'));
      expect(debugClean, contains('dev-c3'));
      expect(debugClean, contains('dev-d4'));
      expect(debugClean, contains('dev-e5'));

      final releaseClean = LogSanitizer.redactText(raw, isReleaseMode: true);
      for (final id in const <String>[
        'dev-a1',
        'dev-b2',
        'dev-c3',
        'dev-d4',
        'dev-e5',
      ]) {
        expect(releaseClean, isNot(contains(id)));
      }
      expect(releaseClean, contains('device_id=[REDACTED]'));
      expect(releaseClean, contains('deviceId: [REDACTED]'));
      expect(releaseClean, contains('x-device-id: [REDACTED]'));
    });

    test('重复调用具有幂等性，不破坏括号与结构', () {
      const raw =
          'ApiException(api_token=secret1, Bearer tok2, "password": "pwd")';
      final once = LogSanitizer.redactText(raw, isReleaseMode: true);
      final twice = LogSanitizer.redactText(once, isReleaseMode: true);

      expect(once, twice);
      expect(once, isNot(contains('[REDACTED]]')));
      expect(once, endsWith(')'));
    });
  });

  group('LogSanitizer.redactMap', () {
    test('递归脱敏嵌套 Map、List 与字符串内嵌凭据且不修改原 Map', () {
      final source = <String, dynamic>{
        'session_token': 'sess-123',
        'api_token': 'api-456',
        'x-api-token': 'x-api-789',
        'unit_code': '1001',
        'x-unit-code': '1002',
        'access_token': 'acc-321',
        'password': 'secret-password',
        'secret': 'top-secret',
        'device_id': 'dev-0001',
        'deviceId': 'dev-0002',
        'x-device-id': 'dev-0003',
        'nullable_secret': null,
        'request': <String, dynamic>{
          'url': 'https://api.example.com/api?session_token=inline-tok&ok=1',
          'headers': <String, dynamic>{
            'Authorization': 'Bearer inline-bearer',
            'X-Device-Id': 'dev-0004',
            'Content-Type': 'application/json',
          },
        },
        'items': <dynamic>[
          'Bearer list-bearer-tok',
          <String, dynamic>{'unitCode': '3003', 'stage': 'sync'},
          42,
        ],
      };

      final debugResult = LogSanitizer.redactMap(source, isReleaseMode: false);
      expect(debugResult['session_token'], '[REDACTED]');
      expect(debugResult['api_token'], '[REDACTED]');
      expect(debugResult['x-api-token'], '[REDACTED]');
      expect(debugResult['unit_code'], '[REDACTED]');
      expect(debugResult['x-unit-code'], '[REDACTED]');
      expect(debugResult['access_token'], '[REDACTED]');
      expect(debugResult['password'], '[REDACTED]');
      expect(debugResult['secret'], '[REDACTED]');
      expect(debugResult['nullable_secret'], isNull);
      // 调试模式下保留 device_id
      expect(debugResult['device_id'], 'dev-0001');
      expect(debugResult['deviceId'], 'dev-0002');
      expect(debugResult['x-device-id'], 'dev-0003');

      final debugReq = debugResult['request'] as Map<String, dynamic>;
      expect(
        debugReq['url'],
        'https://api.example.com/api?session_token=[REDACTED]&ok=1',
      );
      final debugHeaders = debugReq['headers'] as Map<String, dynamic>;
      expect(debugHeaders['Authorization'], '[REDACTED]');
      expect(debugHeaders['X-Device-Id'], 'dev-0004');
      expect(debugHeaders['Content-Type'], 'application/json');

      final debugItems = debugResult['items'] as List<dynamic>;
      expect(debugItems[0], 'Bearer [REDACTED]');
      expect((debugItems[1] as Map<String, dynamic>)['unitCode'], '[REDACTED]');
      expect((debugItems[1] as Map<String, dynamic>)['stage'], 'sync');
      expect(debugItems[2], 42);

      // 正式模式下额外脱敏所有 device_id 变体
      final releaseResult = LogSanitizer.redactMap(source, isReleaseMode: true);
      expect(releaseResult['device_id'], '[REDACTED]');
      expect(releaseResult['deviceId'], '[REDACTED]');
      expect(releaseResult['x-device-id'], '[REDACTED]');
      final releaseHeaders =
          (releaseResult['request'] as Map<String, dynamic>)['headers']
              as Map<String, dynamic>;
      expect(releaseHeaders['X-Device-Id'], '[REDACTED]');

      // 原始输入对象未被篡改
      expect(source['session_token'], 'sess-123');
      expect(source['device_id'], 'dev-0001');
    });
  });

  group('AppLogger', () {
    tearDown(AppLogger.resetTestOverrides);

    test('调试模式下输出脱敏日志与脱敏堆栈', () {
      final emitted = <String>[];
      AppLogger.setTestOverrides(sink: emitted.add, isReleaseMode: false);

      AppLogger.log(
        'sync start session_token=tok_1 device_id=dev-1',
        tag: 'Sync',
      );
      AppLogger.error(
        'upload failed',
        tag: 'Sync',
        error: Exception('x-unit-code=1001 Bearer secret_tok'),
        stackTrace: StackTrace.fromString('frame api_token=stack_tok'),
      );

      expect(emitted.length, 3);
      expect(
        emitted[0],
        '[WatchDog][Sync] sync start session_token=[REDACTED] device_id=dev-1',
      );
      expect(emitted[1], contains('[WatchDog][Sync][ERROR] upload failed'));
      expect(emitted[1], isNot(contains('1001')));
      expect(emitted[1], isNot(contains('secret_tok')));
      expect(emitted[2], contains('api_token=[REDACTED]'));
      expect(emitted[2], isNot(contains('stack_tok')));
    });

    test('正式模式下静默 verbose log，error 脱敏 device_id 且不输出堆栈', () {
      final emitted = <String>[];
      AppLogger.setTestOverrides(sink: emitted.add, isReleaseMode: true);

      AppLogger.log('verbose debug trace', tag: 'Sync');
      expect(emitted, isEmpty);

      AppLogger.error(
        'fatal device_id=dev-99',
        tag: 'Auth',
        error: StateError('x-api-token=k99'),
        stackTrace: StackTrace.fromString('secret stack frame'),
      );

      expect(emitted.length, 1);
      expect(emitted.single, contains('device_id=[REDACTED]'));
      expect(emitted.single, contains('x-api-token=[REDACTED]'));
      expect(emitted.single, isNot(contains('dev-99')));
      expect(emitted.single, isNot(contains('k99')));
    });
  });

  group('DiagnosticLogService 与 OpLogService 集成脱敏', () {
    test('DiagnosticLogService.buildEvent 经 LogSanitizer 脱敏正文与面包屑', () {
      final event = DiagnosticLogService.buildEvent(
        error: Exception('session_token=s123 x-unit-code=1001 Bearer b456'),
        source: 'uncaught',
        page: 'board',
        appVersion: '1.22.0+113',
        breadcrumbs: const <Map<String, dynamic>>[
          <String, dynamic>{
            'stage': 'auth',
            'x-api-token': 'crumb-secret',
          },
        ],
        timestamp: 1000,
        sequence: 1,
      );

      expect(event['msg'], isNot(contains('s123')));
      expect(event['msg'], isNot(contains('1001')));
      expect(event['msg'], isNot(contains('b456')));
      final data = event['data'] as Map<String, dynamic>;
      final crumbs = data['breadcrumbs'] as List<dynamic>;
      expect((crumbs.single as Map<String, dynamic>)['x-api-token'], '[REDACTED]');
    });

    test('OpLogService.record 对凭据直接脱敏并保留内容摘要', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = OpLogService.instance;
      addTearDown(() async {
        await service.setSyncEnabled(true);
        await service.clearLocal();
      });
      await service.init();
      await service.setSyncEnabled(false);
      await service.clearLocal();

      service.record(
        'op-redact-1',
        'auth_check',
        '请求失败 session_token=tok_abc Bearer b_xyz',
        data: <String, dynamic>{
          'unit_code': '1001',
          'x-api-token': 'key_abc',
          'text': '示例语音正文',
          'nested': <String, dynamic>{'password': 'pwd', 'ok': true},
        },
        sync: false,
      );

      final entry = service.logs.first;
      expect(entry.msg, isNot(contains('tok_abc')));
      expect(entry.msg, isNot(contains('b_xyz')));
      expect(entry.data?['unit_code'], '[REDACTED]');
      expect(entry.data?['x-api-token'], '[REDACTED]');
      expect(entry.data?['unit_code_sha256'], isNull);
      expect(entry.data?['text_length'], 6);
      expect(entry.data?['text_sha256'], isA<String>());
      expect(
        (entry.data?['nested'] as Map<String, dynamic>)['password'],
        '[REDACTED]',
      );
      expect((entry.data?['nested'] as Map<String, dynamic>)['ok'], isTrue);
    });
  });
}
