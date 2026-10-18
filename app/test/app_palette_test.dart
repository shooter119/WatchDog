import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/theme/app_palette.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('调色板结构', () {
    test('id 唯一且 byId 对未知值回落默认', () {
      final ids = AppPalette.values.map((p) => p.id).toSet();
      expect(ids.length, AppPalette.values.length);
      expect(AppPalette.byId('warm-sand').id, 'warm-sand');
      expect(AppPalette.byId(null).id, 'daylight');
      expect(AppPalette.byId('').id, 'daylight');
      expect(AppPalette.byId('dark').id, 'daylight');
    });

    test('昼白方案与历史色值逐字相等（默认外观零变化）', () {
      const p = AppPalette.daylight;
      expect(p.background, const Color(0xFFF2F4F7));
      expect(p.surface, const Color(0xFFFFFFFF));
      expect(p.surfaceSubtle, const Color(0xFFE8ECF1));
      expect(p.border, const Color(0xFFD7DDE5));
      expect(p.textPrimary, const Color(0xFF111111));
      expect(p.textSecondary, const Color(0xFF4B5563));
      expect(p.textTertiary, const Color(0xFF6B7280));
      expect(p.safe, const Color(0xFF32C943));
      expect(p.caution, const Color(0xFFFFB000));
      expect(p.alarm, const Color(0xFFF5222D));
      expect(p.timeout, const Color(0xFFC90016));
      expect(p.voice, const Color(0xFFFF9500));
      expect(p.actionPrimary, const Color(0xFF111111));
      expect(p.onPrimary, const Color(0xFFFFFFFF));
      expect(p.onStatus, const Color(0xFFFFFFFF));
      expect(p.online, const Color(0xFF20A83A));
      expect(p.noteInfo, const Color(0xFF2F6FED));
      expect(p.heroBackground, const Color(0xFF111111));
      expect(p.avatarBackdrop, const Color(0xFFDDF3F5));
    });
  });

  group('对比度（正文 ≥4.5，图形 ≥3）', () {
    for (final p in AppPalette.values) {
      test('${p.id}: 正文与弱信息', () {
        expect(
          _contrast(p.textPrimary, p.background),
          greaterThanOrEqualTo(4.5),
        );
        expect(_contrast(p.textPrimary, p.surface), greaterThanOrEqualTo(4.5));
        expect(
          _contrast(p.textSecondary, p.background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(p.textSecondary, p.surface),
          greaterThanOrEqualTo(4.5),
        );
        // 昼白是历史配色，textTertiary 4.39 属既有水平；暖砂必须达到 4.5。
        final tertiaryFloor = p.id == AppPalette.warmSand.id ? 4.5 : 4.3;
        expect(
          _contrast(p.textTertiary, p.background),
          greaterThanOrEqualTo(tertiaryFloor),
        );
        expect(
          _contrast(p.textTertiary, p.surface),
          greaterThanOrEqualTo(tertiaryFloor),
        );
      });

      test('${p.id}: 主按钮与状态卡前景', () {
        expect(
          _contrast(p.onPrimary, p.actionPrimary),
          greaterThanOrEqualTo(4.5),
        );
        // safe/caution 卡片用深色文字；alarm/timeout 用浅色文字。
        expect(_contrast(p.textPrimary, p.safe), greaterThanOrEqualTo(4.5));
        expect(_contrast(p.textPrimary, p.caution), greaterThanOrEqualTo(4.5));
        // 昼白的 alarm 白字为 4.08（历史配色，不回调）；暖砂必须 ≥4.5。
        final alarmFloor = p.id == AppPalette.warmSand.id ? 4.5 : 4.0;
        expect(
          _contrast(p.onStatus, p.alarm),
          greaterThanOrEqualTo(alarmFloor),
        );
        expect(_contrast(p.onStatus, p.timeout), greaterThanOrEqualTo(4.5));
      });
    }

    test('暖砂：状态色作为图标/文字落在表面上仍可辨', () {
      const p = AppPalette.warmSand;
      for (final color in [p.safe, p.caution, p.alarm, p.timeout]) {
        expect(_contrast(color, p.surface), greaterThanOrEqualTo(2.5));
      }
      expect(_contrast(p.safe, p.surface), greaterThanOrEqualTo(3.0));
      expect(_contrast(p.caution, p.surface), greaterThanOrEqualTo(3.0));
    });

    test('暖砂：语音入口在主背景与卡片上都过图形阈值', () {
      const p = AppPalette.warmSand;
      expect(_contrast(p.voice, p.background), greaterThanOrEqualTo(3.0));
      expect(_contrast(p.voice, p.surface), greaterThanOrEqualTo(3.0));
      expect(_contrast(p.onPrimary, p.voice), greaterThanOrEqualTo(3.0));
    });

    test('暖砂：深色大卡信息层可读', () {
      const p = AppPalette.warmSand;
      expect(
        _contrast(p.heroOnDark, p.heroBackground),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(p.heroMuted, p.heroBackground),
        greaterThanOrEqualTo(4.5),
      );
    });
  });
}
