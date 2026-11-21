import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/watermark_settings.dart';

/// 水印相机效果实时预览卡片。
///
/// 预览区使用深蓝实底（`#24569A`）承载白色文字，保证对比度 ≥ 4.5:1；
/// 抬头留空时自动回落至当前登录单位名称，均为空时显示明确占位。
class WatermarkPreviewCard extends StatelessWidget {
  const WatermarkPreviewCard({
    super.key,
    required this.settings,
    required this.fallbackUnitName,
  });

  final WatermarkSettings settings;
  final String fallbackUnitName;

  /// 深蓝实底（与白字对比度 > 7.2:1）。
  static const Color watermarkBlue = Color(0xFF24569A);

  String get _effectiveUnitTitle {
    final custom = settings.unitTitle.trim();
    if (custom.isNotEmpty) return custom;
    final unit = fallbackUnitName.trim();
    return unit.isEmpty ? '未填写单位抬头' : unit;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final preview = settings.copyWith(unitTitle: _effectiveUnitTitle);

    return SurfaceCard(
      padding: const EdgeInsets.all(DsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '效果预览',
            style: ds.typography.title.copyWith(color: ds.colors.textPrimary),
          ),
          const SizedBox(height: DsSpacing.md),
          Container(
            padding: const EdgeInsets.all(DsSpacing.md),
            decoration: BoxDecoration(
              borderRadius: DsRadius.borderSm,
              gradient: const LinearGradient(
                colors: <Color>[Color(0xFF8FA6B8), Color(0xFF43535F)],
              ),
            ),
            child: _PreviewBody(settings: preview),
          ),
        ],
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.settings});

  final WatermarkSettings settings;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      if (settings.showTime) ('拍摄\r\n时间', '2026.10.18 星期日 08:39'),
      if (settings.showWeather) ('天气', '晴 21℃ 东南风2级 湿度87%'),
      if (settings.showLocation) ('地点', '示例市 · 某某有限公司'),
      if (settings.showCoordinates) ('经度', '东经 118°22′'),
      if (settings.showCoordinates) ('纬度', '北纬 29°0′'),
      if (settings.actorName.isNotEmpty) ('拍摄人', settings.actorName),
    ];

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0x9EFFFFFF),
        borderRadius: BorderRadius.circular(5),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            color: WatermarkPreviewCard.watermarkBlue,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: <Widget>[
                if (settings.showLogo)
                  Container(
                    width: 18,
                    height: 18,
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Image.asset(
                      'assets/branding/fire_rescue_badge.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      semanticLabel: '中国消防救援队徽',
                    ),
                  ),
                Expanded(
                  child: Text(
                    settings.unitTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 48,
                    child: Text(
                      row.$1,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 12,
                    color: const Color(0x22000000),
                    margin: const EdgeInsets.only(right: 5),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF1A1A1A),
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (settings.department.isNotEmpty)
            Container(
              color: WatermarkPreviewCard.watermarkBlue,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    const TextSpan(
                      text: '拍摄单位：',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: settings.department,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
