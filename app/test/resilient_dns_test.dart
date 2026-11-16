import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/services/resilient_dns.dart';

Future<void> _instantDelay(Duration _) async {}

class _RealHttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      'DIRECT';
}

Future<T> _withRealHttp<T>(Future<T> Function() fn) =>
    HttpOverrides.runWithHttpOverrides(fn, _RealHttpOverrides());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ResilientDnsResolver.instance.invalidate('api.example.com');
  });

  group('ResilientDnsResolver.shouldBypass', () {
    test('绕过空主机、IP 字面量、单标签测试主机与局部保留后缀', () {
      for (final host in [
        '',
        '   ',
        'localhost',
        'LOCALHOST',
        '127.0.0.1',
        '::1',
        '[::1]',
        'offline',
        'test',
        'rec',
        'foo.test',
        'FOO.TEST',
        'bar.local',
        'sub.localhost',
        'demo.invalid',
      ]) {
        expect(
          ResilientDnsResolver.shouldBypass(host),
          isTrue,
          reason: 'host=$host',
        );
      }

      expect(ResilientDnsResolver.shouldBypass('api.fireman119.xyz'), isFalse);
      expect(ResilientDnsResolver.shouldBypass('api.example.com'), isFalse);
    });
  });

  group('ResilientDnsResolver.isPublicRoutableIp', () {
    test('拒绝私网、回环、Fake-IP 198.18/15、CGNAT、文档网段与非公网 IPv6', () {
      for (final ip in [
        '0.0.0.0',
        '10.0.0.1',
        '100.64.0.1',
        '100.127.255.254',
        '127.0.0.1',
        '169.254.1.1',
        '172.16.0.1',
        '172.31.255.254',
        '192.0.0.1',
        '192.0.2.1',
        '192.168.1.1',
        '198.18.0.53',
        '198.19.255.254',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '255.255.255.255',
        '::',
        '::1',
        'fe80::1',
        'ff02::1',
        'fc00::1',
        'fd12:3456::1',
        '100::1',
        '2001:db8::1',
        '::ffff:198.18.0.53',
        '::ffff:127.0.0.1',
      ]) {
        expect(
          ResilientDnsResolver.isPublicRoutableIp(InternetAddress(ip)),
          isFalse,
          reason: 'ip=$ip',
        );
      }

      for (final ip in [
        '93.184.216.34',
        '120.27.153.83',
        '198.20.0.1',
        '100.63.255.254',
        '2606:4700:4700::1111',
      ]) {
        expect(
          ResilientDnsResolver.isPublicRoutableIp(InternetAddress(ip)),
          isTrue,
          reason: 'ip=$ip',
        );
      }
    });
  });

  group('ResilientDnsResolver 多阶段解析与缓存策略', () {
    test('并发解析同一主机合并为单次系统查询（In-flight Coalescing）', () async {
      var lookupCount = 0;
      final gate = Completer<List<InternetAddress>>();
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) {
          lookupCount++;
          return gate.future;
        },
        delay: _instantDelay,
      );

      final futures = <Future<List<InternetAddress>>>[
        for (var i = 0; i < 10; i++)
          resolver.resolve(i.isEven ? 'api.example.com' : 'API.EXAMPLE.COM'),
      ];

      expect(lookupCount, 1);
      gate.complete([
        InternetAddress('2606:4700:4700::1111'),
        InternetAddress('93.184.216.34'),
      ]);

      final results = await Future.wait(futures);
      for (final addrs in results) {
        expect(addrs.map((a) => a.address), [
          '93.184.216.34',
          '2606:4700:4700::1111',
        ]);
      }
      expect(lookupCount, 1);

      // 进行中的普通查询被 invalidate 后不会污染新查询缓存。
      final staleGate = Completer<List<InternetAddress>>();
      final freshGate = Completer<List<InternetAddress>>();
      var phase = 0;
      final r2 = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) {
          phase++;
          return phase == 1 ? staleGate.future : freshGate.future;
        },
        delay: _instantDelay,
      );
      final staleFuture = r2.resolve('api.example.com');
      r2.invalidate('api.example.com');
      final freshFuture = r2.resolve('api.example.com');
      staleGate.complete([InternetAddress('198.18.0.53')]);
      freshGate.complete([InternetAddress('93.184.216.34')]);
      expect((await staleFuture).single.address, '198.18.0.53');
      expect((await freshFuture).single.address, '93.184.216.34');
      expect((await r2.resolve('api.example.com')).single.address, '93.184.216.34');
      expect(phase, 2);
    });

    test('Stage 1 遇到 EAI_NODATA (errno=7) 时退避并降级至 Stage 2 IPv4 查询', () async {
      final calls = <InternetAddressType>[];
      final delays = <Duration>[];
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) async {
          calls.add(type);
          if (type == InternetAddressType.any) {
            throw const SocketException(
              "Failed host lookup: 'api.example.com'",
              osError: OSError('No address associated with hostname', 7),
            );
          }
          return [InternetAddress('93.184.216.34')];
        },
        dohLookup: (_) async => throw StateError('DoH 不应被触发'),
        delay: (duration) async => delays.add(duration),
      );

      final result = await resolver.resolve('api.example.com');
      expect(calls, [InternetAddressType.any, InternetAddressType.IPv4]);
      expect(delays, [const Duration(milliseconds: 150)]);
      expect(result.single.address, '93.184.216.34');
    });

    test('系统查询全失败时降级至 Stage 3 DoH 并过滤所有非公网 IP', () async {
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) async {
          throw const SocketException(
            "Failed host lookup: 'api.example.com'",
            osError: OSError('No address associated with hostname', 7),
          );
        },
        dohLookup: (host) async => [
          InternetAddress('198.18.0.53'),
          InternetAddress('192.168.1.1'),
          InternetAddress('10.0.0.1'),
          InternetAddress('127.0.0.1'),
          InternetAddress('100.64.0.1'),
          InternetAddress('93.184.216.34'),
        ],
        delay: _instantDelay,
      );

      final result = await resolver.resolve('api.example.com');
      expect(result.map((a) => a.address), ['93.184.216.34']);
    });

    test('parseDohJsonResponse 只保留 Status=0 且 type=1 的公网 A 记录', () {
      final parsed = ResilientDnsResolver.parseDohJsonResponse(
        jsonEncode({
          'Status': 0,
          'Answer': [
            {'name': 'api.example.com', 'type': 5, 'data': 'cdn.example.com.'},
            {'name': 'api.example.com', 'type': 1, 'data': '198.18.0.53'},
            {'name': 'api.example.com', 'type': 1, 'data': '192.168.1.1'},
            {'name': 'api.example.com', 'type': 1, 'data': '10.0.0.1'},
            {'name': 'api.example.com', 'type': 1, 'data': '127.0.0.1'},
            {'name': 'api.example.com', 'type': 1, 'data': '100.64.0.1'},
            {'name': 'api.example.com', 'type': 28, 'data': '2606:4700:4700::1111'},
            {'name': 'api.example.com', 'type': 1, 'data': '93.184.216.34'},
          ],
        }),
      );
      expect(parsed.map((a) => a.address), ['93.184.216.34']);

      expect(
        ResilientDnsResolver.parseDohJsonResponse(
          jsonEncode({
            'Status': 3,
            'Answer': [
              {'name': 'api.example.com', 'type': 1, 'data': '93.184.216.34'},
            ],
          }),
        ),
        isEmpty,
      );
    });

    test('Stage 1-3 全失败且 DoH 仅返回 Fake-IP 时回退 Stage 4 LKG 并拒绝持久化非公网 IP', () async {
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) async {
          throw const SocketException(
            "Failed host lookup: 'api.example.com'",
            osError: OSError('No address associated with hostname', 7),
          );
        },
        dohLookup: (host) async => [
          InternetAddress('198.18.0.53'),
          InternetAddress('192.168.1.1'),
        ],
        delay: _instantDelay,
      );

      // 非公网 IP 与绕过域名绝不写入 LKG。
      await resolver.recordVerifiedSuccess(
        'api.example.com',
        InternetAddress('198.18.0.53'),
      );
      await resolver.recordVerifiedSuccess(
        'api.example.com',
        InternetAddress('10.0.0.1'),
      );
      await resolver.recordVerifiedSuccess(
        'localhost',
        InternetAddress('93.184.216.34'),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dns_lkg_v1_api.example.com'), isNull);
      expect(prefs.getString('dns_lkg_v1_localhost'), isNull);

      // 合法公网 IP 在 TLS 验证成功后写入 LKG。
      await resolver.recordVerifiedSuccess(
        'API.Example.com',
        InternetAddress('93.184.216.34'),
      );
      expect(prefs.getString('dns_lkg_v1_api.example.com'), '93.184.216.34');

      final fallback = await resolver.resolve('api.example.com');
      expect(fallback.single.address, '93.184.216.34');
    });

    test('无 LKG 且所有阶段失败时重抛原始 SocketException', () async {
      const originalError = SocketException(
        "Failed host lookup: 'api.example.com'",
        osError: OSError('No address associated with hostname', 7),
      );
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) async =>
            throw originalError,
        dohLookup: (host) async => const <InternetAddress>[],
        delay: _instantDelay,
      );

      await expectLater(
        resolver.resolve('api.example.com'),
        throwsA(
          isA<SocketException>().having(
            (e) => e.osError?.errorCode,
            'errorCode',
            7,
          ),
        ),
      );
    });

    test('缓存 TTL 区分公网 IP（5分钟）与 Fake-IP（45秒），且 invalidate 立即失效', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      var lookups = 0;
      var returnedIp = '198.18.0.53';
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) async {
          lookups++;
          return [InternetAddress(returnedIp)];
        },
        delay: _instantDelay,
        clock: () => now,
      );

      // 非公网 Fake-IP 缓存 45 秒。
      expect((await resolver.resolve('api.example.com')).single.address, '198.18.0.53');
      expect(lookups, 1);

      now = now.add(const Duration(seconds: 44));
      expect((await resolver.resolve('api.example.com')).single.address, '198.18.0.53');
      expect(lookups, 1);

      // 超过 45 秒失效后切到公网 IP。
      returnedIp = '93.184.216.34';
      now = now.add(const Duration(seconds: 2));
      expect((await resolver.resolve('api.example.com')).single.address, '93.184.216.34');
      expect(lookups, 2);

      // 公网 IP 缓存 5 分钟。
      now = now.add(const Duration(minutes: 4, seconds: 59));
      await resolver.resolve('api.example.com');
      expect(lookups, 2);

      // invalidate 立即驱逐缓存并触发新解析。
      resolver.invalidate('api.example.com');
      await resolver.resolve('api.example.com');
      expect(lookups, 3);
    });
  });

  group('createResilientHttpClient 与 connectResilientWebSocket', () {
    test('直连本地 HttpServer (127.0.0.1) 与域名连接失败后 invalidate 重试均正常返回', () => _withRealHttp(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..write('ok');
        await request.response.close();
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close(force: true);
      });

      // 1. 绕过路径（127.0.0.1）
      final bypassClient = IOClient(createResilientHttpClient());
      addTearDown(bypassClient.close);
      final bypassRes = await bypassClient.get(
        Uri.parse('http://127.0.0.1:${server.port}/ping'),
      );
      expect(bypassRes.statusCode, 200);
      expect(bypassRes.body, 'ok');

      // 2. 域名路径：首次返回未监听的 ::1 导致 TCP 失败 -> invalidate -> forceRefresh 返回 127.0.0.1
      var lookupPhase = 0;
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) async {
          lookupPhase++;
          if (lookupPhase == 1) {
            return [InternetAddress.loopbackIPv6];
          }
          return [InternetAddress.loopbackIPv4];
        },
        delay: _instantDelay,
      );
      final domainClient = IOClient(createResilientHttpClient(resolver: resolver));
      addTearDown(domainClient.close);
      final domainRes = await domainClient.get(
        Uri.parse('http://api.example.com:${server.port}/ping'),
      );
      expect(domainRes.statusCode, 200);
      expect(domainRes.body, 'ok');
      expect(lookupPhase, 2);
    }));

    test('connectResilientWebSocket 正常建连并双向收发消息', () => _withRealHttp(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final ws = await WebSocketTransformer.upgrade(request);
          ws.listen((msg) {
            ws.add('echo:$msg');
          });
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      final wsHttpClient = createResilientHttpClient();
      addTearDown(() async {
        wsHttpClient.close(force: true);
        await sub.cancel();
        await server.close(force: true);
      });

      final socket = await connectResilientWebSocket(
        'ws://127.0.0.1:${server.port}/ws',
        customClient: wsHttpClient,
      );
      addTearDown(socket.close);

      socket.add('hello');
      final reply = await socket.first.timeout(const Duration(seconds: 2));
      expect(reply, 'echo:hello');
    }));

    test('HTTPS TLS 握手校验失败时失效缓存且不写入 LKG', () => _withRealHttp(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((clientSocket) {
        clientSocket.add(utf8.encode('HTTP/1.1 200 OK\r\n\r\n'));
        clientSocket.destroy();
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close();
      });

      var lookups = 0;
      final resolver = ResilientDnsResolver(
        systemLookup: (host, {type = InternetAddressType.any}) async {
          lookups++;
          return [InternetAddress.loopbackIPv4];
        },
        delay: _instantDelay,
      );
      final client = IOClient(createResilientHttpClient(resolver: resolver));
      addTearDown(client.close);

      await expectLater(
        client.get(Uri.parse('https://api.example.com:${server.port}/ping')),
        throwsA(anyOf(isA<HandshakeException>(), isA<TlsException>(), isA<Exception>())),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dns_lkg_v1_api.example.com'), isNull);
      // 握手失败已调用 invalidate，下次 resolve 会重新发起查询。
      await resolver.resolve('api.example.com');
      expect(lookups, 2);
    }));

    test('directProxy 启用时强制直连并保持严格 TLS 校验', () => _withRealHttp(() async {
      final rawClient = createResilientHttpClient(directProxy: true);
      addTearDown(() => rawClient.close(force: true));

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..write('proxy-bypassed');
        await request.response.close();
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close(force: true);
      });

      final client = IOClient(rawClient);
      addTearDown(client.close);
      final res = await client.get(Uri.parse('http://127.0.0.1:${server.port}/test'));
      expect(res.statusCode, 200);
      expect(res.body, 'proxy-bypassed');
    }));
  });

  group('ApiClient 幂等同步与会话续期重试', () {
    test('fetchSyncBootstrap 在 503 与传输中断后重试成功，401 SESSION_EXPIRED 立即返回不重试', () => _withRealHttp(() async {
      var requestCount = 0;
      var mode = '503_then_200';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((request) async {
        requestCount++;
        await request.drain<void>();
        if (mode == '503_then_200' && requestCount == 1) {
          request.response
            ..statusCode = 503
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'upstream busy'}));
          await request.response.close();
          return;
        }
        if (mode == 'drop_then_200' && requestCount == 1) {
          final rawSocket = await request.response.detachSocket(
            writeHeaders: false,
          );
          rawSocket.destroy();
          return;
        }
        if (mode == '401_no_retry') {
          request.response
            ..statusCode = 401
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': '认证会话已过期',
                'code': 'SESSION_EXPIRED',
              }),
            );
          await request.response.close();
          return;
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'cursors': {'unit': '1', 'incident': '2'},
              'events': const [],
            }),
          );
        await request.response.close();
      });

      ApiException? authFailure;
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        incidentId: 'incident-1',
        sessionToken: 'token-1',
        onAuthenticationFailure: (err) => authFailure = err,
      );
      addTearDown(() async {
        api.dispose();
        await sub.cancel();
        await server.close(force: true);
      });

      // 1. 503 -> 重试一次成功
      final first = await api.fetchSyncBootstrap();
      expect((first['cursors'] as Map)['unit'], '1');
      expect(requestCount, 2);

      // 2. TCP 连接被中断 -> 重试一次成功
      requestCount = 0;
      mode = 'drop_then_200';
      final second = await api.fetchSyncBootstrap();
      expect((second['cursors'] as Map)['incident'], '2');
      expect(requestCount, 2);

      // 3. 401 SESSION_EXPIRED -> 立即失败且不重试
      requestCount = 0;
      mode = '401_no_retry';
      await expectLater(
        api.fetchSyncBootstrap(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_EXPIRED'),
        ),
      );
      expect(requestCount, 1);
      expect(authFailure?.code, 'SESSION_EXPIRED');
    }));

    test('fetchSyncCheckpoint / fetchSyncEvents / refreshSession 均支持 503 退避重试', () => _withRealHttp(() async {
      var checkpointHits = 0;
      var eventsHits = 0;
      var refreshHits = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path == '/api/sync/checkpoint') {
          checkpointHits++;
          request.response
            ..statusCode = checkpointHits == 1 ? 503 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'unit': '3', 'incident': '4'}));
        } else if (request.uri.path == '/api/sync/events') {
          eventsHits++;
          request.response
            ..statusCode = eventsHits == 1 ? 502 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'events': const []}));
        } else if (request.uri.path == '/api/auth/refresh') {
          refreshHits++;
          request.response
            ..statusCode = refreshHits == 1 ? 504 : 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'session_token': 'refreshed'}));
        }
        await request.response.close();
      });

      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        incidentId: 'incident-1',
        sessionToken: 'token-1',
      );
      addTearDown(() async {
        api.dispose();
        await sub.cancel();
        await server.close(force: true);
      });

      final cp = await api.fetchSyncCheckpoint();
      expect(cp['unit'], '3');
      expect(checkpointHits, 2);

      final events = await api.fetchSyncEvents(
        unitCursor: '1',
        incidentCursor: '2',
      );
      expect(events, isEmpty);
      expect(eventsHits, 2);

      final refreshed = await api.refreshSession();
      expect(refreshed['session_token'], 'refreshed');
      expect(refreshHits, 2);
    }));

    test('单标签测试主机（如 offline）传输失败时立即重抛而不休眠重试', () => _withRealHttp(() async {
      var socketAttempts = 0;
      await IOOverrides.runZoned(() async {
        final api = ApiClient(
          baseUrl: 'http://offline',
          incidentId: 'incident-1',
        );
        addTearDown(api.dispose);

        final stopwatch = Stopwatch()..start();
        await expectLater(
          api.fetchSyncBootstrap(),
          throwsA(anyOf(isA<SocketException>(), isA<Exception>())),
        );
        stopwatch.stop();
        expect(socketAttempts, 1);
        // 若触发了 350ms + 700ms 退避则必然超过 1000ms
        expect(stopwatch.elapsedMilliseconds, lessThan(300));
      }, socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) {
        socketAttempts++;
        return Future<ConnectionTask<Socket>>.error(
          SocketException("Failed host lookup: '$host'"),
        );
      });
    }));
  });
}
