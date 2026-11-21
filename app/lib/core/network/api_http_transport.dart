import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../services/resilient_dns.dart';
import 'api_config.dart';
import 'api_exceptions.dart';

class ApiHttpTransport {
  final ApiConfig config;
  final http.Client Function() _clientFactory;
  late final http.Client _client;
  http.Client? _activeChatClient;
  final Set<http.Client> _transientClients = <http.Client>{};
  final Set<Timer> _pendingRetryTimers = <Timer>{};
  final Set<Completer<void>> _pendingRetryWaits = <Completer<void>>{};
  bool _disposed = false;

  ApiHttpTransport(
    this.config, {
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? createDefaultHttpClient {
    _client = _clientFactory();
  }

  bool get isDisposed => _disposed;

  Map<String, String> get headers => config.headers;

  Map<String, String> opHeaders(String? opId) => config.opHeaders(opId);

  Uri uri(String path) => config.uri(path);

  String get cacheScope => config.cacheScope;

  http.Client get client {
    _ensureNotDisposed();
    return _client;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('API 客户端已释放');
  }

  /// 创建带底层连接/空闲超时与抗冷启动 DNS 解析的移动端 HTTP 客户端。
  ///
  /// `Future.timeout` 只能停止等待 Dart Future，不能保证底层 socket 被关闭。
  /// 所有 API 请求都使用受控客户端；辅助页另建一个客户端，便于单独取消。
  static IOClient createDefaultHttpClient() {
    return IOClient(
      createResilientHttpClient(
        connectionTimeout: const Duration(seconds: 12),
        idleTimeout: const Duration(seconds: 25),
      ),
    );
  }

  http.Client newChatClient() {
    _ensureNotDisposed();
    return _clientFactory();
  }

  /// 开启并登记当前辅助问答流式客户端，供 `cancelChatRequest` 与 `dispose` 统一关闭。
  http.Client openChatClient() {
    _ensureNotDisposed();
    final chatClient = _clientFactory();
    _activeChatClient = chatClient;
    return chatClient;
  }

  /// 归还并关闭辅助问答流式客户端。
  void releaseChatClient(http.Client chatClient) {
    if (identical(_activeChatClient, chatClient)) {
      _activeChatClient = null;
    }
    chatClient.close();
  }

  /// 取消当前辅助问答的底层请求（页面超时、离开页面或用户重试时调用）。
  void cancelChatRequest() {
    _activeChatClient?.close();
  }

  /// 释放 API 客户端及其底层 socket。
  void dispose() {
    _disposed = true;
    cancelChatRequest();
    _activeChatClient = null;
    _client.close();
    for (final transient in List<http.Client>.of(_transientClients)) {
      transient.close();
    }
    _transientClients.clear();
    for (final timer in List<Timer>.of(_pendingRetryTimers)) {
      timer.cancel();
    }
    _pendingRetryTimers.clear();
    for (final wait in List<Completer<void>>.of(_pendingRetryWaits)) {
      if (!wait.isCompleted) wait.completeError(StateError('API 客户端已释放'));
    }
    _pendingRetryWaits.clear();
  }

  /// 网关故障时可能返回 HTML（例如 503），不能直接 jsonDecode，
  /// 否则用户只能看到无意义的 FormatException: Unexpected character '<'。
  dynamic decodeJson(http.Response res, {required String fallback}) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw ApiException(
        responseError(res.statusCode, null, fallback),
        statusCode: res.statusCode,
        code: 'INVALID_JSON',
      );
    }
  }

  String responseError(int statusCode, dynamic body, String fallback) {
    if (body is Map && body['error'] != null) {
      final message = body['error'].toString().trim();
      if (message.isNotEmpty) return message;
    }
    if (statusCode >= 500) {
      return '服务器暂时不可用，请稍后重试（HTTP $statusCode）';
    }
    return '$fallback（HTTP $statusCode）';
  }

  ApiException apiException(
    http.Response res, {
    required dynamic body,
    required String fallback,
  }) {
    final suggestions = body is Map && body['suggestions'] is List
        ? List<String>.unmodifiable(
            (body['suggestions'] as List)
                .whereType<String>()
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .take(3),
          )
        : const <String>[];
    final error = ApiException(
      responseError(res.statusCode, body, fallback),
      statusCode: res.statusCode,
      code: responseCode(res, body),
      requestId: res.headers['x-request-id'],
      current: body is Map && body['current'] is Map
          ? Map<String, dynamic>.from(body['current'] as Map)
          : null,
      suggestions: suggestions,
    );
    if (isApiAuthenticationFailure(error)) {
      config.onAuthenticationFailure?.call(error);
    }
    return error;
  }

  ApiException streamedApiException(
    http.StreamedResponse res,
    String responseBody, {
    required String fallback,
  }) {
    dynamic body;
    try {
      body = jsonDecode(responseBody);
    } catch (_) {
      body = null;
    }
    final error = ApiException(
      responseError(res.statusCode, body, fallback),
      statusCode: res.statusCode,
      code: body is Map && body['code'] != null
          ? body['code'].toString()
          : 'HTTP_${res.statusCode}',
      requestId: res.headers['x-request-id'],
    );
    if (isApiAuthenticationFailure(error)) {
      config.onAuthenticationFailure?.call(error);
    }
    return error;
  }

  String responseCode(http.Response res, dynamic body) {
    final code = body is Map ? body['code']?.toString().trim() : null;
    return code == null || code.isEmpty ? 'HTTP_${res.statusCode}' : code;
  }

  ApiException responseShapeException(http.Response res, String message) =>
      ApiException(
        message,
        statusCode: res.statusCode,
        code: 'INVALID_RESPONSE_SHAPE',
      );

  static bool isRetryableTransportError(Object error) =>
      error is SocketException ||
      error is HandshakeException ||
      error is TlsException ||
      error is HttpException ||
      error is http.ClientException ||
      error is TimeoutException;

  static bool isSyntheticTestHost(String host) {
    if (!ResilientDnsResolver.shouldBypass(host)) return false;
    var normalized = host.trim().toLowerCase();
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.isEmpty) return true;
    if (InternetAddress.tryParse(normalized) != null) return false;
    return !normalized.contains('.') ||
        normalized.endsWith('.test') ||
        normalized.endsWith('.invalid');
  }

  Future<void> _cancellableRetryDelay(Duration duration) {
    if (_disposed) return Future<void>.error(StateError('API 客户端已释放'));
    final completer = Completer<void>();
    late final Timer timer;
    timer = Timer(duration, () {
      _pendingRetryTimers.remove(timer);
      _pendingRetryWaits.remove(completer);
      if (!completer.isCompleted) completer.complete();
    });
    _pendingRetryTimers.add(timer);
    _pendingRetryWaits.add(completer);
    return completer.future;
  }

  /// 幂等同步与会话续期请求重试：
  /// 首次沿用共享 `_client` 保持连接池复用；仅在 502/503/504 或短暂传输异常时
  /// 失效对应域名 DNS 缓存并使用独立短寿命客户端退避重试（350ms、700ms）。
  Future<http.Response> withIdempotentSyncRetry(
    Uri uri,
    Future<http.Response> Function(http.Client client) send, {
    required Duration timeout,
  }) async {
    const attempts = 3;
    for (var attempt = 0; attempt < attempts; attempt++) {
      _ensureNotDisposed();
      final http.Client? transientClient =
          attempt == 0 ? null : _clientFactory();
      if (transientClient != null) _transientClients.add(transientClient);
      final activeClient = transientClient ?? _client;
      try {
        final response = await send(activeClient).timeout(timeout);
        final retryableStatus =
            response.statusCode == 502 ||
            response.statusCode == 503 ||
            response.statusCode == 504;
        if (!retryableStatus) return response;
        ResilientDnsResolver.instance.invalidate(uri.host);
        if (_disposed || attempt == attempts - 1) return response;
      } catch (error) {
        if (!isRetryableTransportError(error)) rethrow;
        ResilientDnsResolver.instance.invalidate(uri.host);
        if (_disposed ||
            attempt == attempts - 1 ||
            isSyntheticTestHost(uri.host)) {
          rethrow;
        }
      } finally {
        if (transientClient != null) {
          _transientClients.remove(transientClient);
          transientClient.close();
        }
      }
      await _cancellableRetryDelay(
        Duration(milliseconds: 350 * (attempt + 1)),
      );
    }
    throw StateError('请求重试失败');
  }

  /// 后端冷启动或移动网络切换时，认证请求可能短暂收到 502/503/504
  /// 或在连接层超时。认证写入按设备幂等，允许短暂退避后重试。
  Future<http.Response> withTransientRetry(
    Future<http.Response> Function(http.Client client) request, {
    required Duration timeout,
    String? host,
  }) async {
    final resolvedHost = host ?? Uri.tryParse(config.baseUrl)?.host;
    const attempts = 3;
    for (var attempt = 0; attempt < attempts; attempt++) {
      _ensureNotDisposed();
      final transientClient = _clientFactory();
      _transientClients.add(transientClient);
      try {
        final response = await request(transientClient).timeout(timeout);
        final retryable =
            response.statusCode == 502 ||
            response.statusCode == 503 ||
            response.statusCode == 504;
        if (!retryable) return response;
        if (resolvedHost != null && resolvedHost.isNotEmpty) {
          ResilientDnsResolver.instance.invalidate(resolvedHost);
        }
        if (attempt == attempts - 1) return response;
      } catch (_) {
        if (resolvedHost != null && resolvedHost.isNotEmpty) {
          ResilientDnsResolver.instance.invalidate(resolvedHost);
        }
        if (_disposed || attempt == attempts - 1) rethrow;
      } finally {
        // Future.timeout 不会自动关闭底层 socket；每次重试结束后关闭本次
        // 专用客户端，不能触碰同时进行的共享 API 请求。
        _transientClients.remove(transientClient);
        transientClient.close();
      }
      await _cancellableRetryDelay(
        Duration(milliseconds: 700 * (attempt + 1)),
      );
    }
    throw StateError('请求重试失败');
  }

  Future<Map<String, dynamic>> requestJsonMap(
    String path, {
    Map<String, dynamic>? body,
    String method = 'GET',
    String? opId,
    Map<String, String>? queryParameters,
    String fallback = '警情资料请求失败',
    String shapeError = '警情资料格式异常',
    Duration timeout = const Duration(seconds: 30),
    bool requireStatus200 = false,
  }) async {
    _ensureNotDisposed();
    final targetUri = queryParameters == null
        ? config.uri(path)
        : config.uri(path).replace(queryParameters: queryParameters);
    final request = http.Request(method, targetUri);
    request.headers.addAll(config.opHeaders(opId));
    if (body != null) request.body = jsonEncode(body);
    final response = await (() async {
      final stream = await _client.send(request);
      return http.Response.fromStream(stream);
    })().timeout(timeout);
    final value = decodeJson(response, fallback: fallback);
    final statusOk = requireStatus200
        ? response.statusCode == 200
        : (response.statusCode >= 200 && response.statusCode < 300);
    if (!statusOk) {
      throw apiException(response, body: value, fallback: fallback);
    }
    if (value is! Map) throw responseShapeException(response, shapeError);
    return Map<String, dynamic>.from(value);
  }

  Future<List<Map<String, dynamic>>> requestJsonList(
    String path, {
    String fallback = '读取列表失败',
    String shapeError = '列表格式异常',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _ensureNotDisposed();
    final response = await _client
        .get(config.uri(path), headers: config.headers)
        .timeout(timeout);
    final value = decodeJson(response, fallback: fallback);
    if (response.statusCode != 200) {
      throw apiException(response, body: value, fallback: fallback);
    }
    if (value is! List) throw responseShapeException(response, shapeError);
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }
}
