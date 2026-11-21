part of 'app_controller.dart';

mixin _AppControllerMonitorMixin on _AppControllerBase {
  @override
  Future<void> _clearScheduledNotifications() async {
    final ids = List<String>.of(_scheduled.keys);
    _scheduled.clear();
    if (!_alarmReady) return;
    for (final id in ids) {
      try {
        await alarm.cancelForEntry(id);
      } catch (_) {
        // 插件未就绪或已被系统回收时，清理本地状态仍应完成。
      }
    }
    try {
      await alarm.stopAlarm();
    } catch (_) {}
  }


  @override
  Future<void> _rescheduleNotifications() async {
    if (!_alarmReady) return;
    final active = entries.where((e) => e.isActive).toList();
    final activeIds = active.map((e) => e.id).toSet();
    final allIds = entries.map((e) => e.id).toSet();

    for (final e in active) {
      if (AppController.shouldRescheduleNotification(
        scheduledExitAt: _scheduled[e.id],
        exitAt: e.exitAt,
      )) {
        try {
          await alarm.cancelForEntry(e.id);
          await alarm.scheduleForEntry(
            e,
            warnMin: calcConfig.warnMin,
            alarmMin: calcConfig.alarmMin,
          );
          _scheduled[e.id] = e.exitAt;
        } catch (_) {
          _scheduled.remove(e.id);
          rethrow;
        }
      }
    }
    // 已出火场或已消失的条目：取消通知
    for (final id in List.of(_scheduled.keys)) {
      if (!activeIds.contains(id) || !allIds.contains(id)) {
        _scheduled.remove(id);
        await alarm.cancelForEntry(id);
      }
    }
  }

  /// 通知只在 `exitAt` 变化（改名/压力复核）时重排；同一到期时间重复同步不得反复
  /// cancel+schedule，否则每次快照都会白跑 3 个精确闹钟的 IPC。
  @override
  void _checkThresholds() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var inDanger = false;
    for (final e in entries.where((e) => e.isActive)) {
      final remaining = e.exitAt - now;
      if (remaining <= 0) {
        inDanger = true;
        _announce(e, 'timeout', '${e.name}超时！${e.name}超时！立即确认！');
      } else if (remaining <= calcConfig.alarmMin * 60000) {
        inDanger = true;
        _announce(
          e,
          'alarm',
          '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，立即撤离！',
        );
      } else if (remaining <= calcConfig.warnMin * 60000) {
        _announce(
          e,
          'warn',
          '${e.name}，气瓶剩余${(remaining / 60000).ceil()}分钟，准备撤离。',
        );
      }
    }
    // 红色（alarm/timeout）状态持续循环警报，全部脱险后停止
    if (inDanger) {
      unawaited(_startAlarmLoopSafely());
    } else {
      unawaited(_stopAlarmSafely());
    }
  }

  Future<void> _startAlarmLoopSafely() async {
    try {
      await alarm.startAlarmLoop();
    } catch (error) {
      AppLogger.error('AlarmService start loop failed', tag: 'alarm', error: error);
    }
  }

  Future<void> _stopAlarmSafely() async {
    try {
      await alarm.stopAlarm();
    } catch (error) {
      AppLogger.error('AlarmService stop failed', tag: 'alarm', error: error);
    }
  }

  void _announce(Entry e, String kind, String text) {
    final key = '${e.id}:$kind';
    if (_announced[key] != null) return;
    _announced[key] = DateTime.now().millisecondsSinceEpoch;
    tts.speak(text);
    alarm.fire(key, ttsText: text);
  }

  Future<Entry?> createEntryFromVoice({
    required String name,
    required double pressureMpa,
    String? rawText,
    bool force = false,
    double? volumeL,
    String? opId,
  }) async {
    final incident = currentIncident;
    if (incident == null) throw StateError('请先选择或新建警情');
    final operationApi = api;
    final owner = <String, String>{
      'unit_id': operationApi?.unitId ?? '',
      'member_id': await Settings.memberId,
    };
    Entry e;
    try {
      e = await operationApi!.createEntry(
        name: name,
        pressureMpa: pressureMpa,
        source: 'voice',
        rawText: rawText,
        force: force,
        volumeL: volumeL,
        consumptionLpm: calcConfig.consumptionLpm,
        opId: opId,
      );
    } catch (error) {
      if (!_isNetworkError(error)) rethrow;
      final id = 'offline-entry-${DateTime.now().microsecondsSinceEpoch}';
      final at = DateTime.now().millisecondsSinceEpoch;
      final volume = volumeL ?? calcConfig.cylinderVolL;
      final duration = (volume * pressureMpa * 10 / calcConfig.consumptionLpm)
          .round();
      await OfflineQueue.instance.enqueue(
        owner: owner,
        incidentId: incident.id,
        type: 'entry',
        occurredAt: at,
        clientOpId: opId ?? id,
        payload: {
          'entry_id': id,
          'name': name,
          'pressure_mpa': pressureMpa,
          'volume_l': volume,
          'consumption_lpm': calcConfig.consumptionLpm,
          'raw_text': rawText,
        },
      );
      e = Entry(
        id: id,
        name: name,
        pressureMpa: pressureMpa,
        durationMin: duration,
        entryAt: at,
        exitAt: at + duration * 60000,
        source: 'offline',
        rawText: rawText,
        cylinderVolL: volume,
        consumptionLpm: calcConfig.consumptionLpm,
      );
    }
    // 提交成功立即插入本地列表并通知（看板即时显示倒计时），
    // 不依赖 sync 网络结果——网络不稳时同步失败也不影响本地展示
    if (api != operationApi) return e;
    entries = [e, ...entries.where((x) => x.id != e.id)];
    _notify();
    await sync();
    return e;
  }

  /// 合并：同名已在场的记录按本次复核压力重新倒计时（保留原记录，不重复计数）
  Future<Entry> mergeEntryPressure({
    required String id,
    required double pressureMpa,
    String? opId,
    int? expectedVersion,
  }) async {
    if (!entries.any((entry) => entry.id == id)) await sync();
    final e = await updatePressure(
      id: id,
      expectedVersion: expectedVersion,
      pressureMpa: pressureMpa,
      opId: opId,
    );
    await sync();
    return e;
  }

  /// 更新压力：对在场人员提交一次压力读数（动态耗气率的采样点，服务端差分重算倒计时）
  Future<Entry> updatePressure({
    required String id,
    required double pressureMpa,
    String? opId,
    int? expectedVersion,
  }) async {
    final op = opId ?? '';
    OpLogService.instance.record(
      op,
      'pressure_report',
      '更新压力 ${pressureMpa}MPa',
      data: {'entryId': id},
    );
    final current = entries.firstWhere((entry) => entry.id == id);
    final incident = currentIncident;
    final operationApi = api;
    final owner = <String, String>{
      'unit_id': operationApi?.unitId ?? '',
      'member_id': await Settings.memberId,
    };
    Entry e;
    try {
      e = await operationApi!.updateEntry(
        id: id,
        expectedVersion: expectedVersion ?? current.version,
        pressureMpa: pressureMpa,
        consumptionLpm: calcConfig.consumptionLpm,
        opId: op,
      );
    } catch (error) {
      if (error is ApiException &&
          [
            'VERSION_CONFLICT',
            'ENTRY_EXITED',
            'STALE_PRESSURE',
          ].contains(error.code)) {
        await sync();
        rethrow;
      }
      if (!_isNetworkError(error) || incident == null) rethrow;
      final occurredAt = DateTime.now().millisecondsSinceEpoch;
      final volume = current.cylinderVolL ?? calcConfig.cylinderVolL;
      final consumption = current.consumptionLpm ?? calcConfig.consumptionLpm;
      final clientOpId = op.isEmpty
          ? 'offline-pressure-${DateTime.now().microsecondsSinceEpoch}'
          : op;
      final payload = {
        'entry_id': id,
        'expected_version': expectedVersion ?? current.version,
        'name': current.name,
        'pressure_mpa': pressureMpa,
        'volume_l': volume,
        'consumption_lpm': consumption,
      };
      final enqueue = _offlineOperationEnqueuer;
      if (enqueue != null) {
        await enqueue(
          incidentId: incident.id,
          type: 'pressure',
          occurredAt: occurredAt,
          clientOpId: clientOpId,
          payload: payload,
        );
      } else {
        await OfflineQueue.instance.enqueue(
          owner: owner,
          incidentId: incident.id,
          type: 'pressure',
          occurredAt: occurredAt,
          clientOpId: clientOpId,
          payload: payload,
        );
      }
      final duration = calcConfig
          .durationMinFor(
            pressureMpa,
            cylinderVolL: volume,
            consumptionLpm: consumption,
          )
          .round();
      e = current.copyWith(
        pressureMpa: pressureMpa,
        durationMin: duration,
        exitAt: occurredAt + duration * 60000,
        cylinderVolL: volume,
        consumptionLpm: consumption,
      );
    }
    if (api != operationApi) return e;
    entries = [for (final entry in entries) entry.id == id ? e : entry];
    _notify();
    await sync();
    return e;
  }

  Future<void> markExited(
    String id, {
    String? opId,
    int? expectedVersion,
  }) async {
    final incident = currentIncident;
    final current = entries.firstWhere((e) => e.id == id);
    final operationApi = api;
    final owner = <String, String>{
      'unit_id': operationApi?.unitId ?? '',
      'member_id': await Settings.memberId,
    };
    try {
      await operationApi!.markExited(
        id,
        opId: opId,
        expectedVersion: expectedVersion ?? current.version,
      );
    } catch (error) {
      if (error is ApiException &&
          [
            'VERSION_CONFLICT',
            'ENTRY_EXITED',
            'STALE_PRESSURE',
          ].contains(error.code)) {
        await sync();
        rethrow;
      }
      if (!_isNetworkError(error) || incident == null) rethrow;
      final exitedAt = DateTime.now().millisecondsSinceEpoch;
      await OfflineQueue.instance.enqueue(
        owner: owner,
        incidentId: incident.id,
        type: 'exit',
        occurredAt: exitedAt,
        clientOpId:
            opId ?? 'offline-exit-${DateTime.now().microsecondsSinceEpoch}',
        payload: {
          'entry_id': id,
          'expected_version': expectedVersion ?? current.version,
          'name': current.name,
        },
      );
      if (api != operationApi) return;
      entries = [
        for (final entry in entries)
          entry.id == id ? entry.copyWith(exitedAt: exitedAt) : entry,
      ];
      _notify();
    }
    await sync();
  }

}
