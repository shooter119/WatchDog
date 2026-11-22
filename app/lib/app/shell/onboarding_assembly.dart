import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../features/auth/ui/onboarding_flow_shell.dart';
import '../../features/incident/data/models/external_incident.dart';
import '../../features/incident/data/models/incident.dart';
import '../../features/incident/data/models/incident_force.dart';
import '../../features/incident/state/incident_import_store.dart';
import '../../features/incident/ui/incident_import_page.dart';
import '../../features/incident/ui/incident_picker_page.dart';
import '../../features/incident/ui/sheets/incident_basic_info_sheet.dart';
import '../../state/app_controller.dart';
import 'incident_address_locator.dart';
import 'shell_voice_bridge.dart';

/// 新外壳全屏启动引导（单位认证 -> 待审 -> 选警情）与警情导入页装配器（M3g）。
///
/// 保持零旧 `pages/`、`theme/`、`widgets/` 依赖；向 [OnboardingFlowShell] 传入稳定
/// 的实例方法引用，避免父级重建导致引导状态机重复重置。
class OnboardingAssembly {
  const OnboardingAssembly({
    required this.controller,
    required this.onSelectTab,
    required this.onShowMessage,
  });

  final AppController controller;
  final ValueChanged<int> onSelectTab;
  final ShellVoiceMessageCallback onShowMessage;

  Future<void> _authenticate(
    String unitName,
    String realName,
    String unitCode,
  ) => controller.authenticate(
    unitName: unitName,
    realName: realName,
    unitCode: unitCode,
  );

  Future<Map<String, dynamic>> _applyMembership(
    String unitName,
    String realName,
    String unitCode, {
    String? stationName,
    String? phone,
    String? applyReason,
  }) => controller.applyUnitMembership(
    unitName: unitName,
    unitCode: unitCode,
    realName: realName,
    stationName: stationName,
    phone: phone,
    applyReason: applyReason,
  );

  void _showGateMessage(String message) =>
      onShowMessage(message, duration: const Duration(seconds: 3));

  Widget _buildIncidentPicker(BuildContext context) {
    return IncidentPickerPage(
      activeIncidents: controller.activeIncidents,
      externalIncidents: controller.externalIncidents,
      loading:
          !controller.needsAuthentication &&
          (controller.syncing || controller.api == null),
      externalLoading: controller.externalIncidentsLoading,
      onSelect: (Incident incident) =>
          controller.selectIncident(incident.id, knownIncident: incident),
      onCreate: controller.createIncident,
      onCreateWithDraft: (IncidentCreateDraft draft) => controller.createIncident(
        title: draft.title,
        location: draft.location,
        disasterCategory:
            draft.categoryExplicitlySelected ? draft.category.name : null,
        latitude: draft.latitude,
        longitude: draft.longitude,
      ),
      onLocateAddress: () => locateCurrentIncidentAddress(controller),
      onClaimExternal: (ExternalIncident ext) async {
        try {
          await controller.claimExternalIncident(ext);
        } catch (error) {
          onShowMessage(
            '认领建档失败：$error',
            duration: const Duration(seconds: 3),
          );
          rethrow;
        }
      },
      onRefreshExternal: ({bool forceRefresh = false}) =>
          controller.fetchExternalIncidents(forceRefresh: forceRefresh),
      onEnterWithoutIncident: () {
        controller.enterWithoutIncident();
        onSelectTab(ShellVoiceBridge.commandTabIndex);
      },
    );
  }

  /// 构建新外壳启动门禁全屏引导流（认证 -> 待审批 -> 选警情）。
  Widget buildStartupGate(BuildContext context) {
    return OnboardingFlowShell(
      authenticationRequired: controller.needsAuthentication,
      onAuthenticate: _authenticate,
      onApply: _applyMembership,
      onEnterGuestMode: controller.enterGuestMode,
      onShowMessage: _showGateMessage,
      incidentPickerBuilder: _buildIncidentPicker,
    );
  }

  /// 打开 DS v3.0 警情资料导入页（3 阶段：采集 -> 轮询 -> 核对确认）。
  Future<bool?> openIncidentImport(
    BuildContext context, {
    bool chooseSourceOnOpen = false,
  }) {
    final api = controller.api;
    final incident = controller.currentIncident;
    if (api == null || incident == null) return Future<bool?>.value(null);
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => IncidentImportPage(
          gateway: _ApiIncidentImportGateway(api, incidentId: incident.id),
          incident: incident,
          chooseSourceOnOpen: chooseSourceOnOpen,
        ),
      ),
    );
  }
}

class _ApiIncidentImportGateway implements IncidentImportGateway {
  const _ApiIncidentImportGateway(this._api, {required this.incidentId});

  final ApiClient _api;
  final String incidentId;

  @override
  String get cacheScope => _api.cacheScope;

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
  Future<List<Map<String, dynamic>>> fetchIncidentImports() =>
      _runScoped((ApiClient c) => c.fetchIncidentImports());

  @override
  Future<Map<String, dynamic>> createIncidentImport({
    String? text,
    List<Uint8List> images = const <Uint8List>[],
  }) => _runScoped(
    (ApiClient c) => c.createIncidentImport(text: text, images: images),
  );

  @override
  Future<Map<String, dynamic>> fetchIncidentImport(String taskId) =>
      _runScoped((ApiClient c) => c.fetchIncidentImport(taskId));

  @override
  Future<Uint8List> fetchImportImage(String taskId, int page) =>
      _runScoped((ApiClient c) => c.fetchImportImage(taskId, page));

  @override
  Future<Map<String, dynamic>> retryIncidentImport(
    String taskId,
    List<int> pages,
  ) => _runScoped((ApiClient c) => c.retryIncidentImport(taskId, pages));

  @override
  Future<Map<String, dynamic>> cancelIncidentImport(String taskId) =>
      _runScoped((ApiClient c) => c.cancelIncidentImport(taskId));

  @override
  Future<Map<String, dynamic>> applyIncidentImport(
    String taskId,
    Map<String, dynamic> body,
    String opId,
  ) => _runScoped((ApiClient c) => c.applyIncidentImport(taskId, body, opId));

  @override
  Future<Map<String, dynamic>> fetchIncidentDetails() =>
      _runScoped((ApiClient c) => c.fetchIncidentDetails());

  @override
  Future<Incident> fetchIncident(String incidentId) =>
      _api.fetchIncident(incidentId);

  @override
  Future<List<IncidentForce>> fetchIncidentForces() =>
      _api.fetchIncidentForces(forIncidentId: incidentId);

  @override
  Future<List<ImportStationOption>> fetchStationOptions() async {
    final options = <ImportStationOption>[];
    final seenNames = <String>{};
    try {
      final unitStations = await _api.fetchUnitStations();
      for (final raw in unitStations) {
        final name = (raw['name']?.toString() ?? '').trim();
        if (name.isEmpty || !seenNames.add(name)) continue;
        options.add(
          ImportStationOption(
            id: raw['id']?.toString() ?? '',
            name: name,
            isUnitStation: true,
          ),
        );
      }
    } catch (_) {}
    try {
      final stations = await _api.fetchStations();
      for (final station in stations) {
        final name = station.name.trim();
        if (name.isEmpty || !seenNames.add(name)) continue;
        options.add(
          ImportStationOption(
            id: station.id,
            name: name,
            isUnitStation: false,
          ),
        );
      }
    } catch (_) {}
    return options;
  }
}
