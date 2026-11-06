import 'package:flutter/material.dart';

import '../services/theme_controller.dart';
import '../theme/app_palette.dart';
import '../theme/app_widgets.dart';

/// 仅调试可见的组件画廊（Design System Gallery）
///
/// 集中展示所有核心 Token、原子组件与交互卡片在当前调色板下的表现，
/// 免去反复深层点击调试，一键核验视觉质感、圆角一致性与对比度。
class ComponentGalleryPage extends StatefulWidget {
  const ComponentGalleryPage({super.key});

  @override
  State<ComponentGalleryPage> createState() => _ComponentGalleryPageState();
}

class _ComponentGalleryPageState extends State<ComponentGalleryPage> {
  int _activeVolumeL = 9;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('UI 规范与组件画廊'),
        actions: [
          TextButton.icon(
            onPressed: () {
              final isDay = ThemeController.instance.currentId == 'daylight';
              final next = isDay ? AppPalette.warmSand : AppPalette.daylight;
              ThemeController.instance.select(next);
            },
            icon: Icon(
              ThemeController.instance.currentId == 'daylight'
                  ? Icons.wb_sunny_outlined
                  : Icons.nights_stay_outlined,
              size: 18,
            ),
            label: Text(ThemeController.instance.current.label),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        children: [
          const SectionTitle(text: '1. 状态胶囊徽标 (StatusBadge) · 微圆点精致版'),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: const [
              StatusBadge(status: 'normal'),
              StatusBadge(status: 'warn'),
              StatusBadge(status: 'alarm'),
              StatusBadge(status: 'timeout'),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          const SectionTitle(text: '2. 统一卡片 (AppCard) · 分层柔光阴影与饱满圆角'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '标准人员信息卡片',
                      style: AppTextStyles.title.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const StatusBadge(status: 'normal'),
                  ],
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  '展示圆角 (16dp) 与柔和阴影层次，边框为半透明微边框。',
                  style: AppTextStyles.bodyMd.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.s3),
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '剩余时间',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s1),
                        const CountdownText(ms: 1845000, size: 28),
                      ],
                    ),
                    const Spacer(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '当前压力',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s1),
                        Text(
                          '28.5 MPa',
                          style: AppTextStyles.numberMd.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          const SectionTitle(text: '3. 快捷选择器与标签'),
          Row(
            children: [
              ChoiceChip(
                label: const Text('6.8 升气瓶'),
                selected: _activeVolumeL == 6,
                showCheckmark: false,
                onSelected: (_) => setState(() => _activeVolumeL = 6),
                selectedColor: AppColors.voice,
                backgroundColor: AppColors.surface,
                side: BorderSide(
                  color: _activeVolumeL == 6
                      ? AppColors.voice
                      : AppColors.border,
                ),
                labelStyle: AppTextStyles.label.copyWith(
                  color: _activeVolumeL == 6
                      ? AppColors.onPrimary
                      : AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              ChoiceChip(
                label: const Text('9.0 升气瓶'),
                selected: _activeVolumeL == 9,
                showCheckmark: false,
                onSelected: (_) => setState(() => _activeVolumeL = 9),
                selectedColor: AppColors.voice,
                backgroundColor: AppColors.surface,
                side: BorderSide(
                  color: _activeVolumeL == 9
                      ? AppColors.voice
                      : AppColors.border,
                ),
                labelStyle: AppTextStyles.label.copyWith(
                  color: _activeVolumeL == 9
                      ? AppColors.onPrimary
                      : AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          const SectionTitle(text: '4. 系统按钮规范 (Button Styles)'),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('主行动按钮 (Filled)'),
              ),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('次级按钮 (Outlined)'),
              ),
              TextButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.info_outline_rounded, size: 18),
                label: const Text('文字按钮 (Text)'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          const SectionTitle(text: '5. 通告与告警条 (AppNotice / AppBanner)'),
          const AppNotice(
            text: '警情现场网络连接正常，正在接收后端毫秒级同步推送。',
            kind: AppNoticeKind.info,
          ),
          const SizedBox(height: AppSpacing.s2),
          const AppNotice(
            text: '注意：当前气瓶消耗率较高，请提醒前方队员注意排查漏气。',
            kind: AppNoticeKind.warning,
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          const SectionTitle(text: '6. 字阶梯度一览 (Typography)'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DisplayXL 56 等宽: 32:45', style: AppTextStyles.displayXl),
                const Divider(),
                Text('DisplayLg 44 等宽: 32:45', style: AppTextStyles.displayLg),
                const Divider(),
                Text('NumberMd 28 等宽: 29.5 MPa', style: AppTextStyles.numberMd),
                const Divider(),
                Text('H1 24 大标题', style: AppTextStyles.h1),
                const Divider(),
                Text('H2 20 区块标题', style: AppTextStyles.h2),
                const Divider(),
                Text('Title 17 人名/主信息', style: AppTextStyles.title),
                const Divider(),
                Text('BodyMd 15 常规正文阅读行', style: AppTextStyles.bodyMd),
                const Divider(),
                Text('Caption 12 辅助时间说明', style: AppTextStyles.caption),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
        ],
      ),
    );
  }
}
