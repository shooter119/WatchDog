import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/models/incident_key_site_link.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../design_system/design_system.dart';
import '../../data/models/incident.dart';
import '../sheets/incident_key_site_confirm_sheet.dart';

/// 重点单位选择器与版本查询回调所使用的轻量脱敏 DTO（零跨 Feature 依赖）。
@immutable
class KeySiteCandidate {
  const KeySiteCandidate({
    required this.siteId,
    required this.name,
    required this.version,
  });

  final String siteId;
  final String name;
  final int version;
}

typedef IncidentKeySiteFetcher =
    Future<Map<String, dynamic>> Function(String incidentId);
typedef KeySitePickerCallback =
    Future<KeySiteCandidate?> Function(BuildContext context);
typedef KeySiteLatestFetcher = Future<KeySiteCandidate> Function(String siteId);
typedef IncidentKeySiteChangeCallback =
    Future<void> Function({
      required String incidentId,
      required int revision,
      KeySiteCandidate? site,
      required String operationId,
    });
typedef KeySiteDetailOpener =
    void Function(
      BuildContext context,
      String siteId,
      int version,
      String incidentId,
    );

/// 警情内嵌重点单位关联卡（Design System v3.0）。
///
/// 严格继承安全与协同不变量：
/// - `canReadKeySites == false` 时整块隐藏（`SizedBox.shrink`）；
/// - 内部状态组件强制挂载 `ValueKey('$protectedDataEpoch:${incident.id}')`；
/// - 30 秒定时刷新并响应 `keySiteLinkRevision` 乐观锁更新；
/// - 零 `features/key_sites/` 导入，全部选择器与详情跳转回调注入。
class IncidentKeySiteCard extends StatelessWidget {
  const IncidentKeySiteCard({
    super.key,
    required this.accessListenable,
    required this.canReadKeySites,
    required this.protectedDataEpoch,
    required this.incident,
    required this.fetchIncidentKeySite,
    required this.onPickKeySite,
    required this.fetchLatestKeySite,
    required this.onChangeKeySiteLink,
    required this.onOpenKeySiteDetail,
    this.refreshInterval = const Duration(seconds: 30),
  });

  final Listenable accessListenable;
  final bool Function() canReadKeySites;
  final int Function() protectedDataEpoch;
  final Incident incident;
  final IncidentKeySiteFetcher fetchIncidentKeySite;
  final KeySitePickerCallback onPickKeySite;
  final KeySiteLatestFetcher fetchLatestKeySite;
  final IncidentKeySiteChangeCallback onChangeKeySiteLink;
  final KeySiteDetailOpener onOpenKeySiteDetail;
  final Duration refreshInterval;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: accessListenable,
      builder: (BuildContext context, Widget? _) {
        if (!canReadKeySites()) return const SizedBox.shrink();
        return _IncidentKeySiteLinkBody(
          key: ValueKey<String>('${protectedDataEpoch()}:${incident.id}'),
          host: this,
        );
      },
    );
  }
}

class _IncidentKeySiteLinkBody extends StatefulWidget {
  const _IncidentKeySiteLinkBody({super.key, required this.host});

  final IncidentKeySiteCard host;

  @override
  State<_IncidentKeySiteLinkBody> createState() =>
      _IncidentKeySiteLinkBodyState();
}

class _IncidentKeySiteLinkBodyState extends State<_IncidentKeySiteLinkBody> {
  Map<String, dynamic>? _state;
  Object? _error;
  bool _busy = false;
  bool _saving = false;
  bool _loading = false;
  int _generation = 0;
  Timer? _refreshTimer;

  IncidentKeySiteCard get _host => widget.host;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(_host.refreshInterval, (_) {
      if (!_busy && !_loading && _host.canReadKeySites()) _load();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _IncidentKeySiteLinkBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.incident.keySiteLinkRevision !=
        _host.incident.keySiteLinkRevision) {
      _load();
    }
  }

  static String _formatError(Object error) {
    if (error is ApiException &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      return '认证已失效，请重新加入单位后查阅';
    }
    if (error is SocketException) return '网络未连接，资料仅支持在线查阅';
    if (error is TimeoutException) return '连接超时，请检查网络后重试';
    if (error is ApiException) return error.message;
    return '资料加载失败，请重试';
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _loading = true;
    try {
      final data = await _host.fetchIncidentKeySite(_host.incident.id);
      if (mounted && generation == _generation) {
        setState(() {
          _state = data;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  Future<void> _change({bool remove = false, bool update = false}) async {
    final epoch = _host.protectedDataEpoch();
    setState(() => _busy = true);
    final revision =
        (_state?['revision'] as num?)?.toInt() ??
        _host.incident.keySiteLinkRevision;
    try {
      KeySiteCandidate? site;
      if (!remove) {
        final String? siteId;
        if (update) {
          siteId = (_state?['link'] as Map?)?['siteId']?.toString();
        } else {
          siteId = (await _host.onPickKeySite(context))?.siteId;
        }
        if (!mounted ||
            !_host.canReadKeySites() ||
            epoch != _host.protectedDataEpoch() ||
            siteId == null ||
            siteId.isEmpty) {
          return;
        }
        site = await _host.fetchLatestKeySite(siteId);
      }
      if (!mounted ||
          !_host.canReadKeySites() ||
          epoch != _host.protectedDataEpoch()) {
        return;
      }

      final confirmed = await showKeySiteAuthAwareConfirmSheet(
        context,
        accessListenable: _host.accessListenable,
        canReadKeySites: _host.canReadKeySites,
        protectedDataEpoch: _host.protectedDataEpoch,
        expectedEpoch: epoch,
        remove: remove,
        siteName: site?.name ?? '',
      );
      if (confirmed != true ||
          !mounted ||
          !_host.canReadKeySites() ||
          epoch != _host.protectedDataEpoch()) {
        return;
      }
      setState(() => _saving = true);
      await _host.onChangeKeySiteLink(
        incidentId: _host.incident.id,
        revision: revision,
        site: site,
        operationId:
            'site-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
      );
      await _load();
    } catch (error) {
      await _load();
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _saving = false;
        });
      }
    }
  }

  List<String> _linkedProfileTags(IncidentKeySiteLink link) {
    final history = _state?['history'];
    if (history is! List) return const <String>[];
    Map<dynamic, dynamic>? matched;
    for (final raw in history) {
      if (raw is! Map || raw['site_id']?.toString() != link.siteId) continue;
      final profile = raw['profile'];
      if (profile is! Map) continue;
      if ((raw['version'] as num?)?.toInt() == link.version) {
        matched = profile;
        break;
      }
      matched ??= profile;
    }
    if (matched == null) return const <String>[];
    final tags = <String>[];
    for (final key in const <String>['district', 'site_type']) {
      final value = matched[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && !tags.contains(value)) tags.add(value);
    }
    return tags;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    final rawLink = _state?['link'];
    final IncidentKeySiteLink? link = rawLink is Map
        ? IncidentKeySiteLink.fromJson(Map<String, dynamic>.from(rawLink))
        : (_state == null ? _host.incident.keySiteLink : null);

    if (link == null && !_host.incident.isActive && _error == null) {
      return const SizedBox.shrink();
    }

    final canSearch = !_busy && _state != null;
    final profileTags = link == null
        ? const <String>[]
        : _linkedProfileTags(link);

    return SurfaceCard(
      level: DsSurfaceLevel.flat,
      borderColor: colors.border,
      borderRadius: DsRadius.borderMd,
      padding: link == null
          ? const EdgeInsets.symmetric(horizontal: DsSpacing.md)
          : const EdgeInsets.all(DsSpacing.md),
      onTap: (link == null && _host.incident.isActive && canSearch)
          ? _change
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (link == null)
            _buildUnlinkedRow(colors, typo, canSearch)
          else
            _buildLinkedBody(context, link, profileTags, canSearch),
          if (_error != null) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            SurfaceCard(
              level: DsSurfaceLevel.flat,
              backgroundColor: colors.statusColors(DsStatus.alarm).pillBg,
              borderColor: colors.alarmFill.withValues(alpha: 0.3),
              padding: const EdgeInsets.all(DsSpacing.sm),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _formatError(_error!),
                      style: typo.caption.copyWith(color: colors.alarmText),
                    ),
                  ),
                  CommandButton(
                    label: '重试',
                    variant: CommandButtonVariant.ghost,
                    size: CommandButtonSize.standard,
                    enabled: !_busy,
                    onPressed: _load,
                  ),
                ],
              ),
            ),
          ],
          if (_saving) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  Widget _buildUnlinkedRow(DsColors colors, DsTypography typo, bool canSearch) {
    final fg = canSearch ? colors.brandText : colors.textTertiary;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
      child: Row(
        children: <Widget>[
          Icon(Icons.domain_add_outlined, size: DsSizes.iconMd, color: colors.textSecondary),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              '绑定重点单位',
              style: typo.body.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
            ),
          ),
          if (_host.incident.isActive)
            InkWell(
              key: const Key('key-site-search'),
              borderRadius: DsRadius.borderSm,
              onTap: canSearch ? _change : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: DsSizes.touchTarget,
                  minHeight: DsSizes.touchTarget,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('点击绑定', style: typo.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
                    Icon(Icons.chevron_right_rounded, size: DsSizes.iconMd, color: fg),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLinkedBody(
    BuildContext context,
    IncidentKeySiteLink link,
    List<String> profileTags,
    bool canSearch,
  ) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final isActive = _host.incident.isActive;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.domain_verification_outlined, size: DsSizes.iconMd, color: colors.brandText),
            const SizedBox(width: DsSpacing.sm),
            Expanded(child: Text(link.name, style: typo.title.copyWith(color: colors.textPrimary))),
          ],
        ),
        if (profileTags.isNotEmpty) ...<Widget>[
          const SizedBox(height: DsSpacing.xs),
          Wrap(
            spacing: DsSpacing.xs,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              for (final tag in profileTags)
                StatusPill(status: DsStatus.neutral, icon: Icons.apartment_outlined, label: tag),
            ],
          ),
        ],
        if (_state?['newVersionAvailable'] == true) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          Text(
            '已有新版资料，请人工核对后更新',
            style: typo.caption.copyWith(color: colors.cautionText, fontWeight: FontWeight.w700),
          ),
        ],
        if (_state?['active'] == false) ...<Widget>[
          const SizedBox(height: DsSpacing.xs),
          Text('重点单位已停用，保留历史引用', style: typo.caption.copyWith(color: colors.textSecondary)),
        ],
        const SizedBox(height: DsSpacing.sm),
        Wrap(
          spacing: DsSpacing.xs,
          runSpacing: DsSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            CommandButton(
              key: const Key('key-site-open'),
              label: '单位资料',
              icon: Icons.folder_open_outlined,
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              onPressed: () => _host.onOpenKeySiteDetail(
                context,
                link.siteId,
                link.version,
                _host.incident.id,
              ),
            ),
            if (isActive) ...<Widget>[
              CommandButton(
                key: const Key('key-site-change'),
                label: '切换',
                variant: CommandButtonVariant.ghost,
                size: CommandButtonSize.standard,
                enabled: canSearch,
                onPressed: canSearch ? _change : null,
              ),
              CommandButton(
                key: const Key('key-site-remove'),
                label: '解除',
                variant: CommandButtonVariant.ghost,
                size: CommandButtonSize.standard,
                enabled: !_busy,
                onPressed: _busy ? null : () => _change(remove: true),
              ),
            ],
            if (isActive && _state?['newVersionAvailable'] == true && _state?['active'] == true)
              CommandButton(
                key: const Key('key-site-update'),
                label: '核对新版',
                variant: CommandButtonVariant.ghost,
                size: CommandButtonSize.standard,
                enabled: !_busy,
                onPressed: _busy ? null : () => _change(update: true),
              ),
          ],
        ),
      ],
    );
  }
}
