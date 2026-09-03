import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/api_client.dart';

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
  WebSocket? _socket;
  bool _closed = false;

  RealtimeClient({
    required this.api,
    required this.onMessage,
    this.onError,
    this.onDone,
    SyncSocketFactory? socketFactory,
  }) : socketFactory = socketFactory ?? _defaultSocketFactory;

  static Future<WebSocket> _defaultSocketFactory(
    Uri uri, {
    Map<String, dynamic>? headers,
  }) => WebSocket.connect(uri.toString(), headers: headers);

  bool get connected => _socket?.readyState == WebSocket.open;

  Future<void> connect({
    required String unitCursor,
    required String incidentCursor,
    String? incidentId,
  }) async {
    await disconnect();
    _closed = false;
    final socket = await socketFactory(
      api.realtimeSyncUri(),
      headers: api.realtimeSyncHeaders(),
    );
    if (_closed) {
      socket.close();
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
    final socket = _socket;
    _socket = null;
    if (socket != null) await socket.close(WebSocketStatus.normalClosure);
  }

  void dispose() {
    unawaited(disconnect());
  }
}
