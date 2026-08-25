import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';

void main() {
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
}
