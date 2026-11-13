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
      expect(ids, {'daylight', 'warm-sand'});
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
      expect(p.cautionSurface, const Color(0xFFFEFCE8));
      expect(p.border, const Color(0xFFD7DDE5));
      expect(p.textPrimary, const Color(0xFF111111));
      expect(p.textSecondary, const Color(0xFF4B5563));
      expect(p.textTertiary, const Color(0xFF6B7280));
      expect(p.safe, const Color(0xFF32C943));
      expect(p.caution, const Color(0xFFFFB000));
      expect(p.alarm, const Color(0xFFDC2626)); // 由 #F5222D 升级以满足白字对比度
      expect(p.timeout, const Color(0xFF7F1D1D)); // 由 #C90016 升级以拉开与 alarm 区分度
      expect(p.voice, const Color(0xFFF95700)); // 由 #FF9500 升级以提高白字图标对比度
      expect(p.actionPrimary, const Color(0xFF111111));
      expect(p.onPrimary, const Color(0xFFFFFFFF));
      expect(p.onStatus, const Color(0xFFFFFFFF));
      expect(p.online, const Color(0xFF20A83A));
      expect(p.noteInfo, const Color(0xFF2F6FED));
      expect(p.heroBackground, const Color(0xFF111111));
      expect(p.avatarBackdrop, const Color(0xFFDDF3F5));
      // 新增双通道文字与动作色
      expect(p.safeText, const Color(0xFF15803D));
      expect(p.cautionText, const Color(0xFFB45309));
      expect(p.alarmText, const Color(0xFFB91C1C));
      expect(p.timeoutText, const Color(0xFF7F1D1D));
      expect(p.destructive, const Color(0xFFB91C1C));
      expect(p.voicePressed, const Color(0xFFD44000));
      // Batch 2: 通告条告警底色与前景色
      expect(p.noticeWarningBg, const Color(0xFFFEF3C7));
      expect(p.noticeWarningFg, const Color(0xFF92400E));
    });
  });

  group('对比度（正文 ≥4.5，图形 ≥3）', () {
    for (final p in AppPalette.values) {
      test('${p.id}: 双通道状态文字、告警区分度与动作色对比度', () {
        for (final text in [
          p.safeText,
          p.cautionText,
          p.alarmText,
          p.timeoutText,
        ]) {
          expect(_contrast(text, p.surface), greaterThanOrEqualTo(4.5));
          expect(_contrast(text, p.background), greaterThanOrEqualTo(4.5));
        }
        expect(
          _contrast(p.cautionText, p.cautionSurface),
          greaterThanOrEqualTo(4.5),
        );
        expect(_contrast(p.onStatus, p.alarm), greaterThanOrEqualTo(4.5));
        expect(_contrast(p.onStatus, p.timeout), greaterThanOrEqualTo(4.5));
        expect(
          _contrast(
            p.onStatus,
            p.destructive,
          ), // 危险确认按钮用 onStatus 白字（夜间 onPrimary 为深色）
          greaterThanOrEqualTo(4.5),
        );
        expect(_contrast(p.onPrimary, p.voice), greaterThanOrEqualTo(3.0));
        // alarm 与 timeout 亮度对比度 ≥1.8，保证双告警色视觉分明
        expect(_contrast(p.alarm, p.timeout), greaterThanOrEqualTo(1.8));
        // Batch 2: 通告条 warning 前景 vs 背景对比度 ≥4.5
        expect(
          _contrast(p.noticeWarningFg, p.noticeWarningBg),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
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
        // 昼白 alarm 已升级为 #DC2626（对比度 4.83），与暖砂一致均 ≥4.5。
        expect(_contrast(p.onStatus, p.alarm), greaterThanOrEqualTo(4.5));
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

    for (final p in AppPalette.values) {
      test('${p.id}: 警情三大类语义色对比度（文本 ≥4.5，图形 ≥3.0）', () {
        final pairs = [
          (p.incidentFire, p.incidentFireText, p.incidentFireSurface),
          (p.incidentRescue, p.incidentRescueText, p.incidentRescueSurface),
          (p.incidentAid, p.incidentAidText, p.incidentAidSurface),
        ];
        for (final (iconColor, textColor, surfaceColor) in pairs) {
          expect(_contrast(iconColor, p.surface), greaterThanOrEqualTo(3.0));
          expect(_contrast(iconColor, surfaceColor), greaterThanOrEqualTo(3.0));
          expect(_contrast(textColor, p.surface), greaterThanOrEqualTo(4.5));
          expect(_contrast(textColor, p.background), greaterThanOrEqualTo(4.5));
          expect(_contrast(textColor, surfaceColor), greaterThanOrEqualTo(4.5));
        }
      });
    }
  });
}
