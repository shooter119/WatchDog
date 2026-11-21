/// 首页「现场地图」高德 JS API 2.0 引导配置与安全代理票据。
class SceneMapBootstrap {
  final bool configured;
  final String jsKey;
  final bool hasSecurityProxy;
  final String? proxyPath;
  final int expiresInMs;
  final String? code;
  final String? message;

  const SceneMapBootstrap({
    required this.configured,
    this.jsKey = '',
    this.hasSecurityProxy = false,
    this.proxyPath,
    this.expiresInMs = 0,
    this.code,
    this.message,
  });

  factory SceneMapBootstrap.fromJson(Map<String, dynamic> json) {
    final rawProxyPath = (json['proxyPath']?.toString() ?? '').trim();
    final rawCode = (json['code']?.toString() ?? '').trim();
    final rawMessage = (json['message']?.toString() ?? '').trim();
    return SceneMapBootstrap(
      configured: json['configured'] == true,
      jsKey: (json['jsKey']?.toString() ?? '').trim(),
      hasSecurityProxy: json['hasSecurityProxy'] == true,
      proxyPath: rawProxyPath.isNotEmpty ? rawProxyPath : null,
      expiresInMs: (json['expiresInMs'] as num?)?.toInt() ?? 0,
      code: rawCode.isNotEmpty ? rawCode : null,
      message: rawMessage.isNotEmpty ? rawMessage : null,
    );
  }

  /// 将相对代理路径与客户端当前后端基址拼合为完整的 `serviceHost`。
  String? resolveServiceHost(String baseUrl) {
    final path = proxyPath?.trim() ?? '';
    if (!hasSecurityProxy || path.isEmpty) return null;
    final cleanBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$cleanBase$path');
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri.toString();
  }
}
