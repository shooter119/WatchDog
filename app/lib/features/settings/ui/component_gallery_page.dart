import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'settings_widgets.dart';

/// 仅调试可见的 Design System v3.0 组件画廊。
///
/// 正式包（`!kDebugMode`）编译时通过 `kDebugMode` 守卫剔除预览引用。
class ComponentGalleryPage extends StatefulWidget {
  const ComponentGalleryPage({super.key});

  @override
  State<ComponentGalleryPage> createState() => _ComponentGalleryPageState();
}

class _ComponentGalleryPageState extends State<ComponentGalleryPage> {
  Brightness? _overrideBrightness;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) {
      return const CommandScaffold(
        body: StatePlaceholder.empty(
          icon: DsIcons.lock,
          message: '组件画廊仅在调试模式可用',
        ),
      );
    }

    final brightness =
        _overrideBrightness ?? Theme.of(context).brightness;
    final nextBrightness = brightness == Brightness.light
        ? Brightness.dark
        : Brightness.light;

    return Theme(
      data: buildCommandTheme(brightness),
      child: Builder(
        builder: (BuildContext themedCtx) {
          final ds = themedCtx.ds;
          final colors = ds.colors;
          return CommandScaffold(
            appBar: AppBar(
              title: const Text('UI 规范与组件画廊'),
              actions: <Widget>[
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _overrideBrightness = nextBrightness),
                  icon: Icon(
                    brightness == Brightness.light
                        ? DsIcons.sun
                        : DsIcons.moon,
                    size: 18,
                  ),
                  label: Text(brightness == Brightness.light ? '昼白' : '暗曜'),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.all(DsSpacing.pageMargin),
              children: <Widget>[
                SurfaceCard(
                  onTap: () => Navigator.of(themedCtx).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const DsPreviewPage(),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: colors.brand.withValues(alpha: 0.12),
                          borderRadius: DsRadius.borderMd,
                        ),
                        child: Icon(
                          DsIcons.appearance,
                          color: colors.brandText,
                        ),
                      ),
                      const SizedBox(width: DsSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Design System v3.0 预览',
                              style: ds.typography.title.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '组件总览 · 指挥台与安全管控原型（昼白 / 暗曜 · 130% 字号）',
                              style: ds.typography.caption.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        DsIcons.chevronRight,
                        color: colors.textTertiary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.xl),
                const SettingsSectionTitle(text: '1. 状态语义胶囊 (StatusPill)'),
                const Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.sm,
                  children: <Widget>[
                    StatusPill(status: DsStatus.safe),
                    StatusPill(status: DsStatus.caution),
                    StatusPill(status: DsStatus.alarm),
                    StatusPill(status: DsStatus.timeout),
                    StatusPill(status: DsStatus.neutral),
                  ],
                ),
                const SizedBox(height: DsSpacing.xl),
                const SettingsSectionTitle(text: '2. 表面卡片与关键读数 (SurfaceCard)'),
                SurfaceCard(
                  accentStatus: DsStatus.safe,
                  child: Row(
                    children: const <Widget>[
                      Expanded(
                        child: MetricReadout(
                          label: '剩余时间',
                          value: '30:45',
                          status: DsStatus.safe,
                          large: true,
                        ),
                      ),
                      Expanded(
                        child: MetricReadout(
                          label: '当前压力',
                          value: '28.5',
                          unit: 'MPa',
                          status: DsStatus.neutral,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.xl),
                const SettingsSectionTitle(text: '3. 指挥操作按钮 (CommandButton)'),
                Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.sm,
                  children: <Widget>[
                    CommandButton(
                      label: '主操作',
                      icon: DsIcons.check,
                      onPressed: () {},
                    ),
                    CommandButton(
                      label: '次级操作',
                      variant: CommandButtonVariant.secondary,
                      icon: DsIcons.refresh,
                      onPressed: () {},
                    ),
                    CommandButton(
                      label: '幽灵操作',
                      variant: CommandButtonVariant.ghost,
                      onPressed: () {},
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.xl),
                const SettingsSectionTitle(text: '4. 连接状态胶囊 (ConnectionPill)'),
                const Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.sm,
                  children: <Widget>[
                    ConnectionPill(state: DsConnectionState.online),
                    ConnectionPill(state: DsConnectionState.reconnecting),
                    ConnectionPill(
                      state: DsConnectionState.offline,
                      pendingCount: 3,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
