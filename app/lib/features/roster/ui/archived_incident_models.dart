import 'package:flutter/foundation.dart';

/// 已归档警情的轻量化视图模型（隔离 `features/incident/` 跨 Feature 依赖）。
@immutable
class ArchivedIncidentView {
  const ArchivedIncidentView({
    required this.id,
    required this.number,
    this.title,
    this.suggestedTitle,
    required this.createdAt,
    required this.lastActivityAt,
    this.archivedAt,
    this.archivedBy,
    this.autoArchived = false,
    this.unresolvedActiveCount = 0,
    this.version = 1,
    this.forceStationCount = 0,
    this.vehicleCount = 0,
    this.personnelCount = 0,
    this.unknownVehicleStationCount = 0,
    this.unknownPersonnelStationCount = 0,
  });

  final String id;
  final String number;
  final String? title;
  final String? suggestedTitle;
  final int createdAt;
  final int lastActivityAt;
  final int? archivedAt;
  final String? archivedBy;
  final bool autoArchived;
  final int unresolvedActiveCount;
  final int version;
  final int forceStationCount;
  final int vehicleCount;
  final int personnelCount;
  final int unknownVehicleStationCount;
  final int unknownPersonnelStationCount;

  String get displayName =>
      (title ?? '').trim().isEmpty ? number : title!.trim();

  ArchivedIncidentView copyWithTitle(String? newTitle, {int? nextVersion}) {
    final normalized = (newTitle ?? '').trim().isEmpty
        ? null
        : newTitle!.trim();
    return ArchivedIncidentView(
      id: id,
      number: number,
      title: normalized,
      suggestedTitle: suggestedTitle,
      createdAt: createdAt,
      lastActivityAt: lastActivityAt,
      archivedAt: archivedAt,
      archivedBy: archivedBy,
      autoArchived: autoArchived,
      unresolvedActiveCount: unresolvedActiveCount,
      version: nextVersion ?? version + 1,
      forceStationCount: forceStationCount,
      vehicleCount: vehicleCount,
      personnelCount: personnelCount,
      unknownVehicleStationCount: unknownVehicleStationCount,
      unknownPersonnelStationCount: unknownPersonnelStationCount,
    );
  }
}

/// 归档复盘参战力量快照视图模型。
@immutable
class ArchivedIncidentForceView {
  const ArchivedIncidentForceView({
    required this.stationName,
    required this.vehicleLabel,
    required this.personnelLabel,
  });

  final String stationName;
  final String vehicleLabel;
  final String personnelLabel;
}

/// 归档复盘时间线事件视图模型。
@immutable
class ArchivedIncidentEventView {
  const ArchivedIncidentEventView({
    required this.type,
    required this.text,
    required this.occurredAt,
    this.actorName,
    this.source,
    this.revisionOf,
  });

  final String type;
  final String text;
  final int occurredAt;
  final String? actorName;
  final String? source;
  final String? revisionOf;
}

/// 已归档警情列表与复盘详情的数据网关。
abstract class ArchivedIncidentsGateway {
  Future<List<ArchivedIncidentView>> fetchArchivedIncidents();
  Future<ArchivedIncidentView> renameIncident(
    ArchivedIncidentView incident,
    String title,
  );
  Future<List<ArchivedIncidentEventView>> fetchTimeline(String incidentId);
  Future<List<ArchivedIncidentForceView>> fetchForces(String incidentId);
}

String formatArchiveTime(int ms, {bool withSeconds = false}) {
  if (ms <= 0) return '-';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final minute = '${d.minute}'.padLeft(2, '0');
  final second = withSeconds ? ':${'${d.second}'.padLeft(2, '0')}' : '';
  return '${d.year}年${d.month}月${d.day}日 ${d.hour}:$minute$second';
}

String archiveMethodLabel(bool autoArchived) =>
    autoArchived ? '自动归档' : '手动归档';
