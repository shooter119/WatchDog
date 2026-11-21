import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/key_sites.dart';
import 'key_site_gate.dart';
import 'key_site_module_page.dart';

/// 重点单位详情页：通过 [KeySiteGate] 受保护读取指定或最新版本，记录最近查看，并导航至五大资料模块。
class KeySiteDetailPage extends StatelessWidget {
  const KeySiteDetailPage({
    super.key,
    required this.gateway,
    required this.siteId,
    this.version,
    this.incidentId,
  });

  final KeySiteGateway gateway;
  final String siteId;
  final int? version;
  final String? incidentId;

  @override
  Widget build(BuildContext context) {
    return KeySiteGate(
      gateway: gateway,
      builder: (scope) => _KeySiteDetailLoader(
        gateway: gateway,
        scope: scope,
        siteId: siteId,
        version: version,
        incidentId: incidentId,
      ),
    );
  }
}

class _KeySiteDetailLoader extends StatefulWidget {
  const _KeySiteDetailLoader({
    required this.gateway,
    required this.scope,
    required this.siteId,
    this.version,
    this.incidentId,
  });

  final KeySiteGateway gateway;
  final String scope;
  final String siteId;
  final int? version;
  final String? incidentId;

  @override
  State<_KeySiteDetailLoader> createState() => _KeySiteDetailLoaderState();
}

class _KeySiteDetailLoaderState extends State<_KeySiteDetailLoader> {
  late Future<KeySiteVersion> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<KeySiteVersion> _load() async {
    final value = await widget.gateway.fetchKeySite(
      widget.siteId,
      version: widget.version,
      incident: widget.incidentId,
    );
    if (mounted) {
      await widget.gateway.recents.viewed(widget.scope, widget.siteId);
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    return CommandScaffold(
      appBar: AppBar(title: const Text('单位资料')),
      body: FutureBuilder<KeySiteVersion>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return KeySiteFailure(
              error: snapshot.error!,
              retry: () => setState(() {
                _data = _load();
              }),
            );
          }
          if (!snapshot.hasData) {
            return const StatePlaceholder.loading(message: '正在加载重点单位资料...');
          }
          final site = snapshot.data!;
          return KeySiteDetailContent(
            site: site,
            onOpenModule: (moduleKey) {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => KeySiteModulePage(
                    gateway: widget.gateway,
                    site: site,
                    module: moduleKey,
                    incidentId: widget.incidentId,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 重点单位详情主体视图（与在线网关解耦，便于独立测试与 Golden 截图回归）。
class KeySiteDetailContent extends StatelessWidget {
  const KeySiteDetailContent({
    super.key,
    required this.site,
    required this.onOpenModule,
  });

  final KeySiteVersion site;
  final ValueChanged<String> onOpenModule;

  String _formatPublishedAt(int millis) {
    if (millis <= 0) return '未知时间';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final district = site.profile['district']?.toString().trim() ?? '';
    final siteType = site.profile['site_type']?.toString().trim() ?? '';

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.pageMargin,
        DsSpacing.md,
        DsSpacing.pageMargin,
        DsSpacing.xxl,
      ),
      children: <Widget>[
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          accentStatus: site.active ? DsStatus.safe : DsStatus.caution,
          padding: DsSpacing.cardAll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                site.name,
                style: typo.headline.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              if (site.address.isNotEmpty) ...<Widget>[
                const SizedBox(height: DsSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.location_on_outlined,
                        size: DsSizes.iconSm,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: DsSpacing.xs),
                    Expanded(
                      child: Text(
                        site.address,
                        style: typo.body.copyWith(color: colors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: DsSpacing.md),
              Wrap(
                spacing: DsSpacing.sm,
                runSpacing: DsSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  StatusPill(
                    status: site.active ? DsStatus.safe : DsStatus.caution,
                    icon: site.active
                        ? Icons.verified_outlined
                        : Icons.pause_circle_outline_rounded,
                    label: '资料 v${site.version}',
                  ),
                  if (district.isNotEmpty)
                    StatusPill(
                      status: DsStatus.neutral,
                      icon: Icons.map_outlined,
                      label: district,
                    ),
                  if (siteType.isNotEmpty)
                    StatusPill(
                      status: DsStatus.neutral,
                      icon: Icons.domain_outlined,
                      label: siteType,
                    ),
                ],
              ),
              const SizedBox(height: DsSpacing.sm),
              Text(
                '更新于 ${_formatPublishedAt(site.publishedAt)}',
                style: typo.captionTabular.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
        if (!site.active) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          const KeySiteStatusBanner(
            status: DsStatus.caution,
            message: '该单位已停用，当前仅供警情历史引用查阅',
          ),
        ],
        if (site.latestVersion > site.version) ...<Widget>[
          const SizedBox(height: DsSpacing.sm),
          KeySiteStatusBanner(
            status: DsStatus.caution,
            message:
                '已有 v${site.latestVersion}，本警情仍引用 v${site.version}。请返回警情关联区人工核对后更新。',
          ),
        ],
        const SizedBox(height: DsSpacing.md),
        Padding(
          padding: const EdgeInsets.only(bottom: DsSpacing.sm),
          child: Text(
            '核对资料模块',
            style: typo.title.copyWith(color: colors.textPrimary),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = DsSpacing.sm;
            final twoColWidth = (constraints.maxWidth - spacing) / 2;
            final useSingleColumn = twoColWidth < 140;
            final itemWidth = useSingleColumn
                ? constraints.maxWidth
                : math.max(140.0, twoColWidth);
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: <Widget>[
                for (final module in keySiteModules.entries)
                  SizedBox(
                    width: itemWidth,
                    child: _ModuleTile(
                      moduleKey: module.key,
                      title: module.value,
                      itemCount: site.content[module.key]?.length ?? 0,
                      onTap: () => onOpenModule(module.key),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.moduleKey,
    required this.title,
    required this.itemCount,
    required this.onTap,
  });

  final String moduleKey;
  final String title;
  final int itemCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 76),
      child: SurfaceCard(
        key: ValueKey<String>('key-site-module-$moduleKey'),
        level: DsSurfaceLevel.outlined,
        padding: const EdgeInsets.all(DsSpacing.md),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: DsRadius.borderSm,
                  ),
                  child: Icon(
                    keySiteModuleIcon(moduleKey),
                    size: DsSizes.iconSm + 2,
                    color: colors.brandText,
                  ),
                ),
                const SizedBox(width: DsSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: typo.body.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: DsSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Text(
                    '$itemCount 项已核对资料',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.captionTabular.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: DsSpacing.xs),
                Icon(
                  Icons.chevron_right_rounded,
                  size: DsSizes.iconSm,
                  color: colors.textTertiary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
