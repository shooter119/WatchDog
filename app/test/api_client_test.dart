import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';

class _JsonFixture {
  final ApiClient api;
  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;

  _JsonFixture(this.api, this.server, this.subscription);

  Future<void> close() async {
    api.dispose();
    await subscription.cancel();
    await server.close(force: true);
  }
}

Future<_JsonFixture> _jsonFixture({
  required int statusCode,
  required Object responseBody,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    await request.drain();
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(responseBody));
    await request.response.close();
  });
  final api = ApiClient(
    baseUrl: 'http://${server.address.address}:${server.port}',
    incidentId: 'incident-for-test',
  );
  return _JsonFixture(api, server, subscription);
}

void main() {
  test(
    'incident list and object methods accept their expected top-level shapes',
    () async {
      const incident = {
        'id': 'incident-1',
        'number': '2026-001',
        'status': 'active',
        'created_at': 1,
        'last_activity_at': 1,
      };
      final listFixture = await _jsonFixture(
        statusCode: 200,
        responseBody: [incident],
      );
      final createFixture = await _jsonFixture(
        statusCode: 201,
        responseBody: incident,
      );
      final fetchFixture = await _jsonFixture(
        statusCode: 200,
        responseBody: incident,
      );
      addTearDown(listFixture.close);
      addTearDown(createFixture.close);
      addTearDown(fetchFixture.close);

      expect((await listFixture.api.fetchIncidents()).single.id, 'incident-1');
      expect(
        (await createFixture.api.createIncident(realName: '测试人员')).id,
        'incident-1',
      );
      expect(
        (await fetchFixture.api.fetchIncident('incident-1')).id,
        'incident-1',
      );
    },
  );

  test(
    'fetchIncidents rejects a successful non-list response as ApiException',
    () async {
      final fixture = await _jsonFixture(
        statusCode: 200,
        responseBody: {'incident': <String, dynamic>{}},
      );
      addTearDown(fixture.close);

      await expectLater(
        fixture.api.fetchIncidents(),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 200)
              .having((error) => error.code, 'code', 'INVALID_RESPONSE_SHAPE'),
        ),
      );
    },
  );

  test(
    'createIncident rejects a successful non-map response as ApiException',
    () async {
      final fixture = await _jsonFixture(statusCode: 201, responseBody: []);
      addTearDown(fixture.close);

      await expectLater(
        fixture.api.createIncident(realName: '测试人员'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 201)
              .having((error) => error.code, 'code', 'INVALID_RESPONSE_SHAPE'),
        ),
      );
    },
  );

  test(
    'fetchIncident rejects a successful non-map response as ApiException',
    () async {
      final fixture = await _jsonFixture(statusCode: 200, responseBody: []);
      addTearDown(fixture.close);

      await expectLater(
        fixture.api.fetchIncident('incident-1'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 200)
              .having((error) => error.code, 'code', 'INVALID_RESPONSE_SHAPE'),
        ),
      );
    },
  );

  test('fetchIncident preserves HTTP error status and server code', () async {
    final fixture = await _jsonFixture(
      statusCode: 403,
      responseBody: {'error': '无权访问', 'code': 'FORBIDDEN'},
    );
    addTearDown(fixture.close);

    await expectLater(
      fixture.api.fetchIncident('incident-1'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 403)
            .having((error) => error.code, 'code', 'FORBIDDEN'),
      ),
    );
  });

  test('markExited preserves HTTP error status and server code', () async {
    final fixture = await _jsonFixture(
      statusCode: 409,
      responseBody: {'error': '记录已出场', 'code': 'ENTRY_ALREADY_EXITED'},
    );
    addTearDown(fixture.close);

    await expectLater(
      fixture.api.markExited('entry-1'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 409)
            .having((error) => error.code, 'code', 'ENTRY_ALREADY_EXITED'),
      ),
    );
  });

  test('non-JSON gateway errors become structured ApiException', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = 503
        ..headers.contentType = ContentType.html
        ..write('<html><body>upstream unavailable</body></html>');
      await request.response.close();
    });
    final api = ApiClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      incidentId: 'incident-for-test',
    );
    addTearDown(() async {
      api.dispose();
      await subscription.cancel();
      await server.close(force: true);
    });

    await expectLater(
      api.fetchIncident('incident-1'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 503)
            .having((error) => error.code, 'code', 'INVALID_JSON'),
      ),
    );
  });

  test('fetchIncidents 聚合服务端分页且限制请求页数', () async {
    const incident = {
      'id': 'incident-page',
      'number': '2026-001',
      'status': 'active',
      'created_at': 1,
      'last_activity_at': 1,
    };
    final offsets = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await request.drain();
      offsets.add(request.uri.queryParameters['offset'] ?? '');
      final offset = int.parse(offsets.last);
      final body = offset == 0
          ? List<Map<String, dynamic>>.generate(100, (index) {
              return {...incident, 'id': 'incident-$index'};
            })
          : [incident];
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });
    final api = ApiClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      incidentId: 'incident-for-test',
    );
    addTearDown(() async {
      api.dispose();
      await subscription.cancel();
      await server.close(force: true);
    });

    final incidents = await api.fetchIncidents(status: 'active');
    expect(incidents, hasLength(101));
    expect(offsets, ['0', '100']);
  });

  test('认证重试不会关闭同时进行的共享同步请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entriesStarted = Completer<void>();
    final releaseEntries = Completer<void>();
    var verifyAttempts = 0;
    final subscription = server.listen((request) async {
      await request.drain();
      if (request.uri.path == '/api/entries') {
        if (!entriesStarted.isCompleted) entriesStarted.complete();
        await releaseEntries.future;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('[]');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/api/auth/verify') {
        verifyAttempts++;
        request.response
          ..statusCode = verifyAttempts == 1 ? 503 : 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(
              verifyAttempts == 1
                  ? {'error': '暂时不可用'}
                  : {'unit_id': 'unit-a', 'session_token': 'session-a'},
            ),
          );
        await request.response.close();
      }
    });
    final api = ApiClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      incidentId: 'incident-a',
    );
    addTearDown(() async {
      api.dispose();
      await subscription.cancel();
      await server.close(force: true);
    });

    final entries = api.fetchEntries();
    await entriesStarted.future;
    final verification = api.verifyUnit(
      unitName: '测试单位',
      unitCode: '1234',
      realName: '测试人员',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    releaseEntries.complete();

    expect(await entries, isEmpty);
    expect((await verification)['session_token'], 'session-a');
    expect(verifyAttempts, 2);
  });

  test(
    'addFirefighter distinguishes inserted and duplicate responses',
    () async {
      final inserted = await _jsonFixture(statusCode: 201, responseBody: {});
      final duplicate = await _jsonFixture(statusCode: 409, responseBody: {});
      addTearDown(inserted.close);
      addTearDown(duplicate.close);

      expect(await inserted.api.addFirefighter('张伟'), isTrue);
      expect(await duplicate.api.addFirefighter('张伟'), isFalse);
    },
  );

  test(
    'fetchTimeline rejects a successful response with malformed events',
    () async {
      final fixture = await _jsonFixture(
        statusCode: 200,
        responseBody: {
          'events': {'id': 'not-a-list'},
        },
      );
      addTearDown(fixture.close);

      await expectLater(
        fixture.api.fetchTimeline('incident-1'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 200)
              .having((error) => error.code, 'code', 'INVALID_RESPONSE_SHAPE'),
        ),
      );
    },
  );

  test('完整警情简报发送给模型时带现场研判任务，原文由页面保留', () async {
    final requestBody = Completer<Map<String, dynamic>>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requestBody.complete(body);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'reply': '结论：先确认现场人员安全', 'created_at': 1}))
        ..close();
    });
    final api = ApiClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      incidentId: '',
    );
    addTearDown(() async {
      api.dispose();
      await subscription.cancel();
      await server.close(force: true);
    });

    const incident = '江山市消防支队接到警情：居民家中发现一条蛇，出动1车7人，请求到场处置。';
    final reply = await api.sendChatMessage(incident);
    final body = await requestBody.future;

    expect(reply.content, contains('先确认现场人员安全'));
    expect(body['message'], contains('真实的现场警情简报'));
    expect(body['message'], contains(incident));
  });

  test('会话令牌使用 Bearer 头并由警情/辅助派生客户端保留', () async {
    final authorizationHeaders = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await request.drain();
      authorizationHeaders.add(request.headers.value('authorization'));
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('[]');
      await request.response.close();
    });
    final api = ApiClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      incidentId: 'incident-a',
      sessionToken: 'session-token-123',
    );
    final incidentApi = api.forIncident('incident-b');
    final assistantApi = api.forAssistant();
    addTearDown(() async {
      api.dispose();
      incidentApi.dispose();
      assistantApi.dispose();
      await subscription.cancel();
      await server.close(force: true);
    });

    expect(incidentApi.sessionToken, 'session-token-123');
    expect(assistantApi.sessionToken, 'session-token-123');
    await incidentApi.fetchIncidents();
    await assistantApi.fetchIncidents();

    expect(authorizationHeaders, [
      'Bearer session-token-123',
      'Bearer session-token-123',
    ]);
  });
}
