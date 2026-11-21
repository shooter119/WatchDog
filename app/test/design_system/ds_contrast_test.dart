import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _tintedPillBg(Color fill, Color bg) =>
    Color.alphaBlend(fill.withValues(alpha: 0.12), bg);

void _expectContrast(
  String label,
  Color fg,
  Color bg,
  double minRatio,
) {
  final ratio = _contrastRatio(fg, bg);
  expect(
    ratio,
    greaterThanOrEqualTo(minRatio),
    reason: '$label 对比度 ${ratio.toStringAsFixed(2)}:1 < $minRatio:1',
  );
}

void main() {
  final palettes = <(String, DsColors)>[
    ('昼白 Daylight', DsColors.daylight),
    ('暗曜 Night', DsColors.night),
  ];

  group('DsColors 亮度与工厂映射', () {
    test('daylight 与 night 对应正确的 Brightness 及 DsColors.of', () {
      expect(DsColors.daylight.brightness, Brightness.light);
      expect(DsColors.night.brightness, Brightness.dark);
      expect(DsColors.of(Brightness.light), equals(DsColors.daylight));
      expect(DsColors.of(Brightness.dark), equals(DsColors.night));
      expect(DsColors.daylight == DsColors.night, isFalse);
    });

    test('DsColors.lerp 边界与中间态保持有效', () {
      expect(
        DsColors.lerp(DsColors.daylight, DsColors.night, 0.0),
        equals(DsColors.daylight),
      );
      expect(
        DsColors.lerp(DsColors.daylight, DsColors.night, 1.0),
        equals(DsColors.night),
      );
      final mid = DsColors.lerp(DsColors.daylight, DsColors.night, 0.5);
      expect(mid.canvas, isNot(equals(DsColors.daylight.canvas)));
      expect(mid.canvas, isNot(equals(DsColors.night.canvas)));
    });
  });

  group('WCAG 2.1 文本与表面对比度 (≥ 4.5:1)', () {
    for (final (name, c) in palettes) {
      test('$name 三级文字在 canvas / surface / surfaceMuted 上达标', () {
        final surfaces = <(String, Color)>[
          ('canvas', c.canvas),
          ('surface', c.surface),
          ('surfaceMuted', c.surfaceMuted),
        ];
        final texts = <(String, Color)>[
          ('textPrimary', c.textPrimary),
          ('textSecondary', c.textSecondary),
          ('textTertiary', c.textTertiary),
        ];
        for (final (sName, sColor) in surfaces) {
          for (final (tName, tColor) in texts) {
            _expectContrast('$name $tName / $sName', tColor, sColor, 4.5);
          }
        }
      });
    }
  });

  group('WCAG 2.1 状态文字与 12% 淡底胶囊对比度 (≥ 4.5:1)', () {
    for (final (name, c) in palettes) {
      test('$name 各状态文字在三层表面及 12% 淡底胶囊上均达标', () {
        final activeStatuses = <(String, Color, Color)>[
          ('safe', c.safeFill, c.safeText),
          ('caution', c.cautionFill, c.cautionText),
          ('alarm', c.alarmFill, c.alarmText),
          ('timeout', c.timeoutFill, c.timeoutText),
        ];
        for (final (sName, fill, text) in activeStatuses) {
          _expectContrast('$name $sName text / canvas', text, c.canvas, 4.5);
          _expectContrast('$name $sName text / surface', text, c.surface, 4.5);
          _expectContrast(
            '$name $sName text / surfaceMuted',
            text,
            c.surfaceMuted,
            4.5,
          );
          _expectContrast(
            '$name $sName text / 12% pill @canvas',
            text,
            _tintedPillBg(fill, c.canvas),
            4.5,
          );
          _expectContrast(
            '$name $sName text / 12% pill @surface',
            text,
            _tintedPillBg(fill, c.surface),
            4.5,
          );
          _expectContrast(
            '$name $sName text / 12% pill @surfaceMuted',
            text,
            _tintedPillBg(fill, c.surfaceMuted),
            4.5,
          );
        }

        _expectContrast(
          '$name neutral text / neutralPillBg',
          c.neutralText,
          c.neutralPillBg,
          4.5,
        );
      });
    }
  });

  group('WCAG 2.1 品牌与实心填充前景色对比度', () {
    for (final (name, c) in palettes) {
      test('$name 品牌文字、白字/深字填充与图形对比度达标', () {
        _expectContrast('$name brandText / canvas', c.brandText, c.canvas, 4.5);
        _expectContrast(
          '$name brandText / surface',
          c.brandText,
          c.surface,
          4.5,
        );
        _expectContrast(
          '$name brandText / surfaceMuted',
          c.brandText,
          c.surfaceMuted,
          4.5,
        );

        expect(c.onBrand, equals(const Color(0xFFFFFFFF)));
        _expectContrast('$name onBrand / brand', c.onBrand, c.brand, 4.5);
        _expectContrast('$name brand / canvas (UI 图形)', c.brand, c.canvas, 3.0);
        _expectContrast(
          '$name brand / surface (UI 图形)',
          c.brand,
          c.surface,
          3.0,
        );

        expect(c.onAlarm, equals(const Color(0xFFFFFFFF)));
        expect(c.onTimeout, equals(const Color(0xFFFFFFFF)));
        _expectContrast('$name onSafe / safeFill', c.onSafe, c.safeFill, 4.5);
        _expectContrast(
          '$name onCaution / cautionFill',
          c.onCaution,
          c.cautionFill,
          4.5,
        );
        _expectContrast(
          '$name onAlarm / alarmFill',
          c.onAlarm,
          c.alarmFill,
          4.5,
        );
        _expectContrast(
          '$name onTimeout / timeoutFill',
          c.onTimeout,
          c.timeoutFill,
          4.5,
        );
        _expectContrast(
          '$name neutralOnFill / neutralFill',
          c.neutralOnFill,
          c.neutralFill,
          4.5,
        );
      });
    }
  });

  group('WCAG AAA 关键数字读数可读性 (≥ 7.0:1)', () {
    for (final (name, c) in palettes) {
      test('$name textPrimary 与 metric* 在 canvas / surface 上达到 AAA', () {
        final metrics = <(String, Color)>[
          ('textPrimary', c.textPrimary),
          ('metricSafe', c.metricSafe),
          ('metricCaution', c.metricCaution),
          ('metricAlarm', c.metricAlarm),
          ('metricTimeout', c.metricTimeout),
        ];
        for (final (mName, mColor) in metrics) {
          _expectContrast('$name $mName / canvas', mColor, c.canvas, 7.0);
          _expectContrast('$name $mName / surface', mColor, c.surface, 7.0);
        }
      });
    }
  });

  group('StatusColorPair 一致性与告警/超时色阶区分度', () {
    for (final (name, c) in palettes) {
      test('$name statusColors 映射完整且 alarm 与 timeout 区分明显', () {
        for (final status in DsStatus.values) {
          final pair = c.statusColors(status);
          _expectContrast('$name $status onFill / fill', pair.onFill, pair.fill, 4.5);
          _expectContrast(
            '$name $status text / pill @canvas',
            pair.text,
            Color.alphaBlend(pair.pillBg, c.canvas),
            4.5,
          );
          _expectContrast(
            '$name $status text / pill @surface',
            pair.text,
            Color.alphaBlend(pair.pillBg, c.surface),
            4.5,
          );
          _expectContrast(
            '$name $status text / pill @surfaceMuted',
            pair.text,
            Color.alphaBlend(pair.pillBg, c.surfaceMuted),
            4.5,
          );
          _expectContrast(
            '$name $status metric / canvas',
            pair.metricText,
            c.canvas,
            7.0,
          );
          _expectContrast(
            '$name $status metric / surface',
            pair.metricText,
            c.surface,
            7.0,
          );
        }

        expect(
          c.statusColors(DsStatus.safe),
          equals(
            StatusColorPair(
              fill: c.safeFill,
              onFill: c.onSafe,
              text: c.safeText,
              metricText: c.metricSafe,
              pillBg: c.safeFill.withValues(alpha: 0.12),
            ),
          ),
        );
        expect(
          c.statusColors(DsStatus.caution),
          equals(
            StatusColorPair(
              fill: c.cautionFill,
              onFill: c.onCaution,
              text: c.cautionText,
              metricText: c.metricCaution,
              pillBg: c.cautionFill.withValues(alpha: 0.12),
            ),
          ),
        );
        expect(
          c.statusColors(DsStatus.alarm),
          equals(
            StatusColorPair(
              fill: c.alarmFill,
              onFill: c.onAlarm,
              text: c.alarmText,
              metricText: c.metricAlarm,
              pillBg: c.alarmFill.withValues(alpha: 0.12),
            ),
          ),
        );
        expect(
          c.statusColors(DsStatus.timeout),
          equals(
            StatusColorPair(
              fill: c.timeoutFill,
              onFill: c.onTimeout,
              text: c.timeoutText,
              metricText: c.metricTimeout,
              pillBg: c.timeoutFill.withValues(alpha: 0.12),
            ),
          ),
        );
        expect(
          c.statusColors(DsStatus.neutral),
          equals(
            StatusColorPair(
              fill: c.neutralFill,
              onFill: c.neutralOnFill,
              text: c.neutralText,
              metricText: c.textPrimary,
              pillBg: c.neutralPillBg,
            ),
          ),
        );

        _expectContrast(
          '$name alarmFill vs timeoutFill 视觉分离',
          c.alarmFill,
          c.timeoutFill,
          2.0,
        );
      });
    }
  });

  group('警情三大类语义色对比度（灭火/抢险/救助：文本 ≥ 4.5，图形 ≥ 3.0）', () {
    for (final (name, c) in palettes) {
      test('$name fire/rescue/aid 文本、图标与徽章前景对比度达标', () {
        for (final category in DsIncidentCategory.values) {
          final (
            String label,
            Color fill,
            Color onFill,
            Color iconAndText,
            Color pillBg,
          ) = switch (category) {
            DsIncidentCategory.fire => (
              'fire(灭火)',
              c.statusColors(DsStatus.alarm).fill,
              c.statusColors(DsStatus.alarm).onFill,
              c.statusColors(DsStatus.alarm).text,
              c.statusColors(DsStatus.alarm).pillBg,
            ),
            DsIncidentCategory.rescue => (
              'rescue(抢险)',
              c.statusColors(DsStatus.caution).fill,
              c.statusColors(DsStatus.caution).onFill,
              c.statusColors(DsStatus.caution).text,
              c.statusColors(DsStatus.caution).pillBg,
            ),
            DsIncidentCategory.aid => (
              'aid(救助)',
              c.brand,
              c.onBrand,
              c.brandText,
              c.brand.withValues(alpha: 0.12),
            ),
          };

          final surfacePillBg = Color.alphaBlend(pillBg, c.surface);
          final canvasPillBg = Color.alphaBlend(pillBg, c.canvas);

          // 图形/图标通道 ≥ 3.0:1（对齐 WCAG 2.1 非文本图形对比度）
          _expectContrast(
            '$name $label icon / surface (图形)',
            iconAndText,
            c.surface,
            3.0,
          );
          _expectContrast(
            '$name $label icon / canvas (图形)',
            iconAndText,
            c.canvas,
            3.0,
          );
          _expectContrast(
            '$name $label icon / pill @surface (图形)',
            iconAndText,
            surfacePillBg,
            3.0,
          );
          _expectContrast(
            '$name $label icon / pill @canvas (图形)',
            iconAndText,
            canvasPillBg,
            3.0,
          );

          // 文本通道 ≥ 4.5:1（在主底色、卡片表面、弱底色及卡片/底色上的 12% 淡底胶囊均达标）
          _expectContrast(
            '$name $label text / surface',
            iconAndText,
            c.surface,
            4.5,
          );
          _expectContrast(
            '$name $label text / canvas',
            iconAndText,
            c.canvas,
            4.5,
          );
          _expectContrast(
            '$name $label text / surfaceMuted',
            iconAndText,
            c.surfaceMuted,
            4.5,
          );
          _expectContrast(
            '$name $label text / pill @surface',
            iconAndText,
            surfacePillBg,
            4.5,
          );
          _expectContrast(
            '$name $label text / pill @canvas',
            iconAndText,
            canvasPillBg,
            4.5,
          );

          // 选中态实心胶囊前景/填充 ≥ 4.5:1
          _expectContrast(
            '$name $label onFill / fill',
            onFill,
            fill,
            4.5,
          );
        }
      });
    }
  });

  group('DsTheme、buildCommandTheme 与基础 Token 契约', () {
    test('buildCommandTheme 构建双主题 M3 配置与字体回退链', () {
      for (final brightness in Brightness.values) {
        final theme = buildCommandTheme(brightness);
        final expectedColors = DsColors.of(brightness);
        expect(theme.useMaterial3, isTrue);
        expect(theme.brightness, brightness);
        expect(theme.scaffoldBackgroundColor, expectedColors.canvas);
        expect(theme.canvasColor, expectedColors.surface);
        expect(theme.dividerColor, expectedColors.border);
        expect(theme.colorScheme.surface, expectedColors.surface);
        expect(theme.colorScheme.primary, expectedColors.brand);
        expect(theme.colorScheme.onPrimary, expectedColors.onBrand);
        expect(theme.colorScheme.surfaceTint, Colors.transparent);
        expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
        expect(
          theme.bottomSheetTheme.shape,
          const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(DsRadius.xl),
            ),
          ),
        );
        expect(
          theme.textTheme.bodyMedium?.fontFamily,
          DsTypography.fontFamily,
        );
        expect(
          theme.textTheme.bodyMedium?.fontFamilyFallback,
          DsTypography.fontFamilyFallback,
        );

        final ext = theme.extension<DsTheme>();
        expect(ext, isNotNull);
        expect(ext!.brightness, brightness);
        expect(ext.colors, equals(expectedColors));
        expect(ext.typography, equals(DsTypography.standard));
      }
    });

    test('buildCommandTheme ColorScheme 全部前景/背景配对达到 WCAG AA (≥ 4.5:1)', () {
      for (final brightness in Brightness.values) {
        final label = brightness == Brightness.dark ? '暗曜 Night' : '昼白 Daylight';
        final cs = buildCommandTheme(brightness).colorScheme;
        _expectContrast('$label onPrimary / primary', cs.onPrimary, cs.primary, 4.5);
        _expectContrast(
          '$label onSecondary / secondary',
          cs.onSecondary,
          cs.secondary,
          4.5,
        );
        _expectContrast(
          '$label onTertiary / tertiary',
          cs.onTertiary,
          cs.tertiary,
          4.5,
        );
        _expectContrast('$label onError / error', cs.onError, cs.error, 4.5);
        _expectContrast('$label onSurface / surface', cs.onSurface, cs.surface, 4.5);
        _expectContrast(
          '$label onSurfaceVariant / surface',
          cs.onSurfaceVariant,
          cs.surface,
          4.5,
        );
        _expectContrast(
          '$label onPrimaryContainer / alphaBlend(primaryContainer, surface)',
          cs.onPrimaryContainer,
          Color.alphaBlend(cs.primaryContainer, cs.surface),
          4.5,
        );
        _expectContrast(
          '$label onSecondaryContainer / alphaBlend(secondaryContainer, surface)',
          cs.onSecondaryContainer,
          Color.alphaBlend(cs.secondaryContainer, cs.surface),
          4.5,
        );
        _expectContrast(
          '$label onTertiaryContainer / alphaBlend(tertiaryContainer, surface)',
          cs.onTertiaryContainer,
          Color.alphaBlend(cs.tertiaryContainer, cs.surface),
          4.5,
        );
        _expectContrast(
          '$label onErrorContainer / alphaBlend(errorContainer, surface)',
          cs.onErrorContainer,
          Color.alphaBlend(cs.errorContainer, cs.surface),
          4.5,
        );
        _expectContrast(
          '$label onInverseSurface / inverseSurface',
          cs.onInverseSurface,
          cs.inverseSurface,
          4.5,
        );
        _expectContrast(
          '$label inversePrimary / inverseSurface',
          cs.inversePrimary,
          cs.inverseSurface,
          4.5,
        );
      }
    });

    test('StatusColorPair.lerp 与 DsTypography.lerp 边界、钳制及中间态正确', () {
      final dayAlarm = DsColors.daylight.statusColors(DsStatus.alarm);
      final nightAlarm = DsColors.night.statusColors(DsStatus.alarm);

      expect(StatusColorPair.lerp(dayAlarm, dayAlarm, 0.5), same(dayAlarm));
      expect(StatusColorPair.lerp(dayAlarm, nightAlarm, 0.0), equals(dayAlarm));
      expect(StatusColorPair.lerp(dayAlarm, nightAlarm, -0.5), equals(dayAlarm));
      expect(StatusColorPair.lerp(dayAlarm, nightAlarm, 1.0), equals(nightAlarm));
      expect(StatusColorPair.lerp(dayAlarm, nightAlarm, 1.5), equals(nightAlarm));

      final midPair = StatusColorPair.lerp(dayAlarm, nightAlarm, 0.5);
      expect(midPair.text, Color.lerp(dayAlarm.text, nightAlarm.text, 0.5));
      expect(midPair.pillBg, Color.lerp(dayAlarm.pillBg, nightAlarm.pillBg, 0.5));
      expect(midPair.metricText, isNot(equals(dayAlarm.metricText)));
      expect(midPair.metricText, isNot(equals(nightAlarm.metricText)));

      const baseTypo = DsTypography.standard;
      final scaledTypo = DsTypography(
        display: baseTypo.display.copyWith(fontSize: 36),
        headline: baseTypo.headline.copyWith(fontSize: 24),
        title: baseTypo.title.copyWith(fontSize: 20),
        body: baseTypo.body.copyWith(fontSize: 18),
        caption: baseTypo.caption.copyWith(fontSize: 16),
        micro: baseTypo.micro.copyWith(fontSize: 15),
        metric: baseTypo.metric.copyWith(fontSize: 26),
        metricLarge: baseTypo.metricLarge.copyWith(fontSize: 40),
      );

      expect(DsTypography.lerp(baseTypo, baseTypo, 0.5), same(baseTypo));
      expect(DsTypography.lerp(baseTypo, scaledTypo, 0.0), equals(baseTypo));
      expect(DsTypography.lerp(baseTypo, scaledTypo, -0.5), equals(baseTypo));
      expect(DsTypography.lerp(baseTypo, scaledTypo, 1.0), equals(scaledTypo));
      expect(DsTypography.lerp(baseTypo, scaledTypo, 1.5), equals(scaledTypo));

      final midTypo = DsTypography.lerp(baseTypo, scaledTypo, 0.5);
      expect(midTypo.display.fontSize, closeTo(32, 1e-6));
      expect(midTypo.body.fontSize, closeTo(16, 1e-6));
      expect(midTypo.metric.fontSize, closeTo(24, 1e-6));
      expect(midTypo.display.color, isNull);
      expect(midTypo.body.color, isNull);
    });

    test('DsTheme copyWith 与 lerp 行为正确', () {
      const day = DsTheme.daylight;
      const night = DsTheme.night;
      expect(day.lerp(night, 0.0), equals(day));
      expect(day.lerp(night, -0.5), equals(day));
      expect(day.lerp(night, 1.0), equals(night));
      expect(day.lerp(night, 1.5), equals(night));
      expect(day.lerp(null, 0.5), equals(day));

      final mid = day.lerp(night, 0.5);
      expect(mid.colors.canvas, isNot(equals(day.colors.canvas)));
      expect(mid.colors.canvas, isNot(equals(night.colors.canvas)));

      final copied = day.copyWith(brightness: Brightness.dark);
      expect(copied.brightness, Brightness.dark);
      expect(copied.colors, equals(day.colors));
    });

    test('Typography、Spacing、Radius、Sizes、Motion Token 数值契约', () {
      const t = DsTypography.standard;
      expect(t.display.fontSize, 28);
      expect(t.display.height, closeTo(34 / 28, 1e-6));
      expect(t.display.fontWeight, FontWeight.w700);
      expect(t.headline.fontSize, 20);
      expect(t.headline.height, closeTo(26 / 20, 1e-6));
      expect(t.headline.fontWeight, FontWeight.w600);
      expect(t.title.fontSize, 16);
      expect(t.title.height, closeTo(22 / 16, 1e-6));
      expect(t.title.fontWeight, FontWeight.w600);
      expect(t.body.fontSize, 14);
      expect(t.body.height, closeTo(20 / 14, 1e-6));
      expect(t.body.fontWeight, FontWeight.w400);
      expect(t.caption.fontSize, 12);
      expect(t.caption.height, closeTo(16 / 12, 1e-6));
      expect(t.caption.fontWeight, FontWeight.w400);
      expect(t.micro.fontSize, 11);
      expect(t.micro.height, closeTo(14 / 11, 1e-6));
      expect(t.micro.fontWeight, FontWeight.w500);
      expect(t.metric.fontSize, 22);
      expect(t.metric.height, closeTo(28 / 22, 1e-6));
      expect(t.metric.fontWeight, FontWeight.w600);
      expect(t.metricLarge.fontSize, 32);
      expect(t.metricLarge.height, closeTo(38 / 32, 1e-6));
      expect(t.metricLarge.fontWeight, FontWeight.w600);

      expect(t.display.color, isNull);
      expect(t.headline.color, isNull);
      expect(t.title.color, isNull);
      expect(t.body.color, isNull);
      expect(t.caption.color, isNull);
      expect(t.micro.color, isNull);
      expect(t.metric.color, isNull);
      expect(t.metricLarge.color, isNull);

      expect(
        t.metric.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(
        t.metricLarge.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(
        t.bodyTabular.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(
        t.captionTabular.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(DsTypography.tabular(t.metric).fontFeatures?.length, 1);

      expect(DsSpacing.xs, 4);
      expect(DsSpacing.sm, 8);
      expect(DsSpacing.md, 12);
      expect(DsSpacing.lg, 16);
      expect(DsSpacing.xl, 20);
      expect(DsSpacing.xxl, 24);
      expect(DsSpacing.pageMargin, 16);
      expect(DsSpacing.cardPadding, 16);
      expect(DsSpacing.cardGap, 12);

      expect(DsRadius.sm, 6);
      expect(DsRadius.md, 10);
      expect(DsRadius.lg, 14);
      expect(DsRadius.xl, 20);
      expect(DsRadius.pill, 999);
      expect(DsRadius.full, DsRadius.pill);

      expect(DsSizes.touchTarget, greaterThanOrEqualTo(48));
      expect(DsSizes.primaryAction, greaterThanOrEqualTo(56));
      expect(DsSizes.voiceButton, 64);
      expect(DsSizes.voiceProtrusion, 12);
      expect(DsSizes.navBarHeight, 64);
      expect(DsSizes.iconSm, 16);
      expect(DsSizes.iconMd, 20);
      expect(DsSizes.iconLg, 24);

      expect(DsMotion.fast, const Duration(milliseconds: 120));
      expect(DsMotion.normal, const Duration(milliseconds: 200));
      expect(DsMotion.slow, const Duration(milliseconds: 320));
    });

    testWidgets('DsMotion.resolve 尊重 disableAnimations 设置', (tester) async {
      late Duration resolvedNormal;
      late Duration resolvedDisabled;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: Builder(
            builder: (context) {
              resolvedNormal = DsMotion.resolve(context, DsMotion.normal);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolvedNormal, DsMotion.normal);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              resolvedDisabled = DsMotion.resolve(context, DsMotion.normal);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolvedDisabled, Duration.zero);

      MediaQueryData? missingMediaQuery;
      late Duration resolvedWithoutAncestor;
      await tester.pumpWidget(
        RawView(
          view: tester.view,
          child: Builder(
            builder: (context) {
              missingMediaQuery = MediaQuery.maybeOf(context);
              resolvedWithoutAncestor = DsMotion.resolve(context, DsMotion.slow);
              return const SizedBox.shrink();
            },
          ),
        ),
        wrapWithView: false,
      );
      expect(missingMediaQuery, isNull);
      expect(resolvedWithoutAncestor, DsMotion.slow);
    });

    testWidgets('context.ds 与 DsTheme.maybeOf 随主题切换生效，未注入时抛出 FlutterError', (
      tester,
    ) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          themeAnimationDuration: Duration.zero,
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(DsTheme.maybeOf(capturedContext), isNotNull);
      expect(capturedContext.ds.colors, equals(DsColors.daylight));

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.dark),
          themeAnimationDuration: Duration.zero,
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(capturedContext.ds.colors, equals(DsColors.night));

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          themeAnimationDuration: Duration.zero,
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(DsTheme.maybeOf(capturedContext), isNull);
      expect(() => capturedContext.ds, throwsFlutterError);
    });
  });
}
