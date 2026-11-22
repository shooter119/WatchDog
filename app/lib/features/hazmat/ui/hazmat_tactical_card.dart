import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design_system/design_system.dart';
import '../data/models/hazmat.dart';
import 'hazmat_widgets.dart';

/// 高对比度「电台战术复诵卡」组件（Design System v3.0）。
///
/// 信息优先级：身份标识 / 遇水红线 -> 绝对禁忌 -> 灭火防护对策 -> 隔离疏散 -> 折叠详注。
/// 遵循危化品现场规范：提供剪贴板一键复制，**严禁提供离线语音朗读按钮**。
class HazmatTacticalCard extends StatelessWidget {
  const HazmatTacticalCard({
    super.key,
    required this.item,
    this.aiDisclaimer,
  });

  final HazmatItem item;
  final String? aiDisclaimer;

  bool get _hasSecondaryDetails =>
      item.leakHandling.isNotEmpty ||
      item.firstAid.isNotEmpty ||
      item.appearance.isNotEmpty ||
      item.casNumber.isNotEmpty ||
      item.notes.isNotEmpty;

  Future<void> _copyToClipboard(BuildContext context) async {
    final text = item.formatShareText(aiDisclaimer: aiDisclaimer);
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已复制电台处置要点，可粘贴至救援调度群'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final alarmPair = colors.statusColors(DsStatus.alarm);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 1. 物质身份头卡 + 复制按钮
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          padding: DsSpacing.cardAll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: DsSpacing.sm,
                runSpacing: DsSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  HazmatUnBadge(unNumber: item.unNumber),
                  if (item.dangerCategory.isNotEmpty)
                    _CategoryBadge(
                      label: item.dangerCategory,
                      signColor: item.dangerSignColor,
                    ),
                ],
              ),
              const SizedBox(height: DsSpacing.md),
              Text(
                item.nameCn,
                style: typo.headline.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              if (item.nameEn.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  item.nameEn,
                  style: typo.caption.copyWith(color: colors.textSecondary),
                ),
              ],
              if (item.aliases.isNotEmpty) ...<Widget>[
                const SizedBox(height: DsSpacing.xs),
                Text(
                  '俗名/别名：${item.aliases.join('、')}',
                  style: typo.caption.copyWith(color: colors.textSecondary),
                ),
              ],
              const SizedBox(height: DsSpacing.md),
              CommandButton(
                key: const ValueKey<String>('hazmat-copy-btn'),
                label: '复制处置要点',
                icon: DsIcons.copyAll,
                variant: CommandButtonVariant.secondary,
                size: CommandButtonSize.standard,
                expanded: true,
                onPressed: () => _copyToClipboard(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.cardGap),

        // 2. 双通道遇水警示横幅
        _WaterReactivityBanner(item: item),
        const SizedBox(height: DsSpacing.cardGap),

        // 3. 致命禁忌（绝对保命红线）
        if (item.forbiddenAgents.isNotEmpty) ...<Widget>[
          SurfaceCard(
            level: DsSurfaceLevel.outlined,
            accentStatus: DsStatus.alarm,
            backgroundColor: alarmPair.pillBg,
            borderColor: alarmPair.fill,
            padding: DsSpacing.cardAll,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      DsIcons.forbid,
                      color: alarmPair.text,
                      size: DsSizes.iconMd,
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Expanded(
                      child: Text(
                        '绝对禁忌 · 严禁动作',
                        style: typo.title.copyWith(
                          color: alarmPair.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.sm),
                Text(
                  item.forbiddenAgents,
                  style: typo.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.cardGap),
        ],

        // 4. 核心灭火与战术对策
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          padding: DsSpacing.cardAll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '核心灭火与战术对策',
                style: typo.title.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: DsSpacing.md),
              HazmatInfoBlock(
                icon: DsIcons.categoryFireLine,
                label: '推荐灭火/抑蒸介质',
                value: item.extinguishingAgents,
                highlightColor: colors.safeText,
              ),
              if (item.firefightingTips.isNotEmpty) ...<Widget>[
                Divider(height: DsSpacing.xl, color: colors.border),
                HazmatInfoBlock(
                  icon: DsIcons.shield,
                  label: '战术处置要点',
                  value: item.firefightingTips,
                ),
              ],
              if (item.protectiveLevel.isNotEmpty) ...<Widget>[
                Divider(height: DsSpacing.xl, color: colors.border),
                HazmatInfoBlock(
                  icon: DsIcons.shieldCheck,
                  label: '个体防护等级',
                  value: item.protectiveLevel,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.cardGap),

        // 5. 隔离疏散与关键参数
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          padding: DsSpacing.cardAll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '隔离疏散与危情评估',
                style: typo.title.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: DsSpacing.md),
              if (item.isolationDistance.isNotEmpty)
                HazmatInfoBlock(
                  icon: DsIcons.distance,
                  label: '初期隔离与下风向疏散',
                  value: item.isolationDistance,
                  highlightColor: colors.cautionText,
                  tabular: true,
                ),
              if (item.dangerSummary.isNotEmpty) ...<Widget>[
                if (item.isolationDistance.isNotEmpty)
                  Divider(height: DsSpacing.xl, color: colors.border),
                HazmatInfoBlock(
                  icon: DsIcons.warning,
                  label: '核心危险性',
                  value: item.dangerSummary,
                ),
              ],
              if (item.vaporDensityHint.isNotEmpty) ...<Widget>[
                Divider(height: DsSpacing.xl, color: colors.border),
                HazmatInfoBlock(
                  icon: DsIcons.wind,
                  label: '蒸气密度与积聚方位',
                  value: item.vaporDensityHint,
                  tabular: true,
                ),
              ],
              if (item.flashPoint.isNotEmpty ||
                  item.explosionLimit.isNotEmpty) ...<Widget>[
                Divider(height: DsSpacing.xl, color: colors.border),
                Wrap(
                  spacing: DsSpacing.sm,
                  runSpacing: DsSpacing.sm,
                  children: <Widget>[
                    if (item.flashPoint.isNotEmpty)
                      _MetricTag(label: '闪点', value: item.flashPoint),
                    if (item.explosionLimit.isNotEmpty)
                      _MetricTag(label: '爆炸极限', value: item.explosionLimit),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.cardGap),

        // 6. 泄漏堵漏、急救与理化详注（折叠面板）
        if (_hasSecondaryDetails) _buildSecondarySection(context),
      ],
    );
  }

  Widget _buildSecondarySection(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey<String>('hazmat-secondary-expansion'),
          tilePadding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.cardPadding,
            vertical: DsSpacing.xs,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            DsSpacing.cardPadding,
            0,
            DsSpacing.cardPadding,
            DsSpacing.cardPadding,
          ),
          title: Text(
            '泄漏堵漏、现场急救与理化详注',
            style: ds.typography.title.copyWith(color: colors.textPrimary),
          ),
          children: <Widget>[
            if (item.leakHandling.isNotEmpty) ...<Widget>[
              HazmatInfoBlock(
                icon: DsIcons.toolWaterSources,
                label: '泄漏围堵与洗消',
                value: item.leakHandling,
              ),
              Divider(height: DsSpacing.xl, color: colors.border),
            ],
            if (item.firstAid.isNotEmpty) ...<Widget>[
              HazmatInfoBlock(
                icon: DsIcons.firstAid,
                label: '现场急救措施',
                value: item.firstAid,
              ),
              Divider(height: DsSpacing.xl, color: colors.border),
            ],
            if (item.appearance.isNotEmpty) ...<Widget>[
              HazmatInfoBlock(
                icon: DsIcons.eye,
                label: '外观与气味识别',
                value: item.appearance,
              ),
              Divider(height: DsSpacing.xl, color: colors.border),
            ],
            if (item.casNumber.isNotEmpty) ...<Widget>[
              HazmatInfoBlock(
                icon: DsIcons.tag,
                label: 'CAS 登记号',
                value: item.casNumber,
                tabular: true,
              ),
              if (item.notes.isNotEmpty)
                Divider(height: DsSpacing.xl, color: colors.border),
            ],
            if (item.notes.isNotEmpty)
              HazmatInfoBlock(
                icon: DsIcons.book,
                label: '战术速记口诀',
                value: item.notes,
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.label, required this.signColor});

  final String label;
  final String signColor;

  @override
  Widget build(BuildContext context) {
    if (signColor == 'blue') {
      final ds = context.ds;
      final colors = ds.colors;
      return Container(
        constraints: const BoxConstraints(minHeight: 26),
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.sm + 2,
          vertical: DsSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colors.brand.withValues(alpha: 0.12),
          borderRadius: DsRadius.borderPill,
          border: Border.all(
            color: colors.brand.withValues(alpha: 0.28),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(
              DsIcons.toolWaterSources,
              size: DsSizes.iconSm,
              color: colors.brandText,
            ),
            const SizedBox(width: DsSpacing.xs),
            Flexible(
              child: Text(
                label,
                style: ds.typography.micro.copyWith(
                  color: colors.brandText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final status = switch (signColor) {
      'red' => DsStatus.alarm,
      'yellow' => DsStatus.caution,
      _ => DsStatus.neutral,
    };
    final icon = switch (signColor) {
      'red' => DsIcons.categoryFire,
      'yellow' => DsIcons.warning,
      _ => DsIcons.toolHazmat,
    };
    return StatusPill(status: status, icon: icon, label: label);
  }
}

class _WaterReactivityBanner extends StatelessWidget {
  const _WaterReactivityBanner({required this.item});

  final HazmatItem item;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (DsStatus status, IconData icon, String text) = item.isWaterForbidden
        ? (
            DsStatus.alarm,
            DsIcons.prohibited,
            '遇水属性：严禁用水（遇水可能剧烈反应、燃爆或释放有毒/易燃气体）',
          )
        : item.isWaterReactive
        ? (
            DsStatus.caution,
            DsIcons.warning,
            '遇水属性：慎用/剧烈反应（遇水热反应或放气，严格按战术规程控水）',
          )
        : (
            DsStatus.safe,
            DsIcons.toolWaterSources,
            '遇水属性：可用水冷却或稀释控制（注意防流淌污染）',
          );

    final pair = ds.colors.statusColors(status);
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      accentStatus: status,
      backgroundColor: pair.pillBg,
      borderColor: pair.fill.withValues(alpha: 0.55),
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, color: pair.text, size: DsSizes.iconMd),
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: ds.typography.body.copyWith(
                color: pair.text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTag extends StatelessWidget {
  const _MetricTag({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.sm + 2,
        vertical: DsSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: DsRadius.borderSm,
        border: Border.all(color: colors.border),
      ),
      child: Text(
        '$label：$value',
        style: ds.typography.captionTabular.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
