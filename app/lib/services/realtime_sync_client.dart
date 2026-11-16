import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/api_client.dart';
import 'resilient_dns.dart';

typedef SyncMessageHandler = void Function(Map<String, dynamic> message);
typedef SyncSocketFactory = Future<WebSocket> Function(Uri uri, {Map<String, dynamic>? headers});

/// 一个设备的业务实时连接。重连退避由 SyncCoordinator 管理，避免把
/// WebSocket 生命周期和业务状态混在页面控制器里。
class RealtimeClient {
  final ApiClient api;
  final SyncMessageHandler onMessage;
  final void Function(Object error)? onError;
  final void Function()? onDone;
  final SyncSocketFactory socketFactory;
  final Duration connectTimeout;
  WebSocket? _socket;
  bool _closed = false;
  int _connectEpoch = 0;

  RealtimeClient({
    required this.api,
    required this.onMessage,
    this.onError,
    this.onDone,
    SyncSocketFactory? socketFactory,
    this.connectTimeout = const Duration(seconds: 12),
  }) : socketFactory =
           socketFactory ??
           ((uri, {headers}) => connectResilientWebSocket(
                 uri.toString(),
                 headers: headers,
                 timeout: connectTimeout,
               ));

  bool get connected => _socket?.readyState == WebSocket.open;

  Future<void> connect({
    required String unitCursor,
    required String incidentCursor,
    String? incidentId,
  }) async {
    final previousSocket = _socket;
    _socket = null;
    _closed = false;
    final epoch = ++_connectEpoch;
    if (previousSocket != null) {
      try {
        await previousSocket.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
    if (_closed || epoch != _connectEpoch) return;

    final socketFuture = socketFactory(
      api.realtimeSyncUri(),
      headers: api.realtimeSyncHeaders(),
    );
    var timedOut = false;
    final socket = await socketFuture.timeout(
      connectTimeout,
      onTimeout: () {
        timedOut = true;
        unawaited(
          socketFuture.then(
            (lateSocket) => lateSocket.close(WebSocketStatus.goingAway),
            onError: (_) {},
          ),
        );
        throw TimeoutException(
          'Realtime WebSocket connection timed out',
          connectTimeout,
        );
      },
    );
    if (_closed || timedOut || epoch != _connectEpoch) {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {}
      return;
    }
    _socket = socket;
    socket.listen(
      (data) {
        try {
          final decoded = jsonDecode(data.toString());
          if (decoded is Map) onMessage(Map<String, dynamic>.from(decoded));
        } catch (error) {
          onError?.call(error);
        }
      },
      onError: (Object error) => onError?.call(error),
      onDone: () {
        if (!_closed) onDone?.call();
      },
      cancelOnError: false,
    );
    socket.add(jsonEncode({
      'type': 'subscribe',
      'unit_cursor': unitCursor,
      'incident_cursor': incidentCursor,
      if (incidentId != null && incidentId.isNotEmpty) 'incident_id': incidentId,
    }));
  }

  Future<void> disconnect() async {
    _closed = true;
    _connectEpoch++;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
  }

  void dispose() {
    unawaited(disconnect());
  }
}
