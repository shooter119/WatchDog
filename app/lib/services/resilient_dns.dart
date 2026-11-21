import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef SystemDnsLookup = Future<List<InternetAddress>> Function(
  String host, {
  InternetAddressType type,
});
typedef DohDnsLookup = Future<List<InternetAddress>> Function(String host);
typedef DnsDelay = Future<void> Function(Duration duration);
typedef DnsClock = DateTime Function();

class _DnsCacheEntry {
  final List<InternetAddress> addresses;
  final DateTime expiresAt;

  const _DnsCacheEntry(this.addresses, this.expiresAt);
}

/// 抗冷启动异常的多阶段 DNS 解析器与严格 TLS 传输工具。
///
/// 针对双卡/双栈移动网络在冷启动时同时请求引发的 `EAI_NODATA`（errno = 7）
/// 或短暂 UDP DNS 抖动，按以下顺序降级解析：
/// 1. 内存缓存与并发请求合并（In-flight Coalescing）；
/// 2. 系统双栈查询（`any`，2.5s 超时，IPv4 优先排序）；
/// 3. 短暂退避（150ms）后显式 IPv4 系统查询（2.5s 超时）；
/// 4. 国内公网 IP 字面量 DoH JSON 并发竞速（223.5.5.5 与 1.12.12.12，3s 超时）；
/// 5. 最近一次通过 TLS 验证成功的公网 LKG 地址（SharedPreferences）。
class ResilientDnsResolver {
  ResilientDnsResolver({
    SystemDnsLookup? systemLookup,
    DohDnsLookup? dohLookup,
    DnsDelay? delay,
    DnsClock? clock,
  })  : _systemLookup = systemLookup ?? _defaultSystemLookup,
        _dohLookup = dohLookup ?? _defaultDohLookup,
        _delay = delay ?? _defaultDelay,
        _clock = clock ?? DateTime.now;

  static final ResilientDnsResolver instance = ResilientDnsResolver();

  static const Duration _systemLookupTimeout = Duration(
    seconds: 2,
    milliseconds: 500,
  );
  static const Duration _stage2Delay = Duration(milliseconds: 150);
  static const Duration _dohRequestTimeout = Duration(seconds: 3);
  static const Duration _publicCacheTtl = Duration(minutes: 5);
  static const Duration _nonPublicCacheTtl = Duration(seconds: 45);
  static const String _lkgPrefix = 'dns_lkg_v1_';

  final SystemDnsLookup _systemLookup;
  final DohDnsLookup _dohLookup;
  final DnsDelay _delay;
  final DnsClock _clock;

  final Map<String, _DnsCacheEntry> _cache = <String, _DnsCacheEntry>{};
  final Map<String, Future<List<InternetAddress>>> _inFlightNormal =
      <String, Future<List<InternetAddress>>>{};
  final Map<String, Future<List<InternetAddress>>> _inFlightForce =
      <String, Future<List<InternetAddress>>>{};
  final Map<String, int> _epochs = <String, int>{};

  static String _normalizeHost(String host) {
    var normalized = host.trim().toLowerCase();
    if (normalized.startsWith('[') &&
        normalized.endsWith(']') &&
        normalized.length >= 2) {
      normalized = normalized.substring(1, normalized.length - 1);
    }
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// 本机、IP 字面量、单标签测试主机或保留局部后缀直接绕过 DoH/LKG，
  /// 保证本地开发与全部离线单测即时返回。
  static bool shouldBypass(String host) {
    final normalized = _normalizeHost(host);
    if (normalized.isEmpty) return true;
    if (InternetAddress.tryParse(normalized) != null) return true;
    if (!normalized.contains('.')) return true;
    return normalized.endsWith('.localhost') ||
        normalized.endsWith('.local') ||
        normalized.endsWith('.test') ||
        normalized.endsWith('.invalid');
  }

  /// 校验是否为可公网路由 IP。
  ///
  /// 拒绝回环、链路本地、组播、未指定、RFC1918 私网、CGNAT（100.64/10）、
  /// 基准测试 / 本地 TUN Fake-IP（198.18.0.0/15）、文档保留网段与非公网 IPv6。
  static bool isPublicRoutableIp(InternetAddress addr) {
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
      return _isPublicIpv4(raw[0], raw[1], raw[2], raw[3]);
    }
    if (addr.type == InternetAddressType.IPv6 && raw.length == 16) {
      if (addr.isLoopback || addr.isLinkLocal || addr.isMulticast) {
        return false;
      }
      var allZero = true;
      for (final byte in raw) {
        if (byte != 0) {
          allZero = false;
          break;
        }
      }
      if (allZero) return false; // ::
      if (raw.sublist(0, 15).every((b) => b == 0) && raw[15] == 1) {
        return false; // ::1
      }
      if (raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80) {
        return false; // fe80::/10 link-local
      }
      if (raw[0] == 0xFF) {
        return false; // ff00::/8 multicast
      }
      if ((raw[0] & 0xFE) == 0xFC) {
        return false; // fc00::/7 unique local
      }
      if (raw[0] == 0x01 &&
          raw[1] == 0x00 &&
          raw[2] == 0 &&
          raw[3] == 0 &&
          raw[4] == 0 &&
          raw[5] == 0 &&
          raw[6] == 0 &&
          raw[7] == 0) {
        return false; // 100::/64 discard-only
      }
      if (raw[0] == 0x20 &&
          raw[1] == 0x01 &&
          raw[2] == 0x0D &&
          raw[3] == 0xB8) {
        return false; // 2001:db8::/32 documentation
      }
      if (raw.sublist(0, 10).every((b) => b == 0) &&
          raw[10] == 0xFF &&
          raw[11] == 0xFF) {
        return _isPublicIpv4(raw[12], raw[13], raw[14], raw[15]);
      }
      return true;
    }
    return false;
  }

  /// 判断是否为本地 TUN / 代理拦截常用的基准测试 Fake-IP 网段（198.18.0.0/15）。
  static bool isFakeIp(InternetAddress addr) {
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
      return _isFakeIpv4(raw[0], raw[1]);
    }
    if (addr.type == InternetAddressType.IPv6 &&
        raw.length == 16 &&
        raw.sublist(0, 10).every((b) => b == 0) &&
        raw[10] == 0xFF &&
        raw[11] == 0xFF) {
      return _isFakeIpv4(raw[12], raw[13]);
    }
    return false;
  }

  static bool _isFakeIpv4(int b0, int b1) =>
      b0 == 198 && (b1 == 18 || b1 == 19);

  static bool _isPublicIpv4(int b0, int b1, int b2, int b3) {
    if (b0 == 0) return false; // 0.0.0.0/8 unspecified
    if (b0 == 10) return false; // 10.0.0.0/8 RFC1918
    if (b0 == 100 && b1 >= 64 && b1 <= 127) return false; // 100.64.0.0/10 CGNAT
    if (b0 == 127) return false; // 127.0.0.0/8 loopback
    if (b0 == 169 && b1 == 254) return false; // 169.254.0.0/16 link-local
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return false; // 172.16.0.0/12 RFC1918
    if (b0 == 192 && b1 == 0 && b2 == 0) return false; // 192.0.0.0/24 IETF
    if (b0 == 192 && b1 == 0 && b2 == 2) return false; // 192.0.2.0/24 TEST-NET-1
    if (b0 == 192 && b1 == 168) return false; // 192.168.0.0/16 RFC1918
    if (_isFakeIpv4(b0, b1)) return false; // 198.18.0.0/15 Fake-IP
    if (b0 == 198 && b1 == 51 && b2 == 100) return false; // 198.51.100.0/24 doc
    if (b0 == 203 && b1 == 0 && b2 == 113) return false; // 203.0.113.0/24 doc
    if (b0 >= 224) return false; // 224.0.0.0/4 multicast & 240.0.0.0/4 reserved
    return true;
  }

  /// 清除指定主机的内存解析缓存并递增版本，防止滞后的并发查询回写旧结果。
  void invalidate(String host) {
    final key = _normalizeHost(host);
    if (key.isEmpty) return;
    _cache.remove(key);
    _inFlightNormal.remove(key);
    _inFlightForce.remove(key);
    _epochs[key] = (_epochs[key] ?? 0) + 1;
  }

  Future<List<InternetAddress>> _resolveBypass(String host, String key) async {
    final literal = InternetAddress.tryParse(key);
    if (literal != null) return <InternetAddress>[literal];
    if (key.isEmpty) throw SocketException("Failed host lookup: '$host'");
    return _systemLookup(
      key,
      type: InternetAddressType.any,
    ).timeout(_systemLookupTimeout);
  }

  /// 解析主机地址列表（IPv4 优先）。
  Future<List<InternetAddress>> resolve(
    String host, {
    bool forceRefresh = false,
  }) async {
    final key = _normalizeHost(host);
    if (shouldBypass(key)) {
      return _resolveBypass(host, key);
    }

    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        if (_clock().isBefore(cached.expiresAt)) {
          return cached.addresses;
        }
        _cache.remove(key);
      }
    }

    final map = forceRefresh ? _inFlightForce : _inFlightNormal;
    final existing = map[key];
    if (existing != null) return existing;

    final startEpoch = _epochs[key] ?? 0;
    late final Future<List<InternetAddress>> future;
    future = _resolvePipeline(key, startEpoch).whenComplete(() {
      if (identical(map[key], future)) {
        map.remove(key);
      }
    });
    map[key] = future;
    return future;
  }

  /// 当候选地址连接失败、TLS 握手超时或命中 Fake-IP 拦截时执行回退解析：
  /// 先失效缓存并复查系统 DNS（剔除已失败 IP 与 Fake-IP），若过滤后无可用候选，
  /// 立即执行 DoH 与公网 LKG 兜底并缓存。
  Future<List<InternetAddress>> resolveFallback(
    String host, {
    Set<String> excludeAddresses = const <String>{},
  }) async {
    final key = _normalizeHost(host);
    if (shouldBypass(key)) {
      return _resolveBypass(host, key);
    }

    invalidate(key);
    final startEpoch = _epochs[key] ?? 0;
    final systemResult = await _lookupSystemAddresses(key);
    final filteredSystem = _prioritizePublicAndSort(
      systemResult.addresses.where(
        (addr) => !isFakeIp(addr) && !_isExcluded(addr, excludeAddresses),
      ),
    );
    if (filteredSystem.isNotEmpty) {
      _storeCache(key, filteredSystem, startEpoch);
      return filteredSystem;
    }

    return _resolveDohOrLkg(
      key,
      startEpoch,
      excludeAddresses: excludeAddresses,
      fallbackError: systemResult.error,
    );
  }

  /// 仅在非绕过域名且真实 TLS/连接验证成功后，才将公网 IP 写入 LKG。
  Future<void> recordVerifiedSuccess(
    String host,
    InternetAddress address,
  ) async {
    final key = _normalizeHost(host);
    if (shouldBypass(key) || !isPublicRoutableIp(address)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_lkgPrefix$key', address.address);
    } catch (_) {
      // 独立 isolate 或未初始化插件绑定的单测环境下静默跳过持久化。
    }
  }

  Future<({List<InternetAddress> addresses, SocketException? error})>
      _lookupSystemAddresses(String key) async {
    SocketException? firstSocketException;

    // Stage 1: 系统双栈查询（2.5s 超时，公网 IPv4 排前）。
    try {
      final stage1 = await _systemLookup(
        key,
        type: InternetAddressType.any,
      ).timeout(_systemLookupTimeout);
      final sorted = _prioritizePublicAndSort(stage1);
      if (sorted.isNotEmpty) {
        return (addresses: sorted, error: null);
      }
    } on SocketException catch (error) {
      firstSocketException ??= error;
    } catch (_) {
      // 超时或其他非 SocketException 降级进入 Stage 2。
    }

    // Stage 2: 退避 150ms 后显式 IPv4 查询（规避仅 IPv4 域名的 AAAA NODATA 竞态）。
    await _delay(_stage2Delay);
    try {
      final stage2 = await _systemLookup(
        key,
        type: InternetAddressType.IPv4,
      ).timeout(_systemLookupTimeout);
      final sorted = _prioritizePublicAndSort(stage2);
      if (sorted.isNotEmpty) {
        return (addresses: sorted, error: null);
      }
    } on SocketException catch (error) {
      firstSocketException ??= error;
    } catch (_) {
      // 降级进入 Stage 3。
    }

    return (addresses: const <InternetAddress>[], error: firstSocketException);
  }

  Future<List<InternetAddress>> _resolvePipeline(
    String key,
    int startEpoch,
  ) async {
    final systemResult = await _lookupSystemAddresses(key);
    if (systemResult.addresses.isNotEmpty) {
      _storeCache(key, systemResult.addresses, startEpoch);
      return systemResult.addresses;
    }

    return _resolveDohOrLkg(
      key,
      startEpoch,
      fallbackError: systemResult.error,
    );
  }

  Future<List<InternetAddress>> _resolveDohOrLkg(
    String key,
    int startEpoch, {
    Set<String> excludeAddresses = const <String>{},
    SocketException? fallbackError,
  }) async {
    // Stage 3: 国内 IP 字面量 DoH JSON 并发竞速（严格过滤公网 IP）。
    try {
      final stage3 = await _dohLookup(key);
      final publicIps = _sortAndDedupe(
        stage3.where(
          (addr) =>
              isPublicRoutableIp(addr) &&
              !_isExcluded(addr, excludeAddresses),
        ),
      );
      if (publicIps.isNotEmpty) {
        _storeCache(key, publicIps, startEpoch);
        return publicIps;
      }
    } catch (_) {
      // 降级进入 Stage 4。
    }

    // Stage 4: 最近一次 TLS 验证成功的公网 LKG 兜底。
    final lkg = await _readLastKnownGood(key);
    if (lkg != null && !_isExcluded(lkg, excludeAddresses)) {
      final list = List<InternetAddress>.unmodifiable(<InternetAddress>[lkg]);
      _storeCache(
        key,
        list,
        startEpoch,
        overrideTtl: _nonPublicCacheTtl,
      );
      return list;
    }

    if (fallbackError != null) {
      throw fallbackError;
    }
    throw SocketException("Failed host lookup: '$key'");
  }

  static bool _isExcluded(
    InternetAddress addr,
    Set<String> excludeAddresses,
  ) {
    if (excludeAddresses.isEmpty) return false;
    return excludeAddresses.contains(addr.address) ||
        excludeAddresses.contains('${addr.type.name}:${addr.address}');
  }

  static List<InternetAddress> _prioritizePublicAndSort(
    Iterable<InternetAddress> addresses,
  ) {
    final list = addresses.toList(growable: false);
    if (list.isEmpty) return const <InternetAddress>[];
    final public = _sortAndDedupe(list.where(isPublicRoutableIp));
    final nonPublic = _sortAndDedupe(
      list.where((addr) => !isPublicRoutableIp(addr)),
    );
    return List<InternetAddress>.unmodifiable(<InternetAddress>[
      ...public,
      ...nonPublic,
    ]);
  }

  void _storeCache(
    String key,
    List<InternetAddress> addresses,
    int startEpoch, {
    Duration? overrideTtl,
  }) {
    if ((_epochs[key] ?? 0) != startEpoch) return;
    final allPublic = addresses.every(isPublicRoutableIp);
    final ttl =
        overrideTtl ?? (allPublic ? _publicCacheTtl : _nonPublicCacheTtl);
    _cache[key] = _DnsCacheEntry(
      List<InternetAddress>.unmodifiable(addresses),
      _clock().add(ttl),
    );
  }

  Future<InternetAddress?> _readLastKnownGood(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_lkgPrefix$key')?.trim();
      if (raw == null || raw.isEmpty) return null;
      final addr = InternetAddress.tryParse(raw);
      if (addr == null || !isPublicRoutableIp(addr)) return null;
      return addr;
    } catch (_) {
      return null;
    }
  }

  static List<InternetAddress> _sortAndDedupe(
    Iterable<InternetAddress> addresses,
  ) {
    final v4 = <InternetAddress>[];
    final v6 = <InternetAddress>[];
    final seen = <String>{};
    for (final addr in addresses) {
      final dedupeKey = '${addr.type.name}:${addr.address}';
      if (!seen.add(dedupeKey)) continue;
      if (addr.type == InternetAddressType.IPv4) {
        v4.add(addr);
      } else {
        v6.add(addr);
      }
    }
    return List<InternetAddress>.unmodifiable(<InternetAddress>[...v4, ...v6]);
  }

  static Future<List<InternetAddress>> _defaultSystemLookup(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) => InternetAddress.lookup(host, type: type);

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  static Future<List<InternetAddress>> _defaultDohLookup(String host) async {
    final encoded = Uri.encodeQueryComponent(host);
    final endpoints = <Uri>[
      Uri.parse('https://223.5.5.5/resolve?name=$encoded&type=1'),
      Uri.parse('https://1.12.12.12/resolve?name=$encoded&type=1'),
    ];
    final completer = Completer<List<InternetAddress>>();
    final clients = <HttpClient>[];
    var remaining = endpoints.length;

    void closeClients() {
      for (final client in clients) {
        try {
          client.close(force: true);
        } catch (_) {}
      }
    }

    for (final uri in endpoints) {
      final client = HttpClient()..connectionTimeout = _dohRequestTimeout;
      if (kReleaseMode) {
        client.findProxy = (uri) => 'DIRECT';
        client.badCertificateCallback = null;
      }
      clients.add(client);
      unawaited(
        _queryDohEndpoint(client, uri)
            .timeout(_dohRequestTimeout)
            .then(
              (ips) {
                if (ips.isNotEmpty && !completer.isCompleted) {
                  completer.complete(ips);
                  closeClients();
                }
              },
              onError: (Object _, StackTrace __) {
                // 吞掉竞速失败分支异常，等待同组另一 DoH 节点结果。
              },
            )
            .whenComplete(() {
              try {
                client.close(force: true);
              } catch (_) {}
              remaining--;
              if (remaining == 0 && !completer.isCompleted) {
                completer.complete(const <InternetAddress>[]);
              }
            }),
      );
    }

    return completer.future;
  }

  static Future<List<InternetAddress>> _queryDohEndpoint(
    HttpClient client,
    Uri uri,
  ) async {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
    final res = await req.close();
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      return const <InternetAddress>[];
    }
    final body = await utf8.decoder.bind(res).join();
    return parseDohJsonResponse(body);
  }

  /// 解析 DoH JSON（`Status == 0` 且 `type == 1` 的 A 记录），仅保留公网 IP。
  @visibleForTesting
  static List<InternetAddress> parseDohJsonResponse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const <InternetAddress>[];
    final status = decoded['Status'];
    if (status is! num || status.toInt() != 0) {
      return const <InternetAddress>[];
    }
    final answers = decoded['Answer'];
    if (answers is! List) return const <InternetAddress>[];
    final result = <InternetAddress>[];
    for (final item in answers) {
      if (item is! Map) continue;
      final type = item['type'];
      if (type is! num || type.toInt() != 1) continue;
      final data = item['data']?.toString().trim();
      if (data == null || data.isEmpty) continue;
      final addr = InternetAddress.tryParse(data);
      if (addr == null || addr.type != InternetAddressType.IPv4) continue;
      if (!isPublicRoutableIp(addr)) continue;
      result.add(addr);
    }
    return result;
  }
}

/// 创建挂载抗冷启动 DNS 解析与严格 TLS 主机名校验证书链的 `HttpClient`。
HttpClient createResilientHttpClient({
  ResilientDnsResolver? resolver,
  Duration connectionTimeout = const Duration(seconds: 20),
  Duration idleTimeout = const Duration(seconds: 25),
  bool? directProxy,
  @visibleForTesting Duration tlsHandshakeTimeout = const Duration(seconds: 6),
  @visibleForTesting SecurityContext? tlsContext,
}) {
  final useDirectProxy = directProxy ?? kReleaseMode;
  final dns = resolver ?? ResilientDnsResolver.instance;
  final httpClient = HttpClient()
    ..connectionTimeout = connectionTimeout
    ..idleTimeout = idleTimeout;

  if (useDirectProxy) {
    httpClient.findProxy = (uri) => 'DIRECT';
    httpClient.badCertificateCallback = null;
  }

  httpClient.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
    if (!useDirectProxy && proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }

    final scheme = uri.scheme.toLowerCase();
    final isSecure = scheme == 'https' || scheme == 'wss';
    // Dart WebSocket.connect 将无显式端口的 ws/wss 转为 http/https 时会传入 port: 0
    // （此时 uri.hasPort 为 true 且 uri.port == 0），必须回退至协议默认端口 80/443。
    final port = (uri.hasPort && uri.port > 0) ? uri.port : (isSecure ? 443 : 80);

    var cancelled = false;
    var verified = false;
    ConnectionTask<Socket>? activeTask;
    Socket? activeTcpSocket;

    void onCancel() {
      cancelled = true;
      activeTask?.cancel();
      activeTcpSocket?.destroy();
      if (!verified && !ResilientDnsResolver.shouldBypass(uri.host)) {
        dns.invalidate(uri.host);
      }
    }

    Future<Socket> connectAttempt(dynamic hostOrAddr) async {
      const tcpTimeout = Duration(seconds: 5);
      final taskFuture = Socket.startConnect(hostOrAddr, port);
      final task = await taskFuture.timeout(
        tcpTimeout,
        onTimeout: () {
          unawaited(
            taskFuture.then((lateTask) {
              lateTask.cancel();
              lateTask.socket.then((s) => s.destroy(), onError: (_) {});
            }, onError: (_) {}),
          );
          throw SocketException('TCP connection timed out ($hostOrAddr:$port)');
        },
      );
      if (cancelled) {
        task.cancel();
        task.socket.then((s) => s.destroy(), onError: (_) {});
        throw const SocketException('Connection cancelled');
      }
      activeTask = task;
      try {
        final socket = await task.socket.timeout(tcpTimeout);
        activeTask = null;
        if (cancelled) {
          socket.destroy();
          throw const SocketException('Connection cancelled');
        }
        return socket;
      } catch (error) {
        activeTask = null;
        if (error is TimeoutException) {
          task.cancel();
          task.socket.then((s) => s.destroy(), onError: (_) {});
          throw SocketException(
            'TCP connection timed out ($hostOrAddr:$port)',
          );
        }
        rethrow;
      }
    }

    Future<Socket> secureIfNeeded(
      Socket tcp, {
      required bool invalidateOnFail,
      VoidCallback? onTlsTimeout,
    }) async {
      if (!isSecure) return tcp;
      if (cancelled) {
        tcp.destroy();
        throw const SocketException('Connection cancelled');
      }
      activeTcpSocket = tcp;
      final secureFuture = SecureSocket.secure(
        tcp,
        host: uri.host,
        context: tlsContext,
      );
      try {
        final secure = await secureFuture.timeout(
          tlsHandshakeTimeout,
          onTimeout: () {
            onTlsTimeout?.call();
            unawaited(
              secureFuture.then(
                (lateSocket) => lateSocket.destroy(),
                onError: (_) {},
              ),
            );
            throw TimeoutException(
              'TLS handshake timed out',
              tlsHandshakeTimeout,
            );
          },
        );
        activeTcpSocket = null;
        if (cancelled) {
          secure.destroy();
          throw const SocketException('Connection cancelled');
        }
        return secure;
      } catch (error) {
        activeTcpSocket = null;
        tcp.destroy();
        if (!cancelled && invalidateOnFail) {
          dns.invalidate(uri.host);
        }
        if (error is TimeoutException) {
          throw SocketException('TLS handshake timed out (${uri.host}:$port)');
        }
        rethrow;
      }
    }

    Future<Socket> connectFuture() async {
      if (ResilientDnsResolver.shouldBypass(uri.host)) {
        final tcp = await connectAttempt(uri.host);
        final finalSocket = await secureIfNeeded(tcp, invalidateOnFail: false);
        verified = true;
        return finalSocket;
      }

      final tried = <String>{};
      Object? lastError;
      var hadTransportOrFakeIpFailure = false;

      Future<Socket?> tryCandidates(
        List<InternetAddress> candidates, {
        required bool trackFallbackNeed,
      }) async {
        for (final addr in candidates) {
          if (cancelled) throw const SocketException('Connection cancelled');
          if (!tried.add(addr.address)) continue;
          var tlsAttempted = false;
          var tlsTimedOut = false;
          try {
            final tcp = await connectAttempt(addr);
            if (isSecure) {
              tlsAttempted = true;
            }
            final finalSocket = await secureIfNeeded(
              tcp,
              invalidateOnFail: true,
              onTlsTimeout: () => tlsTimedOut = true,
            );
            verified = true;
            unawaited(dns.recordVerifiedSuccess(uri.host, addr));
            return finalSocket;
          } catch (error) {
            if (cancelled) throw const SocketException('Connection cancelled');
            lastError = error;
            if (trackFallbackNeed &&
                (ResilientDnsResolver.isFakeIp(addr) ||
                    !tlsAttempted ||
                    tlsTimedOut)) {
              hadTransportOrFakeIpFailure = true;
            }
          }
        }
        return null;
      }

      final initialCandidates = await dns.resolve(uri.host);
      if (cancelled) throw const SocketException('Connection cancelled');

      // 系统 DNS 仅返回 TUN Fake-IP（198.18.0.0/15）时，先通过 DoH/LKG 解析公网 IP 直连，
      // 避免先硬连 Fake-IP 干等 5s TCP + 6s TLS 超时；仅在公网兜底不可用时才回退尝试 Fake-IP。
      final onlyFakeIps =
          initialCandidates.isNotEmpty &&
          initialCandidates.every(ResilientDnsResolver.isFakeIp);
      if (onlyFakeIps) {
        final fakeIpSet = initialCandidates.map((a) => a.address).toSet();
        try {
          final directCandidates = await dns.resolveFallback(
            uri.host,
            excludeAddresses: fakeIpSet,
          );
          if (cancelled) throw const SocketException('Connection cancelled');
          final directSocket = await tryCandidates(
            directCandidates,
            trackFallbackNeed: false,
          );
          if (directSocket != null) return directSocket;
        } catch (error) {
          if (cancelled) throw const SocketException('Connection cancelled');
          lastError ??= error;
        }

        final fakeFallbackSocket = await tryCandidates(
          initialCandidates,
          trackFallbackNeed: false,
        );
        if (fakeFallbackSocket != null) return fakeFallbackSocket;

        if (lastError != null) throw lastError!;
        throw SocketException('Failed to connect to ${uri.host}:$port');
      }

      final firstSocket = await tryCandidates(
        initialCandidates,
        trackFallbackNeed: true,
      );
      if (firstSocket != null) return firstSocket;

      if (!cancelled && (hadTransportOrFakeIpFailure || tried.isEmpty)) {
        try {
          final fallbackCandidates = await dns.resolveFallback(
            uri.host,
            excludeAddresses: tried,
          );
          if (cancelled) throw const SocketException('Connection cancelled');
          final fallbackSocket = await tryCandidates(
            fallbackCandidates,
            trackFallbackNeed: false,
          );
          if (fallbackSocket != null) return fallbackSocket;
        } catch (error) {
          if (cancelled) throw const SocketException('Connection cancelled');
          lastError ??= error;
        }
      }

      if (lastError != null) throw lastError!;
      throw SocketException('Failed to connect to ${uri.host}:$port');
    }

    final socketFuture = connectFuture()..ignore();
    return Future.value(
      ConnectionTask.fromSocket<Socket>(socketFuture, onCancel),
    );
  };

  return httpClient;
}

/// 使用抗冷启动 DNS 与严格 TLS 校验证书的受控短生命周期 HTTP 客户端建立 WebSocket 连接。
Future<WebSocket> connectResilientWebSocket(
  String url, {
  Iterable<String>? protocols,
  Map<String, dynamic>? headers,
  CompressionOptions compression = CompressionOptions.compressionDefault,
  HttpClient? customClient,
  Duration timeout = const Duration(seconds: 12),
  @visibleForTesting ResilientDnsResolver? resolver,
}) async {
  final ownedClient = customClient == null
      ? createResilientHttpClient(
          resolver: resolver,
          idleTimeout: const Duration(seconds: 25),
        )
      : null;
  final client = customClient ?? ownedClient!;
  final connectFuture = WebSocket.connect(
    url,
    protocols: protocols,
    headers: headers,
    compression: compression,
    customClient: client,
  );
  try {
    final socket = await connectFuture.timeout(
      timeout,
      onTimeout: () {
        unawaited(
          connectFuture.then(
            (lateSocket) => lateSocket.close(WebSocketStatus.goingAway),
            onError: (_) {},
          ),
        );
        throw TimeoutException('WebSocket connection timed out ($url)', timeout);
      },
    );
    ownedClient?.close(force: false);
    return socket;
  } catch (_) {
    ownedClient?.close(force: true);
    final parsedUri = Uri.tryParse(url);
    if (parsedUri != null &&
        parsedUri.host.isNotEmpty &&
        !ResilientDnsResolver.shouldBypass(parsedUri.host)) {
      (resolver ?? ResilientDnsResolver.instance).invalidate(parsedUri.host);
    }
    rethrow;
  }
}
