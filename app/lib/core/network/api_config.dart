import 'dart:convert';

import '../../services/settings.dart';
import 'api_exceptions.dart';

class ApiConfig {
  final String baseUrl;
  final String incidentId;
  final String apiToken;
  final String deviceId;
  final String actorName;
  final String unitId;
  final String unitCode;
  final String sessionToken;
  final void Function(ApiException error)? onAuthenticationFailure;

  const ApiConfig({
    required this.baseUrl,
    required this.incidentId,
    this.apiToken = '',
    this.deviceId = '',
    this.actorName = '',
    this.unitId = '',
    this.unitCode = '',
    this.sessionToken = '',
    this.onAuthenticationFailure,
  });

  ApiConfig forIncident(String id) => ApiConfig(
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
  ApiConfig forAssistant() => ApiConfig(
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

  Map<String, String> get headers => {
    'Content-Type': 'application/json',
    if (incidentId.isNotEmpty) 'X-Incident-Id': incidentId,
    if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
    if (sessionToken.isNotEmpty) 'Authorization': 'Bearer $sessionToken',
    if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
    if (unitId.isNotEmpty) 'X-Unit-Id': unitId,
    if (unitCode.isNotEmpty) 'X-Unit-Code': unitCode,
    // HTTP 头只能安全承载 ASCII/Latin-1；消防员实名通常是中文，
    // 直接放入 X-Actor-Name 会被 Dart http 拒绝并导致所有请求失败。
    if (actorName.isNotEmpty)
      'X-Actor-Name-B64': base64Encode(utf8.encode(actorName)),
  };

  /// 带操作 ID 的头（opId 贯穿一次语音操作的完整链路，服务端埋点与客户端对齐）
  Map<String, String> opHeaders(String? opId) => {
    ...headers,
    if (opId != null && opId.isNotEmpty) 'X-Op-Id': opId,
  };

  Uri uri(String path) {
    if (!Settings.isSafeHttpUrl(baseUrl)) {
      throw StateError('服务器地址不安全');
    }
    final parsed = Uri.tryParse('$baseUrl$path');
    if (parsed == null || parsed.host.isEmpty) {
      throw StateError('服务器地址无效');
    }
    return parsed;
  }

  String get cacheScope => unitId.isEmpty ? '' : '$baseUrl|$unitId|$actorName';
}
