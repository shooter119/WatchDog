import 'package:flutter/material.dart';

import '../../../../design_system/design_system.dart';

/// 现场工具宫格单项规格定义。
@immutable
class FieldToolSpec {
  const FieldToolSpec({
    required this.keyId,
    required this.label,
    required this.subtitle,
    required this.icon,
    this.badge,
    this.badgeStatus = DsStatus.alarm,
    this.enabled = true,
    this.locked = false,
    this.onTap,
  });

  final String keyId;
  final String label;
  final String subtitle;
  final IconData icon;
  final String? badge;
  final DsStatus badgeStatus;
  final bool enabled;
  final bool locked;
  final VoidCallback? onTap;
}

/// 指挥台现场工具宫格区块（基于 M0 [ToolGrid]，默认 4 列自适应防溢出）。
///
/// 无论当前是否选中警情均可随时展示全部 9 项现场工具（含周边水源入口），
/// 游客模式下按「六锁三开」规则对涉敏/单位业务入口显示锁定标识；
/// 同时保留全部既有语义 `Key('tool-<keyId>')` 与 `Key('command-tools-grid')`。
class FieldToolsGridSection extends StatelessWidget {
  const FieldToolsGridSection({
    super.key = const Key('command-tools-grid'),
    required this.tools,
    this.title = '现场工具',
    this.columns = 4,
  }) : assert(columns > 0, 'columns 必须大于 0');

  /// 构建标准 9 项现场工具默认清单，由调用方注入各路由回调（零跨 Feature 耦合）。
  static List<FieldToolSpec> buildDefaultTools({
    bool guestMode = false,
    VoidCallback? onKeySites,
    VoidCallback? onHazmat,
    VoidCallback? onCamera,
    VoidCallback? onLocationShare,
    VoidCallback? onVideoResources,
    VoidCallback? onRouteTraffic,
    VoidCallback? onTacticalBrief,
    VoidCallback? onSceneMap,
    VoidCallback? onWaterSources,
  }) {
    const String guestLockedSubtitle = '需完成单位认证后使用';
    return <FieldToolSpec>[
      FieldToolSpec(
        keyId: '重点单位',
        label: '重点单位',
        subtitle: guestMode ? guestLockedSubtitle : '预案与作战资料',
        icon: DsIcons.toolKeySites,
        locked: guestMode,
        onTap: onKeySites,
      ),
      FieldToolSpec(
        keyId: '危化速查',
        label: '危化速查',
        subtitle: 'UN 编号离线速查',
        icon: DsIcons.toolHazmat,
        onTap: onHazmat,
      ),
      FieldToolSpec(
        keyId: '水印相机',
        label: '水印相机',
        subtitle: '现场照片视频取证',
        icon: DsIcons.toolWatermarkCamera,
        onTap: onCamera,
      ),
      FieldToolSpec(
        keyId: '定位分享',
        label: '定位分享',
        subtitle: '坐标与高德导航',
        icon: DsIcons.toolLocationShare,
        onTap: onLocationShare,
      ),
      FieldToolSpec(
        keyId: '视频资源',
        label: '视频资源',
        subtitle: guestMode ? guestLockedSubtitle : '授权监控与实况',
        icon: DsIcons.toolVideoResources,
        locked: guestMode,
        onTap: onVideoResources,
      ),
      FieldToolSpec(
        keyId: '路况查询',
        label: '路况查询',
        subtitle: guestMode ? guestLockedSubtitle : '路线耗时与天气',
        icon: DsIcons.toolRouteTraffic,
        locked: guestMode,
        onTap: onRouteTraffic,
      ),
      FieldToolSpec(
        keyId: '警情上报',
        label: '警情上报',
        subtitle: guestMode ? guestLockedSubtitle : '一键生成公文简报',
        icon: DsIcons.toolTacticalBrief,
        locked: guestMode,
        onTap: onTacticalBrief,
      ),
      FieldToolSpec(
        keyId: '现场地图',
        label: '现场地图',
        subtitle: guestMode ? guestLockedSubtitle : '实时定位与卫星图',
        icon: DsIcons.toolSceneMap,
        locked: guestMode,
        onTap: onSceneMap,
      ),
      FieldToolSpec(
        keyId: '周边水源',
        label: '周边水源',
        subtitle: guestMode ? guestLockedSubtitle : '自建消火栓与水源',
        icon: DsIcons.toolWaterSources,
        locked: guestMode,
        onTap: onWaterSources,
      ),
    ];
  }

  final List<FieldToolSpec> tools;
  final String title;
  final int columns;

  @override
  Widget build(BuildContext context) {
    if (tools.isEmpty) return const SizedBox.shrink();
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    final rows = <List<FieldToolSpec?>>[];
    for (var i = 0; i < tools.length; i += columns) {
      final chunk = <FieldToolSpec?>[];
      for (var j = 0; j < columns; j++) {
        final idx = i + j;
        chunk.add(idx < tools.length ? tools[idx] : null);
      }
      rows.add(chunk);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          title,
          style: typo.title.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: DsSpacing.sm),
        for (var r = 0; r < rows.length; r++) ...<Widget>[
          if (r > 0) const SizedBox(height: DsSpacing.sm),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var c = 0; c < columns; c++) ...<Widget>[
                  if (c > 0) const SizedBox(width: DsSpacing.sm),
                  Expanded(
                    child: rows[r][c] != null
                        ? Tooltip(
                            message: rows[r][c]!.subtitle,
                            child: KeyedSubtree(
                              key: Key('tool-${rows[r][c]!.keyId}'),
                              child: ToolGrid(
                                columns: 1,
                                spacing: 0,
                                runSpacing: 0,
                                items: <DsToolItem>[
                                  DsToolItem(
                                    id: rows[r][c]!.keyId,
                                    icon: rows[r][c]!.icon,
                                    label: rows[r][c]!.label,
                                    badge: rows[r][c]!.badge,
                                    badgeStatus: rows[r][c]!.badgeStatus,
                                    enabled: rows[r][c]!.enabled,
                                    locked: rows[r][c]!.locked,
                                    onTap: rows[r][c]!.onTap,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
