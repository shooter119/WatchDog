import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'realtime_sync_client.dart';
import 'sync_reducer.dart';

enum SyncConnectionState { stopped, bootstrapping, connecting, connected, reconnecting, error }

typedef SyncClientFactory = RealtimeClient Function({
  required ApiClient api,
  required void Function(Map<String, dynamic>) onMessage,
  void Function(Object)? onError,
  void Function()? onDone,
});

/// 管理 bootstrap、游标、WebSocket、补拉和 30 秒轻量校准。
class SyncCoordinator {
  static const connectedCheckpointInterval = Duration(seconds: 120);
  static const disconnectedCheckpointInterval = Duration(seconds: 30);

  /// 连接期降频规则：WS 在收事件时不需要每 30 秒盲拉；断线才用 30 秒兜底补齐。
  static Duration checkpointIntervalFor({required bool connected}) =>
      connected ? connectedCheckpointInterval : disconnectedCheckpointInterval;

  final ApiClient api;
  final void Function(Map<String, dynamic> snapshot) onSnapshot;
  final void Function(SyncEvent event) onEvent;
  final void Function(SyncConnectionState state, Object? error) onState;
  final SyncReducer reducer;
  final SyncClientFactory clientFactory;

  RealtimeClient? _client;
  Timer? _checkpointTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _stopped = true;
  bool _busy = false;
  bool _bootstrapped = false;
  Future<void>? _inFlightBootstrap;
  int _bootstrapGeneration = 0;
  String? _incidentId;
  String unitCursor = '0';
  String incidentCursor = '0';

  SyncCoordinator({
    required this.api,
    required this.onSnapshot,
    required this.onEvent,
    required this.onState,
    SyncReducer? reducer,
    SyncClientFactory? clientFactory,
  }) : reducer = reducer ?? SyncReducer(),
       clientFactory = clientFactory ?? _defaultClientFactory;

  static RealtimeClient _defaultClientFactory({
    required ApiClient api,
    required void Function(Map<String, dynamic>) onMessage,
    void Function(Object)? onError,
    void Function()? onDone,
  }) => RealtimeClient(api: api, onMessage: onMessage, onError: onError, onDone: onDone);

  bool get running => !_stopped;
  String? get incidentId => _incidentId;
  Duration get checkpointInterval =>
      checkpointIntervalFor(connected: _client?.connected == true);

  /// 当前生效的检查点间隔（30 秒 / 120 秒），供测试断言。
  @visibleForTesting
  Duration get debugCheckpointTimerPeriod => checkpointInterval;

  Future<void> start({String? incidentId}) async {
    _stopped = false;
    _bootstrapped = false;
    _bootstrapGeneration++;
    _inFlightBootstrap = null;
    _busy = false;
    _incidentId = incidentId?.isNotEmpty == true ? incidentId : null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    await _bootstrapAndConnect();
    if (_stopped) return;
    // 固定 30 秒节拍：连接期只放行每第 4 拍（等效 120 秒）。
    // 不做"按连接状态重建定时器"，否则连接抖动会不停重建、永远攒不满一拍。
    _checkpointTimer ??= Timer.periodic(
      disconnectedCheckpointInterval,
      (_) => _onCheckpointTick(),
    );
  }

  int _checkpointTicks = 0;

  void _onCheckpointTick() {
    if (_stopped) return;
    _checkpointTicks++;
    if (checkpointInterval == connectedCheckpointInterval &&
        _checkpointTicks % _connectedTickDivisor != 0) {
      return;
    }
    unawaited(_checkpoint());
  }

  /// 连接期把 30 秒节拍压成 120 秒：4 拍放行 1 拍。
  static final int _connectedTickDivisor =
      connectedCheckpointInterval.inSeconds ~/ disconnectedCheckpointInterval.inSeconds;

  Future<void> switchIncident(String? incidentId) async {
    if (_stopped) return;
    _incidentId = incidentId?.isNotEmpty == true ? incidentId : null;
    _bootstrapped = false;
    _bootstrapGeneration++;
    _inFlightBootstrap = null;
    _busy = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    final previousClient = _client;
    _client = null;
    await previousClient?.disconnect();
    if (_stopped) return;
    await _bootstrapAndConnect();
  }

  Future<void> checkpointNow({bool force = false}) async {
    if (_stopped) return;
    _reconnectAttempt = 0;
    if (!_bootstrapped || _client?.connected != true) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      if (force) {
        _bootstrapGeneration++;
        _inFlightBootstrap = null;
        _busy = false;
        final previousClient = _client;
        _client = null;
        if (previousClient != null) {
          unawaited(previousClient.disconnect().catchError((Object _) {}));
        }
        await _bootstrapAndConnect();
        return;
      }
      final inFlight = _inFlightBootstrap;
      if (inFlight != null) {
        await inFlight;
      } else {
        await _bootstrapAndConnect();
      }
      return;
    }
    await _checkpoint();
  }

  Future<void> _bootstrapAndConnect() {
    if (_stopped) return Future<void>.value();
    final inFlight = _inFlightBootstrap;
    if (inFlight != null) return inFlight;
    if (_busy) return Future<void>.value();
    final generation = ++_bootstrapGeneration;
    var settled = false;
    final future = _runBootstrap(
      generation,
      onSettled: () {
        settled = true;
        if (generation == _bootstrapGeneration) {
          _inFlightBootstrap = null;
        }
      },
    );
    if (!settled) {
      _inFlightBootstrap = future;
    }
    return future;
  }

  Future<void> _runBootstrap(
    int generation, {
    required VoidCallback onSettled,
  }) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _busy = true;
    onState(SyncConnectionState.bootstrapping, null);
    try {
      final snapshot = await api.fetchSyncBootstrap(forIncidentId: _incidentId);
      if (_stopped || generation != _bootstrapGeneration) return;
      _bootstrapped = true;
      final cursors = snapshot['cursors'] is Map
          ? Map<String, dynamic>.from(snapshot['cursors'] as Map)
          : <String, dynamic>{};
      unitCursor = cursors['unit']?.toString() ?? '0';
      incidentCursor = cursors['incident']?.toString() ?? '0';
      reducer.clear();
      onSnapshot(snapshot);
      await _connect(bootstrapGeneration: generation);
    } catch (error) {
      if (!_stopped && generation == _bootstrapGeneration) {
        onState(SyncConnectionState.error, error);
        if (!ApiClient.isAuthenticationFailure(error)) {
          _scheduleReconnect();
        }
      }
    } finally {
      if (generation == _bootstrapGeneration) {
        _busy = false;
      }
      onSettled();
    }
  }

  Future<void> _connect({int? bootstrapGeneration}) async {
    if (_stopped) return;
    if (bootstrapGeneration != null &&
        bootstrapGeneration != _bootstrapGeneration) {
      return;
    }
    onState(SyncConnectionState.connecting, null);
    late final RealtimeClient client;
    client = clientFactory(
      api: api,
      onMessage: _handleMessage,
      onError: (error) {
        if (_stopped || !identical(_client, client)) return;
        onState(SyncConnectionState.error, error);
        if (!ApiClient.isAuthenticationFailure(error) && !client.connected) {
          _scheduleReconnect();
        }
      },
      onDone: () {
        if (_stopped || !identical(_client, client)) return;
        _scheduleReconnect();
      },
    );
    final previousClient = _client;
    _client = client;
    if (previousClient != null) {
      unawaited(previousClient.disconnect());
    }
    try {
      await client.connect(
        unitCursor: unitCursor,
        incidentCursor: incidentCursor,
        incidentId: _incidentId,
      );
      if (_stopped ||
          !identical(_client, client) ||
          (bootstrapGeneration != null &&
              bootstrapGeneration != _bootstrapGeneration)) {
        await client.disconnect();
        return;
      }
      _reconnectAttempt = 0;
      onState(SyncConnectionState.connected, null);
    } catch (error) {
      await client.disconnect();
      if (identical(_client, client)) _client = null;
      if (_stopped) return;
      if (bootstrapGeneration != null &&
          bootstrapGeneration != _bootstrapGeneration) {
        return;
      }
      onState(SyncConnectionState.error, error);
      if (!ApiClient.isAuthenticationFailure(error)) {
        _scheduleReconnect();
      }
    }
  }

  void _handleMessage(Map<String, dynamic> message) {
    if (_stopped) return;
    final type = message['type']?.toString();
    if (type == 'auth_revoked') {
      final error = ApiException('登录已被撤销，请重新认证', statusCode: 401, code: 'SESSION_INVALID');
      onState(SyncConnectionState.error, error);
      return;
    }
    if (type == 'ready') {
      onState(SyncConnectionState.connected, null);
      return;
    }
    if (type == 'resync_required') {
      unawaited(_bootstrapAndConnect());
      return;
    }
    if (type != 'event') return;
    final event = SyncEvent.fromJson(message);
    final expected = event.stream == 'unit' ? unitCursor : incidentCursor;
    if (!reducer.accept(event, expectedCursor: expected)) {
      if (BigInt.tryParse(event.sequence) != BigInt.tryParse(expected)) {
        unawaited(_pullEvents());
      }
      return;
    }
    _setCursor(event);
    onEvent(event);
  }

  void _setCursor(SyncEvent event) {
    if (event.stream == 'unit') {
      unitCursor = event.sequence;
    } else {
      incidentCursor = event.sequence;
    }
  }

  Future<void> _checkpoint() async {
    if (_stopped || _busy) return;
    if (!_bootstrapped || _client?.connected != true) {
      await _bootstrapAndConnect();
      return;
    }
    try {
      final checkpoint = await api.fetchSyncCheckpoint(forIncidentId: _incidentId);
      if (_stopped) return;
      final cursors = checkpoint['cursors'] is Map
          ? Map<String, dynamic>.from(checkpoint['cursors'] as Map)
          : <String, dynamic>{};
      final unit = cursors['unit']?.toString() ?? unitCursor;
      final incident = cursors['incident']?.toString() ?? incidentCursor;
      if (unit != unitCursor || incident != incidentCursor) {
        await _pullEvents();
      }
      if (!_stopped && _client?.connected == true) {
        onState(SyncConnectionState.connected, null);
      }
    } catch (error) {
      if (!_stopped) {
        onState(SyncConnectionState.error, error);
        if (!ApiClient.isAuthenticationFailure(error) &&
            _client?.connected != true) {
          _scheduleReconnect();
        }
      }
    }
  }

  Future<void> _pullEvents() async {
    if (_stopped || _busy) return;
    _busy = true;
    var needsBootstrap = false;
    try {
      final events = await api.fetchSyncEvents(
        unitCursor: unitCursor,
        incidentCursor: incidentCursor,
        forIncidentId: _incidentId,
      );
      for (final raw in events) {
        final event = SyncEvent.fromJson(raw);
        final expected = event.stream == 'unit' ? unitCursor : incidentCursor;
        if (!reducer.accept(event, expectedCursor: expected)) {
          needsBootstrap = true;
          break;
        }
        _setCursor(event);
        onEvent(event);
      }
    } catch (_) {
      needsBootstrap = true;
    } finally {
      _busy = false;
    }
    if (needsBootstrap && !_stopped) await _bootstrapAndConnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    if (_reconnectTimer?.isActive == true) return;
    const delays = <int>[1, 2, 5, 10, 20, 30];
    final seconds = delays[_reconnectAttempt.clamp(0, delays.length - 1)];
    _reconnectAttempt++;
    onState(SyncConnectionState.reconnecting, null);
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      unawaited(_bootstrapAndConnect());
    });
  }

  Future<void> stop() async {
    _stopped = true;
    _bootstrapped = false;
    _bootstrapGeneration++;
    _inFlightBootstrap = null;
    _busy = false;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    final client = _client;
    _client = null;
    await client?.disconnect();
    onState(SyncConnectionState.stopped, null);
  }

  void dispose() {
    unawaited(stop());
  }
}
