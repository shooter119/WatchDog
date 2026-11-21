import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/network/network.dart';
import '../../../design_system/design_system.dart';
import '../../../services/key_site_recents.dart';
import '../data/key_sites_repository.dart';
import '../data/models/key_sites.dart';

/// 重点单位资料五大模块标签映射。
const Map<String, String> keySiteModules = <String, String>{
  'cards': '作战信息卡',
  'maps': '地图',
  'plans': '应急预案',
  'organization': '组织架构',
  'hazards': '危险品信息',
};

/// 重点单位模块对应图标。
IconData keySiteModuleIcon(String key) => switch (key) {
  'cards' => Icons.badge_outlined,
  'maps' => Icons.map_outlined,
  'plans' => Icons.assignment_outlined,
  'organization' => Icons.account_tree_outlined,
  'hazards' => Icons.science_outlined,
  _ => Icons.description_outlined,
};

/// 重点单位在线请求与权限校验网关（零 `AppController` / `ApiClient` 耦合）。
class KeySiteGateway {
  const KeySiteGateway({
    required this.accessListenable,
    required this.canReadKeySites,
    required this.readProtectedDataEpoch,
    required this.readServerBaseUrl,
    required this.recents,
    required this.keySiteAccess,
    required this.keySiteFilters,
    required this.fetchKeySites,
    required this.fetchRecentKeySites,
    required this.fetchKeySite,
    required this.fetchKeySiteImage,
    this.readClientIdentity,
  });

  /// 基于 [KeySitesRepository] 构建网关的便捷工厂。
  factory KeySiteGateway.fromRepository({
    required Listenable accessListenable,
    required bool Function() canReadKeySites,
    required int Function() readProtectedDataEpoch,
    required String Function() readServerBaseUrl,
    required KeySitesRepository? Function() readRepository,
    KeySiteRecents? recents,
  }) {
    KeySitesRepository requireRepo() {
      final repo = readRepository();
      if (repo == null) {
        throw ApiException(
          '认证已失效，请重新加入单位后查阅',
          statusCode: 401,
          code: 'KEY_SITE_AUTH_REQUIRED',
        );
      }
      return repo;
    }

    return KeySiteGateway(
      accessListenable: accessListenable,
      canReadKeySites: canReadKeySites,
      readProtectedDataEpoch: readProtectedDataEpoch,
      readServerBaseUrl: readServerBaseUrl,
      readClientIdentity: readRepository,
      recents: recents ?? KeySiteRecents.instance,
      keySiteAccess: () => requireRepo().keySiteAccess(),
      keySiteFilters: () => requireRepo().keySiteFilters(),
      fetchKeySites:
          ({
            String search = '',
            String district = '',
            String type = '',
            int offset = 0,
          }) => requireRepo().fetchKeySites(
            search: search,
            district: district,
            type: type,
            offset: offset,
          ),
      fetchRecentKeySites: (ids) => requireRepo().fetchRecentKeySites(ids),
      fetchKeySite: (id, {int? version, String? incident}) =>
          requireRepo().fetchKeySite(id, version: version, incident: incident),
      fetchKeySiteImage:
          (
            siteId,
            version,
            attachmentId, {
            required String resource,
            String? incident,
          }) => requireRepo().fetchKeySiteImage(
            siteId,
            version,
            attachmentId,
            resource: resource,
            incident: incident,
          ),
    );
  }

  final Listenable accessListenable;
  final bool Function() canReadKeySites;
  final int Function() readProtectedDataEpoch;
  final String Function() readServerBaseUrl;
  final Object? Function()? readClientIdentity;
  final KeySiteRecents recents;

  final Future<Map<String, dynamic>> Function() keySiteAccess;
  final Future<Map<String, dynamic>> Function() keySiteFilters;
  final Future<Map<String, dynamic>> Function({
    String search,
    String district,
    String type,
    int offset,
  })
  fetchKeySites;
  final Future<List<KeySiteSummary>> Function(List<String> ids)
  fetchRecentKeySites;
  final Future<KeySiteVersion> Function(
    String id, {
    int? version,
    String? incident,
  })
  fetchKeySite;
  final Future<Uint8List> Function(
    String siteId,
    int version,
    String attachmentId, {
    required String resource,
    String? incident,
  })
  fetchKeySiteImage;
}

/// 将重点单位在线加载异常映射为清晰中文提示。
String keySiteError(Object error) {
  if (isApiAuthenticationFailure(error)) return '认证已失效，请重新加入单位后查阅';
  if (error is SocketException) return '网络未连接，资料仅支持在线查阅';
  if (error is TimeoutException) return '连接超时，请检查网络后重试';
  if (error is ApiException) return error.message;
  return '资料加载失败，请重试';
}

/// 重点单位加载失败占位与重试视图。
class KeySiteFailure extends StatelessWidget {
  const KeySiteFailure({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    return StatePlaceholder.error(
      title: '资料暂不可用',
      reason: keySiteError(error),
      retryLabel: '重试',
      onRetry: retry,
    );
  }
}

/// 重点单位高对比语义横幅（用于版本滞后提示、停用警示等）。
class KeySiteStatusBanner extends StatelessWidget {
  const KeySiteStatusBanner({
    super.key,
    required this.message,
    this.status = DsStatus.caution,
    this.icon = Icons.warning_amber_rounded,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final DsStatus status;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pair = ds.colors.statusColors(status);
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      accentStatus: status,
      backgroundColor: pair.pillBg,
      borderColor: pair.fill.withValues(alpha: 0.45),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: DsSizes.iconMd, color: pair.text),
              ),
              const SizedBox(width: DsSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: ds.typography.body.copyWith(
                    color: ds.colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: CommandButton(
                label: actionLabel!,
                onPressed: onAction,
                variant: CommandButtonVariant.secondary,
                size: CommandButtonSize.standard,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 重点单位认证闸门：每条资料路由受同步撤销信号保护，
/// 游客拦截或 `canReadKeySites` 撤销 / `protectedDataEpoch` 递增时立即销毁正文和图像。
class KeySiteGate extends StatelessWidget {
  const KeySiteGate({
    super.key,
    required this.gateway,
    required this.builder,
  });

  final KeySiteGateway gateway;
  final Widget Function(String scope) builder;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: gateway.accessListenable,
      builder: (context, _) {
        if (!gateway.canReadKeySites()) {
          return CommandScaffold(
            appBar: AppBar(title: const Text('重点单位')),
            body: const StatePlaceholder.empty(
              icon: Icons.verified_user_outlined,
              message: '仅已认证的有效成员可查阅',
              detail: '请加入单位或重新完成认证',
            ),
          );
        }
        return _VerifiedKeySiteAccess(
          key: ValueKey<Object>((
            gateway,
            gateway.readClientIdentity?.call(),
            gateway.readProtectedDataEpoch(),
          )),
          gateway: gateway,
          builder: builder,
        );
      },
    );
  }
}

class _VerifiedKeySiteAccess extends StatefulWidget {
  const _VerifiedKeySiteAccess({
    super.key,
    required this.gateway,
    required this.builder,
  });

  final KeySiteGateway gateway;
  final Widget Function(String scope) builder;

  @override
  State<_VerifiedKeySiteAccess> createState() => _VerifiedKeySiteAccessState();
}

class _VerifiedKeySiteAccessState extends State<_VerifiedKeySiteAccess> {
  late Future<String> _access;

  @override
  void initState() {
    super.initState();
    _access = _verify();
  }

  Future<String> _verify() async {
    final identity = await widget.gateway.keySiteAccess();
    if (!mounted) throw StateError('认证已变更');
    return widget.gateway.recents.begin(
      server: widget.gateway.readServerBaseUrl(),
      unitId: identity['unitId'] as String,
      memberId: identity['memberId'] as String,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _access,
      builder: (context, snapshot) {
        if (snapshot.hasData) return widget.builder(snapshot.data!);
        return CommandScaffold(
          appBar: AppBar(title: const Text('重点单位')),
          body: snapshot.hasError
              ? KeySiteFailure(
                  error: snapshot.error!,
                  retry: () => setState(() {
                    _access = _verify();
                  }),
                )
              : const StatePlaceholder.loading(message: '正在校验单位成员查阅权限...'),
        );
      },
    );
  }
}

/// 固定版本号读取已发布快照，供模块页与附件阅读页确保读到受控版本。
class KeySitePublishedSnapshot extends StatefulWidget {
  const KeySitePublishedSnapshot({
    super.key,
    required this.gateway,
    required this.site,
    required this.incidentId,
    required this.builder,
  });

  final KeySiteGateway gateway;
  final KeySiteVersion site;
  final String? incidentId;
  final Widget Function(KeySiteVersion current) builder;

  @override
  State<KeySitePublishedSnapshot> createState() =>
      _KeySitePublishedSnapshotState();
}

class _KeySitePublishedSnapshotState extends State<KeySitePublishedSnapshot> {
  late Future<KeySiteVersion> _data;

  Future<KeySiteVersion> _load() => widget.gateway.fetchKeySite(
    widget.site.siteId,
    version: widget.site.version,
    incident: widget.incidentId,
  );

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<KeySiteVersion>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasData) return widget.builder(snapshot.data!);
        return CommandScaffold(
          appBar: AppBar(title: const Text('单位资料')),
          body: snapshot.hasError
              ? KeySiteFailure(
                  error: snapshot.error!,
                  retry: () => setState(() {
                    _data = _load();
                  }),
                )
              : const StatePlaceholder.loading(message: '正在加载已发布资料...'),
        );
      },
    );
  }
}
