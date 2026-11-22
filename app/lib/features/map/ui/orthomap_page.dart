import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'orthomap_tile_viewer.dart';

export 'orthomap_tile_viewer.dart'
    show OrthomapGateway, OrthomapTileFailureCell, OrthomapTileViewerPage;

/// 单位正射影像列表页（Design System v3.0）。
class OrthomapPage extends StatefulWidget {
  final OrthomapGateway gateway;

  const OrthomapPage({super.key, required this.gateway});

  @override
  State<OrthomapPage> createState() => _OrthomapPageState();
}

class _OrthomapPageState extends State<OrthomapPage> {
  late Future<List<Map<String, dynamic>>> _maps;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _maps = !widget.gateway.isAuthenticated()
        ? Future.error('请先完成单位认证后查看地图')
        : widget.gateway.fetchMaps();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final cautionPair = colors.statusColors(DsStatus.caution);

    return CommandScaffold(
      appBar: AppBar(title: const Text('现场地图')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _maps,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return StatePlaceholder.error(
              title: '地图暂时无法加载',
              reason: '地图暂时无法加载，请检查网络或重新认证',
              retryLabel: '重试',
              onRetry: () => setState(_load),
            );
          }
          if (!snapshot.hasData) {
            return const StatePlaceholder.loading(message: '正在加载正射影像列表…');
          }
          final maps = snapshot.data!;
          if (maps.isEmpty) {
            return const StatePlaceholder.empty(
              icon: DsIcons.toolSceneMap,
              message: '本单位暂无地图，请联系管理员导入影像',
            );
          }
          final hasDemo = maps.any((m) => m['demo'] == true);
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.pageMargin,
              DsSpacing.md,
              DsSpacing.pageMargin,
              DsSpacing.xxl,
            ),
            itemCount: maps.length + (hasDemo ? 1 : 0),
            itemBuilder: (context, index) {
              if (hasDemo && index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: DsSpacing.md),
                  child: SurfaceCard(
                    accentStatus: DsStatus.caution,
                    padding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.md,
                      vertical: DsSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          DsIcons.warning,
                          size: DsSizes.iconMd,
                          color: cautionPair.text,
                        ),
                        const SizedBox(width: DsSpacing.sm),
                        Expanded(
                          child: Text(
                            '演示影像 · 非真实现场 · 不可用于定位',
                            style: ds.typography.caption.copyWith(
                              color: cautionPair.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final map = maps[hasDemo ? index - 1 : index];
              final isDemo = map['demo'] == true;
              final name = map['name']?.toString() ?? '未命名影像';
              return Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                child: SurfaceCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.md,
                    vertical: DsSpacing.sm,
                  ),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => OrthomapTileViewerPage(
                        gateway: widget.gateway,
                        map: map,
                      ),
                    ),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: DsSizes.touchTarget,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: colors.surfaceMuted,
                            borderRadius: DsRadius.borderSm,
                          ),
                          child: Icon(
                            DsIcons.toolSceneMap,
                            size: DsSizes.iconMd,
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: DsSpacing.md),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Wrap(
                                spacing: DsSpacing.xs,
                                runSpacing: DsSpacing.xs,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    name,
                                    style: ds.typography.body.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  if (isDemo)
                                    const StatusPill(
                                      status: DsStatus.neutral,
                                      label: '演示',
                                      icon: DsIcons.eye,
                                    ),
                                ],
                              ),
                              const SizedBox(height: DsSpacing.xs),
                              Text(
                                isDemo
                                    ? '演示影像 · 非真实现场，不可用于定位'
                                    : '正射影像 · 图片坐标，支持缩放和拖动',
                                style: ds.typography.caption.copyWith(
                                  color: colors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: DsSpacing.sm),
                        Icon(
                          DsIcons.chevronRight,
                          size: DsSizes.iconMd,
                          color: colors.textTertiary,
                        ),
                      ],
                    ),
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
