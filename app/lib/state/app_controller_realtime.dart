part of 'app_controller.dart';

mixin _AppControllerRealtimeMixin on _AppControllerBase {
  @override
  void _applySyncSnapshot(Map<String, dynamic> snapshot) {
    if (_disposed) return;
    _syncSnapshotApplied = true;
    unawaited(refreshPendingMembersCount());
    final roster = snapshot['roster'] is Map
        ? Map<String, dynamic>.from(snapshot['roster'] as Map)
        : <String, dynamic>{};
    orgDirectory.applySnapshot(
      roster: roster,
      stations: snapshot.containsKey('stations') ? snapshot['stations'] : null,
    );
    final active = snapshot['active_incidents'] as List? ?? const [];
    activeIncidents = active
        .whereType<Map>()
        .map((item) => Incident.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final directoryApi = api;
    if (directoryApi != null && snapshot['unit_stations'] is List) {
      unawaited(
        ScopedJsonCache.write(
          directoryApi.cacheScope,
          'directory:active',
          snapshot['unit_stations'] as List,
        ),
      );
    }
    final incidentSnapshot = snapshot['incident_snapshot'];
    if (incidentSnapshot is Map) {
      final data = Map<String, dynamic>.from(incidentSnapshot);
      final details = data['incident_details'];
      if (directoryApi != null && details is Map) {
        unawaited(
          ScopedJsonCache.write(
            directoryApi.cacheScope,
            'details:${details['incident_id']}',
            details,
          ),
        );
      }
      final incident = data['incident'];
      currentIncident = incident is Map
          ? Incident.fromJson(Map<String, dynamic>.from(incident))
          : currentIncident;
      entries = (data['entries'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Entry.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      notes = (data['notes'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Note.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      forces = (data['forces'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => IncidentForce.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    } else if ((snapshot['cursors'] as Map?)?['incident'] == '0') {
      currentIncident = null;
      entries = [];
      notes = [];
      forces = [];
    }
    final unitId = (snapshot['unit'] as Map?)?['id']?.toString();
    if (unitId != null && unitId.isNotEmpty) unawaited(_cacheRoster(unitId));
    unawaited(
      localAsr?.updateHotwords(orgDirectory.asrTerms).catchError((Object _) {}) ??
          Future<void>.value(),
    );
    _lastSyncSuccessAt = _nowMs();
    _firstSyncFailureAt = 0;
    _lastConnectionLost = connectionLost;
    syncError = null;
    _recomputeSyncing();
    _reportMainSnapshotToKeepAlive();
    unawaited(_rescheduleNotifications());
    _notify();
  }

  @override
  void _applySyncEvent(SyncEvent event) {
    if (_disposed) return;
    final payload = event.payload;
    switch (event.eventType) {
      case 'members.applications_changed':
        unawaited(refreshPendingMembersCount());
        break;
      case 'admin.capability_changed':
        unawaited(refreshPendingMembersCount());
        if (adminCapability != null &&
            payload['memberId'] != adminCapability!.memberId) {
          break;
        }
        adminCapability = null;
        _notify();
        unawaited(refreshAdminCapability());
        break;
      case 'incident.created':
      case 'incident.updated':
      case 'incident.archived':
        final raw = payload.isNotEmpty ? payload : null;
        if (raw == null) break;
        final incident = Incident.fromJson(raw);
        activeIncidents = [
          if (incident.isActive) incident,
          ...activeIncidents.where((item) => item.id != incident.id),
        ];
        if (currentIncident?.id == incident.id) {
          currentIncident = incident.isActive ? incident : null;
          if (!incident.isActive) {
            entries = [];
            notes = [];
            forces = [];
          }
        }
        break;
      case 'entry.created':
      case 'entry.pressure_updated':
      case 'entry.exited':
        if (payload.isEmpty) break;
        final entry = Entry.fromJson(payload);
        entries = [entry, ...entries.where((item) => item.id != entry.id)];
        break;
      case 'note.created':
      case 'note.updated':
        if (payload.isEmpty) break;
        final note = Note.fromJson(payload);
        notes = [note, ...notes.where((item) => item.id != note.id)];
        break;
      case 'note.deleted':
        final id = event.aggregateId ?? payload['id']?.toString();
        if (id != null) notes = notes.where((item) => item.id != id).toList();
        break;
      case 'import.applied':
        final importDetailsApi = api;
        if (importDetailsApi != null && payload['details'] is Map) {
          final details = payload['details'] as Map;
          unawaited(
            ScopedJsonCache.write(
              importDetailsApi.cacheScope,
              'details:${details['incident_id']}',
              details,
            ),
          );
        }
        if (payload['incident'] is Map) {
          final incident = Incident.fromJson(
            Map<String, dynamic>.from(payload['incident'] as Map),
          );
          if (currentIncident?.id == incident.id) {
            currentIncident = incident;
            forces = (payload['forces'] as List? ?? [])
                .map(
                  (f) => IncidentForce.fromJson(
                    Map<String, dynamic>.from(f as Map),
                  ),
                )
                .toList();
          }
        }
        break;
      case 'directory.updated':
        final directoryApi = api;
        if (directoryApi != null) {
          unawaited(
            directoryApi.fetchUnitStations().catchError(
              (_) => <Map<String, dynamic>>[],
            ),
          );
        }
        break;
      case 'details.updated':
        final detailsApi = api;
        if (detailsApi != null && payload['incident_id'] != null) {
          unawaited(
            ScopedJsonCache.write(
              detailsApi.cacheScope,
              'details:${payload['incident_id']}',
              payload,
            ),
          );
        }
        final id = currentIncident?.id;
        if (id != null) unawaited(refreshIncidentData(id));
        break;
      case 'force.upserted':
        if (payload.isEmpty) break;
        final force = IncidentForce.fromJson(payload);
        forces = [force, ...forces.where((item) => item.id != force.id)];
        break;
      case 'force.deleted':
        final id = event.aggregateId ?? payload['id']?.toString();
        if (id != null) forces = forces.where((item) => item.id != id).toList();
        break;
      case 'roster.firefighter_added':
      case 'roster.firefighter_removed':
      case 'roster.hotword_added':
      case 'roster.hotword_removed':
      case 'roster.station_added':
      case 'roster.station_removed':
        if (orgDirectory.applyEvent(event)) {
          final rosterUnitId = api?.unitId ?? '';
          if (rosterUnitId.isNotEmpty) unawaited(_cacheRoster(rosterUnitId));
          unawaited(
            localAsr?.updateHotwords(orgDirectory.asrTerms).catchError(
                  (Object _) {},
                ) ??
                Future<void>.value(),
          );
        }
        break;
    }
    _lastSyncSuccessAt = _nowMs();
    _firstSyncFailureAt = 0;
    _lastConnectionLost = connectionLost;
    _recomputeSyncing();
    _reportMainSnapshotToKeepAlive();
    unawaited(_rescheduleNotifications());
    _notify();
  }

}

(List<Entry>, List<Note>) _applyOfflineOperationProjection({
    required Iterable<Map<String, Object?>> rows,
    required List<Entry> entries,
    required List<Note> notes,
    required CalcConfig calcConfig,
    required String author,
  }) {
    var projectedEntries = List<Entry>.of(entries);
    var projectedNotes = List<Note>.of(notes);
    for (final row in rows) {
      try {
        final rawPayload = row['payload'];
        if (rawPayload is! String) continue;
        final decoded = jsonDecode(rawPayload);
        if (decoded is! Map) continue;
        final payload = Map<String, dynamic>.from(decoded);
        final type = row['type']?.toString();
        final occurredAt = (row['occurred_at'] as num?)?.toInt() ?? 0;
        if (occurredAt <= 0) continue;
        switch (type) {
          case 'entry':
            final id = payload['entry_id']?.toString();
            final name = payload['name']?.toString();
            final pressure = _offlineNumber(payload['pressure_mpa']);
            if (id == null || id.isEmpty || name == null || name.isEmpty) {
              continue;
            }
            if (pressure == null || pressure <= 0) continue;
            final volume =
                _offlineNumber(payload['volume_l']) ?? calcConfig.cylinderVolL;
            final consumption =
                _offlineNumber(payload['consumption_lpm']) ??
                calcConfig.consumptionLpm;
            final duration = calcConfig
                .durationMinFor(
                  pressure,
                  cylinderVolL: volume,
                  consumptionLpm: consumption,
                )
                .round();
            final entry = Entry(
              id: id,
              name: name,
              pressureMpa: pressure,
              durationMin: duration,
              entryAt: occurredAt,
              exitAt: occurredAt + duration * 60000,
              source: 'offline',
              rawText: payload['raw_text']?.toString(),
              cylinderVolL: volume,
              consumptionLpm: consumption,
            );
            projectedEntries = [
              entry,
              ...projectedEntries.where((item) => item.id != id),
            ];
          case 'pressure':
            final id = payload['entry_id']?.toString();
            final pressure = _offlineNumber(payload['pressure_mpa']);
            if (id == null || id.isEmpty || pressure == null || pressure <= 0) {
              continue;
            }
            final index = projectedEntries.indexWhere((item) => item.id == id);
            if (index < 0) continue;
            final current = projectedEntries[index];
            final volume =
                _offlineNumber(payload['volume_l']) ??
                current.cylinderVolL ??
                calcConfig.cylinderVolL;
            final consumption =
                _offlineNumber(payload['consumption_lpm']) ??
                current.consumptionLpm ??
                calcConfig.consumptionLpm;
            final duration = calcConfig
                .durationMinFor(
                  pressure,
                  cylinderVolL: volume,
                  consumptionLpm: consumption,
                )
                .round();
            projectedEntries = [
              for (final item in projectedEntries)
                item.id == id
                    ? item.copyWith(
                        pressureMpa: pressure,
                        durationMin: duration,
                        exitAt: occurredAt + duration * 60000,
                        cylinderVolL: volume,
                        consumptionLpm: consumption,
                      )
                    : item,
            ];
          case 'exit':
            final id = payload['entry_id']?.toString();
            if (id == null || id.isEmpty) continue;
            projectedEntries = [
              for (final item in projectedEntries)
                item.id == id ? item.copyWith(exitedAt: occurredAt) : item,
            ];
          case 'note':
            final id = payload['note_id']?.toString();
            final text = payload['text']?.toString();
            if (id == null || id.isEmpty || text == null || text.isEmpty) {
              continue;
            }
            projectedNotes = [
              Note(
                id: id,
                text: text,
                category: payload['category']?.toString() ?? NoteCategory.other,
                author: author,
                createdAt: occurredAt,
                updatedAt: occurredAt,
              ),
              ...projectedNotes.where((item) => item.id != id),
            ];
        }
      } catch (_) {
        // 单条损坏的本地记录不能阻塞其他合法操作的恢复。
      }
    }
    return (projectedEntries, projectedNotes);
  }

