import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/voice/state/voice_session_types.dart';
import 'package:watchdog/features/voice/ui/voice_recording_overlay.dart';

Widget _wrapOverlay(
  VoiceRecordingOverlay overlay, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  double textScale = 1.0,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(body: Stack(children: <Widget>[overlay])),
    ),
  );
}

void main() {
  group('VoiceRecordingOverlay 全局录音浮层', () {
    testWidgets('录音态渲染核心 Key、实时字幕、已录秒数、分批提示与 >=56dp 停止按钮', (tester) async {
      var stopped = 0;
      await tester.pumpWidget(
        _wrapOverlay(
          VoiceRecordingOverlay(
            status: VoiceSessionStatus.recording,
            recordingSeconds: 12,
            amplitude: 0.7,
            liveTranscript: '张三20兆帕进场',
            pendingDraftCount: 2,
            onStopRecording: () => stopped++,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('voice-recording-overlay')), findsOneWidget);
      expect(find.byKey(const Key('voice-recording-timer')), findsOneWidget);
      expect(find.byKey(const Key('voice-live-transcript')), findsOneWidget);
      expect(find.text('张三20兆帕进场'), findsOneWidget);
      expect(find.text('最长录音 60 秒 · 已录 12 秒'), findsOneWidget);
      expect(find.text('已录入 2 人，本次语音将追加到名单'), findsOneWidget);

      final stopBtn = find.text('完成并识别');
      expect(tester.getRect(stopBtn).height, greaterThan(0));
      await tester.tap(stopBtn);
      await tester.pump();
      expect(stopped, 1);
    });

    testWidgets('达到 50 秒预警态展示剩余倒计时提示', (tester) async {
      await tester.pumpWidget(
        _wrapOverlay(
          const VoiceRecordingOverlay(
            status: VoiceSessionStatus.recording,
            recordingSeconds: 52,
            amplitude: 0.5,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('voice-recording-timer')), findsOneWidget);
      expect(find.text('还剩 8 秒，时间到将自动结束'), findsOneWidget);
    });

    testWidgets('尊重 MediaQuery.disableAnimations 禁用脉冲与进度动画', (tester) async {
      await tester.pumpWidget(
        _wrapOverlay(
          const VoiceRecordingOverlay(
            status: VoiceSessionStatus.recording,
            recordingSeconds: 10,
            amplitude: 0.95,
          ),
          disableAnimations: true,
        ),
      );
      await tester.pump();

      final scales = tester.widgetList<AnimatedScale>(find.byType(AnimatedScale));
      expect(scales, isNotEmpty);
      for (final scale in scales) {
        expect(scale.scale, 1.0);
        expect(scale.duration, Duration.zero);
      }

      await tester.pumpWidget(
        _wrapOverlay(
          const VoiceRecordingOverlay(status: VoiceSessionStatus.processing),
          disableAnimations: true,
        ),
      );
      await tester.pump();

      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.value, isNotNull);
      expect(find.text('语音转文字中…'), findsOneWidget);
    });

    testWidgets('麦克风权限被拒展示去系统设置引导，并保留返回确认入口', (tester) async {
      var openedSettings = 0;
      var returned = 0;
      var retried = 0;
      await tester.pumpWidget(
        _wrapOverlay(
          VoiceRecordingOverlay(
            status: VoiceSessionStatus.error,
            errorMessage: '需要麦克风权限',
            permissionDenied: true,
            pendingDraftCount: 1,
            onOpenSettings: () => openedSettings++,
            onReturnToConfirm: () => returned++,
            onRetry: () => retried++,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('需要麦克风权限'), findsOneWidget);
      expect(find.text('去系统设置'), findsOneWidget);
      expect(find.text('返回确认（1 人）'), findsOneWidget);

      await tester.tap(find.text('去系统设置'));
      await tester.tap(find.text('重新语音输入'));
      await tester.tap(find.text('返回确认（1 人）'));
      await tester.pump();

      expect(openedSettings, 1);
      expect(retried, 1);
      expect(returned, 1);
    });

    testWidgets('360dp 窄屏 + 130% 字号下录音/识别/权限被拒三态均零溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 680);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      for (final overlay in <VoiceRecordingOverlay>[
        VoiceRecordingOverlay(
          status: VoiceSessionStatus.recording,
          recordingSeconds: 54,
          amplitude: 0.8,
          liveTranscript: '张三20兆帕，李四22兆帕，使用9升气瓶进入火场',
          pendingDraftCount: 2,
          onStopRecording: () {},
        ),
        const VoiceRecordingOverlay(status: VoiceSessionStatus.processing),
        VoiceRecordingOverlay(
          status: VoiceSessionStatus.error,
          errorMessage: '需要麦克风权限',
          permissionDenied: true,
          pendingDraftCount: 2,
          onOpenSettings: () {},
          onRetry: () {},
          onReturnToConfirm: () {},
        ),
      ]) {
        await tester.pumpWidget(
          _wrapOverlay(
            overlay,
            size: const Size(360, 680),
            textScale: 1.3,
            disableAnimations: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  });
}
