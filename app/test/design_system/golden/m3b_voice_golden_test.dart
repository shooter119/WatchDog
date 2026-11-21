@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/voice/state/voice_draft_person.dart';
import 'package:watchdog/features/voice/state/voice_session_types.dart';
import 'package:watchdog/features/voice/ui/voice_confirm_sheet.dart';
import 'package:watchdog/features/voice/ui/voice_exit_confirm_sheet.dart';
import 'package:watchdog/features/voice/ui/voice_recording_overlay.dart';

Future<void> _pumpVoiceGolden(
  WidgetTester tester, {
  required Brightness brightness,
  required Size size,
  required GlobalKey captureKey,
  required Widget child,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(key: captureKey, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3b VoiceRecordingOverlay ($themeTag)', (
      WidgetTester tester,
    ) async {
      final captureKey = GlobalKey();
      await _pumpVoiceGolden(
        tester,
        brightness: brightness,
        size: const Size(400, 720),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              backgroundColor: context.ds.colors.canvas,
              body: Stack(
                children: <Widget>[
                  VoiceRecordingOverlay(
                    status: VoiceSessionStatus.recording,
                    recordingSeconds: 52,
                    amplitude: 0.72,
                    liveTranscript: '张三20兆帕，李四22兆帕，钢瓶9升进入火场',
                    pendingDraftCount: 1,
                    onStopRecording: () {},
                  ),
                ],
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3b_voice_recording_overlay_$themeTag.png'),
      );
    });

    testWidgets('M3b VoiceConfirmSheet ($themeTag)', (
      WidgetTester tester,
    ) async {
      final captureKey = GlobalKey();
      await _pumpVoiceGolden(
        tester,
        brightness: brightness,
        size: const Size(400, 820),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              backgroundColor: context.ds.colors.canvas,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: VoiceConfirmSheet(
                  transcript: '张三20兆帕，李四22兆帕，钢瓶9升进入火场',
                  calcParams: const VoiceCalcParams(
                    cylinderVolL: 6.8,
                    consumptionLpm: 80,
                  ),
                  rosterNames: const ['张三', '李四', '王五'],
                  activeEntryNames: const {'张三'},
                  drafts: const [
                    VoiceDraftPerson(
                      id: 'd1',
                      name: '张三',
                      pressureText: '20',
                      volumeL: 9.0,
                    ),
                    VoiceDraftPerson(
                      id: 'd2',
                      name: '',
                      sourceName: '赵某',
                      pressureText: '22',
                      volumeL: 6.8,
                    ),
                  ],
                  onNameChanged: (_, _) {},
                  onPressureChanged: (_, _) {},
                  onVolumeChanged: (_, _) {},
                  onRemoveAt: (_) {},
                  onConfirmAll: () {},
                  onContinueVoice: () {},
                  onRetry: () {},
                ),
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3b_voice_confirm_sheet_$themeTag.png'),
      );
    });

    testWidgets('M3b VoiceExitConfirmSheet ($themeTag)', (
      WidgetTester tester,
    ) async {
      final captureKey = GlobalKey();
      await _pumpVoiceGolden(
        tester,
        brightness: brightness,
        size: const Size(400, 680),
        captureKey: captureKey,
        child: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              backgroundColor: context.ds.colors.canvas,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: VoiceExitConfirmSheet(
                  entries: const [
                    VoiceActiveEntry(
                      id: 'e1',
                      name: '张三',
                      version: 1,
                      pressureMpa: 20,
                    ),
                    VoiceActiveEntry(
                      id: 'e2',
                      name: '李四',
                      version: 1,
                      pressureMpa: 18,
                    ),
                    VoiceActiveEntry(
                      id: 'e3',
                      name: '王五',
                      version: 1,
                      pressureMpa: 15,
                    ),
                  ],
                  voiceText: '全体内攻人员撤出火场',
                  isAllExit: true,
                  onConfirm: () {},
                  onCancel: () {},
                ),
              ),
            );
          },
        ),
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3b_voice_exit_confirm_sheet_$themeTag.png'),
      );
    });
  }
}
