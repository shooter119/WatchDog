import 'package:flutter/material.dart';

import '../../core/diagnostics/app_logger.dart';
import '../../core/sync/sync_store.dart';
import '../../features/monitor/data/models/entry.dart';
import '../../features/monitor/state/alert_clock_store.dart';
import '../../features/monitor/state/monitor_store.dart';
import '../../features/monitor/ui/monitor_page.dart';
import '../../features/notes/data/models/note_category.dart';
import '../../state/app_controller.dart';

/// 将既有 [AppController] 的在场数据、时钟节拍与同步健康度桥接为 M3a DS v3.0
/// `MonitorPage` 所需的三个独立 Store，避免重复启动定时器和重复播报。
class ShellMonitorAdapter {
  ShellMonitorAdapter({required this.controller}) {
    _syncStore = _ControllerSyncStore(controller);
    _monitorStore = _ControllerMonitorStore(controller);
    alertClockStore = AlertClockStore(
      alarm: controller.alarm,
      tts: controller.tts,
      entriesProvider: () => _monitorStore.entries,
      calcConfigProvider: () => _monitorStore.calcConfig,
    );
    alertClockStore.clockTick.value = controller.clockTick.value;
    _lastSoundEnabled = controller.alarm.soundEnabled;

    controller.addListener(_onControllerChanged);
    controller.clockTick.addListener(_onClockTick);
  }

  final AppController controller;
  late final _ControllerSyncStore _syncStore;
  late final _ControllerMonitorStore _monitorStore;
  late final AlertClockStore alertClockStore;

  SyncStore get syncStore => _syncStore;
  MonitorStore get monitorStore => _monitorStore;

  late bool _lastSoundEnabled;
  bool _disposed = false;

  void _onControllerChanged() {
    if (_disposed) return;
    _monitorStore.syncFromController();
    _syncStore.notifyBridgeChanged();
    final soundEnabled = controller.alarm.soundEnabled;
    if (soundEnabled != _lastSoundEnabled) {
      _lastSoundEnabled = soundEnabled;
      alertClockStore.notifySoundStateChanged();
    }
  }

  void _onClockTick() {
    if (_disposed) return;
    alertClockStore.clockTick.value = controller.clockTick.value;
  }

  /// 按 ID 查找当前在场/历史人员记录（供全局语音同名冲突弹窗复用）。
  Entry? findEntryById(String id) {
    final fromStore = monitorStore.findById(id);
    if (fromStore != null) return fromStore;
    for (final entry in controller.entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// 构建新外壳 Tab 1（现场监控）页面。
  Widget buildMonitorPage(
    BuildContext context, {
    required VoidCallback onGoVoice,
  }) {
    return MonitorPage(
      monitorStore: monitorStore,
      alertClockStore: alertClockStore,
      syncStore: syncStore,
      isGuest: controller.isGuest,
      requiresIncident: controller.requiresIncident,
      onRefresh: controller.refreshNow,
      onGoVoice: onGoVoice,
      onRequestIncidentSelection: controller.requestIncidentSelection,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_onControllerChanged);
    controller.clockTick.removeListener(_onClockTick);
    monitorStore.dispose();
    alertClockStore.dispose();
    syncStore.dispose();
  }
}

/// 实时读取 [AppController] 同步健康状态的轻量 [SyncStore] 代理。
class _ControllerSyncStore extends SyncStore {
  _ControllerSyncStore(this._controller);

  final AppController _controller;

  @override
  SyncConnectionState get syncConnectionState =>
      _controller.syncConnectionState;

  @override
  bool get syncing => _controller.syncing;

  @override
  String? get syncError => _controller.syncError;

  @override
  bool get connectionLost => _controller.connectionLost;

  void notifyBridgeChanged() {
    if (!isDisposed) notifyListeners();
  }
}

/// 将 [MonitorStore] 写操作委托给 [AppController]，确保离线队列、实时同步与
/// 既有警情状态保持单一真相源。
class _ControllerMonitorStore extends MonitorStore {
  _ControllerMonitorStore(this._controller)
    : super(
        initialEntries: _controller.entries,
        initialCalcConfig: _controller.calcConfig,
        onSpeak: _controller.tts.speak,
      );

  final AppController _controller;

  void syncFromController() {
    if (disposed) return;
    setEntries(_controller.entries, notify: false);
    setCalcConfig(_controller.calcConfig, notify: true);
  }

  @override
  Future<Entry> createEntryFromVoice({
    required String name,
    required double pressureMpa,
    String? rawText,
    bool force = false,
    double? volumeL,
    String? opId,
  }) async {
    final created = await _controller.createEntryFromVoice(
      name: name,
      pressureMpa: pressureMpa,
      rawText: rawText,
      force: force,
      volumeL: volumeL,
      opId: opId,
    );
    syncFromController();
    if (created == null) {
      throw StateError('进场登记未返回有效记录');
    }
    return created;
  }

  @override
  Future<Entry> mergeEntryPressure({
    required String id,
    required double pressureMpa,
    String? opId,
    int? expectedVersion,
  }) async {
    final updated = await _controller.mergeEntryPressure(
      id: id,
      pressureMpa: pressureMpa,
      opId: opId,
      expectedVersion: expectedVersion,
    );
    syncFromController();
    return updated;
  }

  @override
  Future<Entry> updatePressure({
    required String id,
    required double pressureMpa,
    String? opId,
    int? expectedVersion,
    bool recordNote = false,
  }) async {
    final current = findById(id);
    final updated = await _controller.updatePressure(
      id: id,
      pressureMpa: pressureMpa,
      opId: opId,
      expectedVersion: expectedVersion,
    );
    syncFromController();
    if (recordNote && current != null) {
      try {
        await _controller.addNote(
          '${current.name} 更新气瓶压力为 ${MonitorStore.formatPressure(pressureMpa)} MPa',
          category: 'entry',
        );
      } catch (error) {
        AppLogger.error('ShellMonitorAdapter pressure note failed', tag: 'monitor', error: error);
      }
    }
    return updated;
  }

  @override
  Future<void> markExited(
    String id, {
    String? opId,
    int? expectedVersion,
  }) async {
    await _controller.markExited(
      id,
      opId: opId,
      expectedVersion: expectedVersion,
    );
    syncFromController();
  }

  @override
  Future<void> recordExitActionLog(Entry entry, {String? opId}) async {
    await _controller.addActionLog(
      names: <String>[entry.name],
      action: '出场',
      category: NoteCategory.withdraw,
      opId:
          opId ??
          'manual-exit-note-${entry.id}-${DateTime.now().millisecondsSinceEpoch}',
    );
  }
}
