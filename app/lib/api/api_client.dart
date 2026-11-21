import 'dart:typed_data';

import '../core/diagnostics/log_repository.dart';
import '../core/network/api_config.dart';
import '../core/network/api_exceptions.dart';
import '../core/network/api_http_transport.dart';
import '../core/sync/sync_repository.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/data/models/admin_login.dart';
import '../features/auth/data/models/unit_member.dart';
import '../features/copilot/data/copilot_repository.dart';
import '../features/copilot/data/models/chat_message.dart';
import '../features/copilot/data/models/vision_analysis.dart';
import '../features/hazmat/data/hazmat_repository.dart';
import '../features/hazmat/data/models/hazmat.dart';
import '../features/incident/data/incident_import_repository.dart';
import '../features/incident/data/incident_repository.dart';
import '../features/incident/data/models/external_incident.dart';
import '../features/incident/data/models/incident.dart';
import '../features/incident/data/models/incident_event.dart';
import '../features/incident/data/models/incident_force.dart';
import '../features/key_sites/data/key_sites_repository.dart';
import '../features/key_sites/data/models/key_sites.dart';
import '../features/map/data/map_repository.dart';
import '../features/map/data/models/route_traffic_info.dart';
import '../features/map/data/models/scene_map_bootstrap.dart';
import '../features/media/data/media_repository.dart';
import '../features/media/data/models/weather_info.dart';
import '../features/monitor/data/models/calc_config.dart';
import '../features/monitor/data/models/entry.dart';
import '../features/monitor/data/monitor_repository.dart';
import '../features/notes/data/models/note.dart';
import '../features/notes/data/notes_repository.dart';
import '../features/roster/data/models/firefighter.dart';
import '../features/roster/data/models/hotword.dart';
import '../features/roster/data/models/station.dart';
import '../features/roster/data/roster_repository.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/video/data/models/video_resource.dart';
import '../features/video/data/video_repository.dart';
import '../features/voice/data/models/voice_parse.dart';
import '../features/voice/data/voice_repository.dart';
import '../features/water_sources/data/models/water_source.dart';
import '../features/water_sources/data/water_sources_repository.dart';

export '../core/network/api_exceptions.dart' show ApiException;
export '../core/network/sse_parser.dart' show SseEvent, SseLineParser;
export '../features/auth/data/models/unit_member.dart' show UnitMember;
export '../features/incident/data/models/incident_create_conflict_exception.dart'
    show IncidentCreateConflictException;
export '../features/monitor/data/monitor_exceptions.dart'
    show EntryConflictException;

part 'api_client_ops_facade.dart';
part 'api_client_command_facade.dart';
part 'api_client_tools_facade.dart';

abstract class _ApiClientBase {
  final String baseUrl;
  final String incidentId;
  final String apiToken;
  final String deviceId;
  final String actorName;
  final String unitId;
  final String unitCode;
  final String sessionToken;
  final void Function(ApiException error)? onAuthenticationFailure;

  final ApiHttpTransport _transport;

  _ApiClientBase({
    required this.baseUrl,
    required this.incidentId,
    this.apiToken = '',
    this.deviceId = '',
    this.actorName = '',
    this.unitId = '',
    this.unitCode = '',
    this.sessionToken = '',
    this.onAuthenticationFailure,
  }) : _transport = ApiHttpTransport(
         ApiConfig(
           baseUrl: baseUrl,
           incidentId: incidentId,
           apiToken: apiToken,
           deviceId: deviceId,
           actorName: actorName,
           unitId: unitId,
           unitCode: unitCode,
           sessionToken: sessionToken,
           onAuthenticationFailure: onAuthenticationFailure,
         ),
       );

  late final SyncRepository _sync = SyncRepository(_transport);
  late final LogRepository _log = LogRepository(_transport);
  late final AuthRepository _auth = AuthRepository(_transport);
  late final MonitorRepository _monitor = MonitorRepository(_transport);
  late final SettingsRepository _settings = SettingsRepository(_transport);
  late final IncidentRepository _incident = IncidentRepository(_transport);
  late final IncidentImportRepository _incidentImport =
      IncidentImportRepository(_transport);
  late final NotesRepository _notes = NotesRepository(_transport);
  late final VoiceRepository _voice = VoiceRepository(_transport);
  late final CopilotRepository _copilot = CopilotRepository(_transport);
  late final RosterRepository _roster = RosterRepository(_transport);
  late final MapRepository _map = MapRepository(_transport);
  late final MediaRepository _media = MediaRepository(_transport);
  late final VideoRepository _video = VideoRepository(_transport);
  late final KeySitesRepository _keySites = KeySitesRepository(_transport);
  late final HazmatRepository _hazmat = HazmatRepository(_transport);
  late final WaterSourcesRepository _waterSources = WaterSourcesRepository(
    _transport,
  );
}

class ApiClient extends _ApiClientBase
    with _OpsApiFacade, _CommandApiFacade, _ToolsApiFacade {
  ApiClient({
    required super.baseUrl,
    required super.incidentId,
    super.apiToken = '',
    super.deviceId = '',
    super.actorName = '',
    super.unitId = '',
    super.unitCode = '',
    super.sessionToken = '',
    super.onAuthenticationFailure,
  });

  ApiClient forIncident(String id) => ApiClient(
    baseUrl: baseUrl,
    incidentId: id,
    apiToken: apiToken,
    deviceId: deviceId,
    actorName: actorName,
    unitId: unitId,
    unitCode: unitCode,
    sessionToken: sessionToken,
    onAuthenticationFailure: onAuthenticationFailure,
  );

  /// 辅助 AI 不属于任何警情，也不参与警情协同。
  ApiClient forAssistant() => ApiClient(
    baseUrl: baseUrl,
    incidentId: '',
    apiToken: apiToken,
    deviceId: deviceId,
    actorName: actorName,
    unitId: unitId,
    unitCode: unitCode,
    sessionToken: sessionToken,
    onAuthenticationFailure: onAuthenticationFailure,
  );

  String get cacheScope => _transport.cacheScope;

  Uri realtimeAsrUri() => realtimeAsrUris().first;

  /// 取消当前辅助问答的底层请求（页面超时、离开页面或用户重试时调用）。
  void cancelChatRequest() {
    _transport.cancelChatRequest();
  }

  /// 释放 API 客户端及其底层 socket。
  void dispose() {
    cancelChatRequest();
    _transport.dispose();
  }

  static bool isAuthenticationFailure(Object error) =>
      isApiAuthenticationFailure(error);
}
