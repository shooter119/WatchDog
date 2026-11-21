import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:watchdog/core/diagnostics/log_repository.dart';
import 'package:watchdog/core/models/amap_location.dart';
import 'package:watchdog/core/models/incident_key_site_link.dart';
import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/core/sync/sync_repository.dart';

class _TrackingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;
  int closeCount = 0;

  _TrackingClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);

  @override
  void close() {
    closeCount++;
    super.close();
  }
}

http.StreamedResponse _jsonStreamResponse(
  Object body, {
  int statusCode = 200,
  Map<String, String> headers = const {},
}) {
  final bytes = utf8.encode(jsonEncode(body));
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    statusCode,
    headers: {'content-type': 'application/json', ...headers},
  );
}

void main() {
  group('ApiConfig', () {
    test('构造请求头、UTF-8 实名 Base64、opHeaders、cacheScope 与派生配置', () {
      ApiException? capturedAuthError;
      final config = ApiConfig(
        baseUrl: 'https://api.example.test',
        incidentId: 'inc-1',
        apiToken: 'api-tok',
        deviceId: 'dev-1',
        actorName: '张三',
        unitId: 'unit-1',
        unitCode: '1001',
        sessionToken: 'sess-1',
        onAuthenticationFailure: (err) => capturedAuthError = err,
      );

      final headers = config.headers;
      expect(headers['Content-Type'], 'application/json');
      expect(headers['X-Incident-Id'], 'inc-1');
      expect(headers['X-Api-Token'], 'api-tok');
      expect(headers['Authorization'], 'Bearer sess-1');
      expect(headers['X-Device-Id'], 'dev-1');
      expect(headers['X-Unit-Id'], 'unit-1');
      expect(headers['X-Unit-Code'], '1001');
      expect(headers['X-Actor-Name-B64'], base64Encode(utf8.encode('张三')));
      expect(utf8.decode(base64Decode(headers['X-Actor-Name-B64']!)), '张三');

      expect(config.opHeaders(null).containsKey('X-Op-Id'), isFalse);
      expect(config.opHeaders('').containsKey('X-Op-Id'), isFalse);
      expect(config.opHeaders('op-42')['X-Op-Id'], 'op-42');

      expect(config.cacheScope, 'https://api.example.test|unit-1|张三');

      final otherIncident = config.forIncident('inc-2');
      expect(otherIncident.incidentId, 'inc-2');
      expect(otherIncident.baseUrl, config.baseUrl);
      expect(otherIncident.actorName, '张三');
      expect(otherIncident.sessionToken, 'sess-1');
      otherIncident.onAuthenticationFailure?.call(ApiException('expired'));
      expect(capturedAuthError?.message, 'expired');

      final assistant = config.forAssistant();
      expect(assistant.incidentId, '');
      expect(assistant.headers.containsKey('X-Incident-Id'), isFalse);
      expect(assistant.sessionToken, 'sess-1');

      expect(
        config.uri('/api/sync/checkpoint').toString(),
        'https://api.example.test/api/sync/checkpoint',
      );
    });

    test('空 unitId 时 cacheScope 为空且拒绝不安全非本地 HTTP 地址', () {
      const bare = ApiConfig(
        baseUrl: 'http://example.test',
        incidentId: '',
      );
      expect(bare.cacheScope, '');
      expect(bare.headers, {'Content-Type': 'application/json'});
      expect(() => bare.uri('/api/logs'), throwsStateError);
    });
  });

  group('ApiException 与错误解码', () {
    test('isApiAuthenticationFailure 精确识别 4 类认证失败码', () {
      for (final code in const [
        'SESSION_REQUIRED',
        'SESSION_INVALID',
        'SESSION_EXPIRED',
        'KEY_SITE_AUTH_REQUIRED',
      ]) {
        final err = ApiException('auth failed', statusCode: 401, code: code);
        expect(isApiAuthenticationFailure(err), isTrue);
        expect(err.toString(), 'auth failed');
      }
      expect(
        isApiAuthenticationFailure(
          ApiException('forbidden', statusCode: 403, code: 'FORBIDDEN'),
        ),
        isFalse,
      );
      expect(isApiAuthenticationFailure(StateError('other')), isFalse);
    });

    test('decodeJson、apiException 与 streamedApiException 保持错误语义与回调', () {
      ApiException? authError;
      final transport = ApiHttpTransport(
        ApiConfig(
          baseUrl: 'https://api.example.test',
          incidentId: 'inc-1',
          onAuthenticationFailure: (err) => authError = err,
        ),
        clientFactory: () => _TrackingClient((_) async => _jsonStreamResponse({})),
      );
      addTearDown(transport.dispose);

      expect(
        () => transport.decodeJson(
          http.Response('<html>503</html>', 503),
          fallback: '加载失败',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'INVALID_JSON')
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', '服务器暂时不可用，请稍后重试（HTTP 503）'),
        ),
      );

      final apiErr = transport.apiException(
        http.Response('{}', 401, headers: {'x-request-id': 'req-1'}),
        body: {
          'error': '会话已过期',
          'code': 'SESSION_EXPIRED',
          'current': {'version': 3},
          'suggestions': [' 建议1 ', '', '建议2', '建议3', '建议4'],
        },
        fallback: '请求失败',
      );
      expect(apiErr.message, '会话已过期');
      expect(apiErr.code, 'SESSION_EXPIRED');
      expect(apiErr.requestId, 'req-1');
      expect(apiErr.current, {'version': 3});
      expect(apiErr.suggestions, ['建议1', '建议2', '建议3']);
      expect(identical(authError, apiErr), isTrue);

      authError = null;
      final streamed = http.StreamedResponse(
        const Stream.empty(),
        401,
        headers: {'x-request-id': 'req-stream'},
      );
      final streamedErr = transport.streamedApiException(
        streamed,
        jsonEncode({'error': '未登录', 'code': 'SESSION_REQUIRED'}),
        fallback: '提问失败',
      );
      expect(streamedErr.code, 'SESSION_REQUIRED');
      expect(streamedErr.requestId, 'req-stream');
      expect(identical(authError, streamedErr), isTrue);
    });
  });

  group('SseLineParser', () {
    test('跨 chunk 缓冲半行并正确解析 content、error、DONE 与忽略无效行', () {
      final parser = SseLineParser();
      expect(parser.push('event: ping\n: keepalive\ndata: {"con'), isEmpty);

      final batch = parser.push(
        'tent":"火势"}\ndata: not-json\ndata: {"content":"已控制"}\n'
        'data: {"error":"限流"}\ndata: [DONE]\n',
      );
      expect(batch.length, 4);
      expect(batch[0].content, '火势');
      expect(batch[0].done, isFalse);
      expect(batch[1].content, '已控制');
      expect(batch[2].error, '限流');
      expect(batch[3].done, isTrue);
    });
  });

  group('ApiHttpTransport 生命周期与重试', () {
    test('openChatClient / cancelChatRequest / releaseChatClient 与 dispose 清理全部资源', () async {
      final created = <_TrackingClient>[];
      final transport = ApiHttpTransport(
        const ApiConfig(baseUrl: 'https://api.example.test', incidentId: 'inc-1'),
        clientFactory: () {
          final c = _TrackingClient((_) async => _jsonStreamResponse({}));
          created.add(c);
          return c;
        },
      );

      expect(created.length, 1);
      final chat1 = transport.openChatClient() as _TrackingClient;
      expect(created.length, 2);
      transport.cancelChatRequest();
      expect(chat1.closeCount, 1);
      transport.releaseChatClient(chat1);
      expect(chat1.closeCount, 2);

      final chat2 = transport.openChatClient() as _TrackingClient;
      expect(created.length, 3);

      transport.dispose();
      expect(transport.isDisposed, isTrue);
      expect(created[0].closeCount, 1);
      expect(chat2.closeCount, 1);

      final cpUri = Uri.parse('https://api.example.test/api/sync/checkpoint');
      final authUri = Uri.parse('https://api.example.test/api/auth/verify');
      expect(() => transport.client, throwsStateError);
      expect(() => transport.openChatClient(), throwsStateError);
      await expectLater(transport.requestJsonMap('/api/admin-app/capability'), throwsStateError);
      await expectLater(transport.requestJsonList('/api/unit-stations'), throwsStateError);
      await expectLater(
        transport.withIdempotentSyncRetry(cpUri, (c) => c.get(cpUri), timeout: const Duration(seconds: 5)),
        throwsStateError,
      );
      await expectLater(
        transport.withTransientRetry((c) => c.post(authUri), timeout: const Duration(seconds: 5)),
        throwsStateError,
      );
    });

    test('dispose 时立即取消在途重试定时器并关闭短寿命客户端', () async {
      final created = <_TrackingClient>[];
      var calls = 0;
      final enteredDelay = Completer<void>();

      final transport = ApiHttpTransport(
        const ApiConfig(baseUrl: 'http://127.0.0.1:8080', incidentId: 'inc-1'),
        clientFactory: () {
          final c = _TrackingClient((_) async {
            calls++;
            if (!enteredDelay.isCompleted) enteredDelay.complete();
            return _jsonStreamResponse({'error': 'gateway'}, statusCode: 503);
          });
          created.add(c);
          return c;
        },
      );

      final bootUri = Uri.parse('http://127.0.0.1:8080/api/sync/bootstrap');
      final future = transport.withIdempotentSyncRetry(
        bootUri,
        (c) => c.get(bootUri),
        timeout: const Duration(seconds: 5),
      );

      await enteredDelay.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      transport.dispose();

      await expectLater(future, throwsStateError);
      expect(calls, 1);
      expect(created.first.closeCount, 1);
    });

    test('withIdempotentSyncRetry 与 withTransientRetry 遇 503 退避重试并在 finally 关闭短寿命客户端', () async {
      final created = <_TrackingClient>[];
      var syncAttempt = 0;
      var transientAttempt = 0;
      final transport = ApiHttpTransport(
        const ApiConfig(baseUrl: 'http://127.0.0.1:8080', incidentId: 'inc-1'),
        clientFactory: () {
          final c = _TrackingClient((req) async {
            if (req.url.path == '/api/auth/verify') {
              transientAttempt++;
              return transientAttempt == 1
                  ? _jsonStreamResponse({'error': 'busy'}, statusCode: 502)
                  : _jsonStreamResponse({'verified': true});
            }
            syncAttempt++;
            return syncAttempt == 1
                ? _jsonStreamResponse({'error': 'busy'}, statusCode: 503)
                : _jsonStreamResponse({'ok': true});
          });
          created.add(c);
          return c;
        },
      );
      addTearDown(transport.dispose);

      final cpUri = Uri.parse('http://127.0.0.1:8080/api/sync/checkpoint');
      final res = await transport.withIdempotentSyncRetry(
        cpUri,
        (c) => c.get(cpUri),
        timeout: const Duration(seconds: 5),
      );
      expect(res.statusCode, 200);
      expect(syncAttempt, 2);
      expect(created[0].closeCount, 0);
      expect(created[1].closeCount, 1);

      final verifyUri = Uri.parse('http://127.0.0.1:8080/api/auth/verify');
      final verifyRes = await transport.withTransientRetry(
        (c) => c.post(verifyUri),
        timeout: const Duration(seconds: 5),
      );
      expect(verifyRes.statusCode, 200);
      expect(transientAttempt, 2);
      expect(created[2].closeCount, 1);
      expect(created[3].closeCount, 1);
    });

    test('合成测试主机遇传输异常立即重抛不退避；requestJsonMap 支持 requireStatus200', () async {
      var calls = 0;
      final transport = ApiHttpTransport(
        const ApiConfig(
          baseUrl: 'http://127.0.0.1:8080',
          incidentId: 'inc-1',
        ),
        clientFactory: () => _TrackingClient((req) async {
          if (req.url.host == 'offline') {
            calls++;
            throw const SocketException('unreachable');
          }
          if (req.url.path == '/api/admin-app/capability') {
            return _jsonStreamResponse({'member': null}, statusCode: 201);
          }
          return _jsonStreamResponse([
            {'id': 's1'},
          ]);
        }),
      );
      addTearDown(transport.dispose);

      await expectLater(
        transport.withIdempotentSyncRetry(
          Uri.parse('http://offline/api/sync/bootstrap'),
          (c) => c.get(Uri.parse('http://offline/api/sync/bootstrap')),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 1);

      await expectLater(
        transport.requestJsonMap(
          '/api/admin-app/capability',
          fallback: '资料加载失败',
          requireStatus200: true,
        ),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '资料加载失败（HTTP 201）'),
        ),
      );

      final list = await transport.requestJsonList('/api/unit-stations');
      expect(list, [
        {'id': 's1'},
      ]);
    });
  });

  group('Core 模型与 SyncRepository / LogRepository', () {
    test('AmapLocation 与 IncidentKeySiteLink 保持反序列化语义', () {
      expect(AmapLocation.fromJson('invalid'), isNull);
      final loc = AmapLocation.fromJson({'lat': 30.5, 'lon': 120.2});
      expect(loc?.lat, 30.5);
      expect(loc?.lon, 120.2);
      expect(loc?.coordinate, 'gcj02');

      final link = IncidentKeySiteLink.fromJson({
        'siteId': 'ks-1',
        'name': '示例化工厂',
        'address': '示例路 1 号',
        'version': 2,
        'linkedBy': 'u-1',
        'linkedByName': '李四',
        'linkedAt': 1700000000,
      });
      expect(link.siteId, 'ks-1');
      expect(link.version, 2);
      expect(link.linkedByName, '李四');
    });

    test('SyncRepository 7 个方法与 LogRepository.sendLogs 语义一致', () async {
      final recorded = <String>[];
      Map<String, dynamic>? lastReviewedBody;
      final transport = ApiHttpTransport(
        const ApiConfig(
          baseUrl: 'https://api.example.test',
          incidentId: 'inc-9',
          actorName: '张三',
          sessionToken: 'tok-9',
        ),
        clientFactory: () => _TrackingClient((req) async {
          recorded.add('${req.method} ${req.url.path}?${req.url.query}');
          if (req.url.path == '/api/sync/bootstrap') {
            return _jsonStreamResponse({'cursors': {'unit': '1'}});
          }
          if (req.url.path == '/api/sync/checkpoint') {
            return _jsonStreamResponse({'unit': '2', 'incident': '3'});
          }
          if (req.url.path == '/api/sync/events') {
            return _jsonStreamResponse({
              'events': [
                {'seq': 1},
              ],
            });
          }
          if (req.url.path == '/api/entries/e-1' && req.method == 'PATCH') {
            final bytes = await req.finalize().toBytes();
            lastReviewedBody =
                jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
            return _jsonStreamResponse({'ok': true});
          }
          if (req.url.path == '/api/incidents/inc-9/offline-operations') {
            return _jsonStreamResponse({'applied': 1});
          }
          if (req.url.path == '/api/logs') {
            return _jsonStreamResponse({'ok': true});
          }
          return _jsonStreamResponse({'error': 'not found'}, statusCode: 404);
        }),
      );
      addTearDown(transport.dispose);

      final syncRepo = SyncRepository(transport);
      expect(
        syncRepo.realtimeSyncUri().toString(),
        'wss://api.example.test/api/realtime',
      );
      expect(syncRepo.realtimeSyncHeaders()['Authorization'], 'Bearer tok-9');

      final boot = await syncRepo.fetchSyncBootstrap(forIncidentId: 'inc-9');
      expect((boot['cursors'] as Map)['unit'], '1');

      final cp = await syncRepo.fetchSyncCheckpoint(forIncidentId: 'inc-9');
      expect(cp['incident'], '3');

      final events = await syncRepo.fetchSyncEvents(
        unitCursor: '1',
        incidentCursor: '2',
        limit: 999,
      );
      expect(events, [
        {'seq': 1},
      ]);

      await syncRepo.submitReviewedOperation(
        type: 'pressure',
        payload: {'entry_id': 'e-1', 'predecessor_op_id': 'old'},
        originalOpId: 'op-orig',
        newOpId: 'op-new',
        expectedVersion: 4,
      );
      expect(lastReviewedBody?['reviewed_client_op_id'], 'op-orig');
      expect(lastReviewedBody?['expected_version'], 4);
      expect(lastReviewedBody?.containsKey('predecessor_op_id'), isFalse);

      final uploaded = await syncRepo.uploadOfflineOperations([
        {'type': 'note'},
      ]);
      expect(uploaded['applied'], 1);

      final logRepo = LogRepository(transport);
      await logRepo.sendLogs([
        {'stage': 'test', 'level': 'info'},
      ]);
      expect(recorded.last, 'POST /api/logs?');
    });
  });
}
