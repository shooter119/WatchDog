import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../design_system/design_system.dart';
import '../../features/incident/data/incident_import_repository.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/incident/data/models/incident_force.dart';
import '../../features/incident/ui/sheets/incident_force_edit_sheet.dart';
import '../../features/incident/ui/sheets/incident_level_sheet.dart';
import '../../features/incident/ui/widgets/incident_key_site_card.dart';
import '../../features/key_sites/data/models/key_sites.dart';
import '../../features/roster/data/models/station.dart';
import '../../state/app_controller.dart';
import 'field_tools_router.dart';

/// 指挥台警情操作与重点单位绑定协调器（零旧 `pages/`、`theme/`、`widgets/` 依赖）。
class CommandHomeIncidentActions {
  CommandHomeIncidentActions({
    required this.controller,
    required this.toolsRouter,
    required this.onOpenIncidentImport,
    required this.onShowMessage,
  });

  final AppController controller;
  final FieldToolsRouter toolsRouter;
  final IncidentImportOpener onOpenIncidentImport;
  final void Function(String message, {Duration duration}) onShowMessage;

  final Map<String, KeySiteVersion> _latestKeySites = <String, KeySiteVersion>{};

  IncidentImportRepository? buildImportRepository(String incidentId) {
    final api = controller.api;
    if (api == null) return null;
    return _ApiIncidentImportRepository(api, incidentId: incidentId);
  }

  /// 构建可嵌入态势卡与警情详情页的重点单位关联卡。
  Widget buildKeySiteCard(Incident incident) {
    return IncidentKeySiteCard(
      accessListenable: controller,
      canReadKeySites: () => controller.canReadKeySites,
      protectedDataEpoch: () => controller.protectedDataEpoch,
      incident: incident,
      fetchIncidentKeySite: (String incidentId) async {
        final api = controller.api;
        if (api == null) {
          throw ApiException(
            '认证已失效，请重新加入单位后查阅',
            statusCode: 401,
            code: 'KEY_SITE_AUTH_REQUIRED',
          );
        }
        return api.fetchIncidentKeySite(incidentId);
      },
      onPickKeySite: toolsRouter.pickKeySiteForIncident,
      fetchLatestKeySite: (String siteId) async {
        final api = controller.api;
        if (api == null) throw StateError('未连接服务端');
        final latest = await api.fetchKeySite(siteId);
        _latestKeySites['${latest.siteId}:${latest.version}'] = latest;
        return KeySiteCandidate(
          siteId: latest.siteId,
          name: latest.name,
          version: latest.version,
        );
      },
      onChangeKeySiteLink: ({
        required String incidentId,
        required int revision,
        KeySiteCandidate? site,
        required String operationId,
      }) async {
        KeySiteVersion? version;
        if (site != null) {
          version =
              _latestKeySites['${site.siteId}:${site.version}'] ??
              await controller.api?.fetchKeySite(
                site.siteId,
                version: site.version,
              );
        }
        await controller.changeKeySiteLink(
          incidentId,
          revision: revision,
          operationId: operationId,
          site: version,
        );
      },
      onOpenKeySiteDetail: (
        BuildContext ctx,
        String siteId,
        int version,
        String incidentId,
      ) => toolsRouter.openKeySiteDetail(
        ctx,
        siteId: siteId,
        version: version,
        incidentId: incidentId,
      ),
    );
  }

  Future<void> renameIncident(String newTitle) async {
    try {
      await controller.renameCurrent(newTitle);
    } catch (error) {
      onShowMessage('修改名称失败：$error', duration: const Duration(seconds: 3));
    }
  }

  Future<void> archiveIncident() async {
    try {
      await controller.archiveCurrent();
    } catch (error) {
      onShowMessage('归档失败：$error', duration: const Duration(seconds: 3));
    }
  }

  Future<void> exitIncident() async {
    try {
      await controller.exitCurrentIncident();
    } catch (error) {
      onShowMessage('退出警情失败：$error', duration: const Duration(seconds: 3));
    }
  }

  Future<void> removeForce(IncidentForce force) async {
    try {
      await controller.removeForce(force.id);
    } catch (error) {
      onShowMessage('删除参战力量失败：$error', duration: const Duration(seconds: 3));
    }
  }

  Future<void> adjustIncidentLevel(BuildContext context) async {
    final incident = controller.currentIncident;
    if (incident == null) return;
    if (controller.isGuest) {
      onShowMessage('游客模式暂不支持调整警情等级', duration: const Duration(seconds: 2));
      return;
    }
    final result = await showIncidentLevelSheet(context, incident: incident);
    if (result == null) return;
    try {
      await controller.updateIncidentLevel(
        result.level,
        disasterCategory: result.disasterCategory,
      );
      onShowMessage('灾情等级已更新', duration: const Duration(seconds: 2));
    } catch (error) {
      onShowMessage('调整警情等级失败：$error', duration: const Duration(seconds: 3));
    }
  }

  Future<void> openImport(BuildContext context) async {
    if (controller.isGuest) {
      final goAuth = await showCommandSheet<bool>(
        context: context,
        title: '需要转为正式队员',
        builder: (BuildContext ctx) => Text(
          '警情智能分析与参战力量导入需调用单位云端 AI 智算服务，并将力量实时同步至全队。\n\n'
          '当前处于游客模式（单机演练），请先完成单位认证。',
          style: ctx.ds.typography.body.copyWith(
            color: ctx.ds.colors.textSecondary,
          ),
        ),
        actionsBuilder: (BuildContext ctx) => <Widget>[
          CommandButton(
            label: '暂不认证',
            variant: CommandButtonVariant.secondary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          CommandButton(
            label: '去完成认证',
            icon: Icons.verified_user_outlined,
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      );
      if (goAuth == true) unawaited(controller.leaveUnit());
      return;
    }
    final incident = controller.currentIncident;
    if (controller.api == null || incident == null) return;
    final applied = await onOpenIncidentImport(
      context,
      chooseSourceOnOpen: true,
    );
    if (applied == true) {
      try {
        await controller.refreshIncidentData(incident.id);
      } catch (error) {
        onShowMessage(
          '已提交，刷新资料失败：$error',
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> editForce(BuildContext context, {IncidentForce? force}) async {
    final api = controller.api;
    List<Station> stations = controller.stations;
    List<Map<String, dynamic>> commonStations = const <Map<String, dynamic>>[];
    if (api != null) {
      try {
        stations = await api.fetchStations();
        try {
          commonStations = await api.fetchUnitStations();
        } catch (_) {
          // 常用队伍读取失败时继续允许使用缓存或手填
        }
      } catch (_) {
        stations = controller.stations;
      }
    }
    if (!context.mounted) return;
    final stationNames = <String>{
      ...commonStations.map((Map<String, dynamic> s) => s['name'].toString()),
      ...stations.map((Station s) => s.name),
      if (force != null) force.stationName,
    }.toList();

    final result = await showIncidentForceEditSheet(
      context,
      force: force,
      stationNames: stationNames,
    );
    if (result == null) return;
    try {
      await controller.saveForce(
        forceId: force?.id,
        stationName: result.stationName,
        unitStationId: result.stationName == force?.stationName
            ? force?.unitStationId
            : commonStations
                  .where(
                    (Map<String, dynamic> s) => s['name'] == result.stationName,
                  )
                  .firstOrNull?['id']
                  ?.toString(),
        vehicleCount: result.vehicleCount,
        personnelCount: result.personnelCount,
        vehicleCountKnown: result.vehicleCountKnown,
        personnelCountKnown: result.personnelCountKnown,
        expectedVersion: force?.version,
      );
      if (result.saveCommon && api != null) {
        try {
          await api.addUnitStation(result.stationName);
        } catch (error) {
          onShowMessage(
            '力量已保存，常用队伍保存失败：$error',
            duration: const Duration(seconds: 3),
          );
        }
      }
    } catch (error) {
      if (context.mounted &&
          force != null &&
          error is ApiException &&
          error.code == 'FORCE_NAME_CONFLICT') {
        await _confirmForceMerge(context, force, result);
        return;
      }
      onShowMessage('保存参战力量失败：$error', duration: const Duration(seconds: 3));
    }
  }

  Future<void> _confirmForceMerge(
    BuildContext context,
    IncidentForce source,
    IncidentForceEditResult edit,
  ) async {
    final baseApi = controller.api;
    final candidates = controller.forces
        .where((IncidentForce f) => f.id != source.id)
        .toList();
    if (baseApi == null || candidates.isEmpty) return;

    final target = await showIncidentForceMergeSheet(
      context,
      source: source,
      candidates: candidates,
      targetName: edit.stationName,
      vehiclesText: edit.vehicleCountKnown ? '${edit.vehicleCount}' : '',
      peopleText: edit.personnelCountKnown ? '${edit.personnelCount}' : '',
    );
    if (target == null) return;

    final scoped = baseApi.forIncident(source.incidentId);
    try {
      await scoped.mergeIncidentForces(<String, dynamic>{
        'source_id': source.id,
        'target_id': target.id,
        'source_version': source.version,
        'target_version': target.version,
        'vehicle_count': edit.vehicleCount,
        'personnel_count': edit.personnelCount,
        'vehicle_count_known': edit.vehicleCountKnown,
        'personnel_count_known': edit.personnelCountKnown,
      }, 'force-merge-${DateTime.now().microsecondsSinceEpoch}');
      await controller.refreshIncidentData(source.incidentId);
    } catch (error) {
      onShowMessage('合并失败：$error', duration: const Duration(seconds: 3));
    } finally {
      scoped.dispose();
    }
  }
}

class _ApiIncidentImportRepository implements IncidentImportRepository {
  const _ApiIncidentImportRepository(this._api, {required this.incidentId});

  final ApiClient _api;
  final String incidentId;

  Future<T> _runScoped<T>(Future<T> Function(ApiClient client) action) async {
    if (_api.incidentId == incidentId) return action(_api);
    final scoped = _api.forIncident(incidentId);
    try {
      return await action(scoped);
    } finally {
      scoped.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() =>
      _runScoped((ApiClient c) => c.fetchIncidentDetails());

  @override
  Future<Map<String, dynamic>> updateIncidentDetails(
    Map<String, dynamic> data,
    int version,
    String opId,
  ) => _runScoped((ApiClient c) => c.updateIncidentDetails(data, version, opId));

  @override
  Future<Map<String, dynamic>> createIncidentImport({
    String? text,
    List<Uint8List> images = const <Uint8List>[],
  }) => _runScoped(
    (ApiClient c) => c.createIncidentImport(text: text, images: images),
  );

  @override
  Future<Uint8List> fetchImportImage(String id, int page) =>
      _runScoped((ApiClient c) => c.fetchImportImage(id, page));

  @override
  Future<Map<String, dynamic>> fetchIncidentImport(String id) =>
      _runScoped((ApiClient c) => c.fetchIncidentImport(id));

  @override
  Future<Map<String, dynamic>> retryIncidentImport(String id, List<int> pages) =>
      _runScoped((ApiClient c) => c.retryIncidentImport(id, pages));

  @override
  Future<Map<String, dynamic>> cancelIncidentImport(String id) =>
      _runScoped((ApiClient c) => c.cancelIncidentImport(id));

  @override
  Future<Map<String, dynamic>> applyIncidentImport(
    String id,
    Map<String, dynamic> body,
    String opId,
  ) => _runScoped((ApiClient c) => c.applyIncidentImport(id, body, opId));

  @override
  Future<List<Map<String, dynamic>>> fetchIncidentImports() =>
      _runScoped((ApiClient c) => c.fetchIncidentImports());
}
