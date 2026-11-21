@Tags(['golden'])
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/copilot/data/models/chat_message.dart';
import 'package:watchdog/features/copilot/data/models/vision_analysis.dart';
import 'package:watchdog/features/copilot/state/copilot_store.dart';
import 'package:watchdog/features/copilot/ui/copilot_page.dart';
import 'package:watchdog/services/audio_service.dart';

class _GoldenAudioService implements AudioService {
  @override
  bool get isRecording => false;

  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> start() async {}

  @override
  Stream<double> amplitudeStream() => const Stream<double>.empty();

  @override
  Future<Uint8List> stop() async => Uint8List(0);

  @override
  Future<void> dispose() async {}
}

CopilotStore _makeGoldenStore({
  required List<ChatMessage> history,
  required bool hasIncidentContext,
}) {
  return CopilotStore(
    audioService: _GoldenAudioService(),
    gateway: CopilotGateway(
      readScope: () => 'unit-demo|inc-demo',
      hasIncidentContext: () => hasIncidentContext,
      fetchHistory: () async => history,
      askAssistantStream:
          (msg, {required onChunk, opId, history = const []}) async => '',
      cancelAssistantRequest: () {},
      clearHistory: () async {},
      analyzeVision:
          (bytes, {required mimeType, message = '', opId}) async =>
              const VisionAnalysis(
                relevance: 'related',
                category: 'fire',
                confidence: 0.9,
                facts: [],
                risks: [],
                toConfirm: [],
                suggestions: [],
                disclaimer: '以上为图片辅助分析，不替代现场专业判断',
              ),
      transcribeAudio: (bytes, {opId}) async => '',
    ),
  );
}

Future<void> _pumpCopilotGolden(
  WidgetTester tester, {
  required Brightness brightness,
  required GlobalKey captureKey,
  required CopilotStore store,
}) async {
  const surfaceSize = Size(390, 844);
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(
        size: surfaceSize,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.noScaling,
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildCommandTheme(brightness),
        themeAnimationDuration: Duration.zero,
        home: RepaintBoundary(
          key: captureKey,
          child: Scaffold(
            body: CopilotPage(store: store, bottomNavClearance: 12.0),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final ctx = tester.element(find.byType(CopilotPage));
    await precacheImage(
      const AssetImage('assets/avatars/water-element-avatar-selected.png'),
      ctx,
    );
  });
  await tester.pumpAndSettle();
}

final List<ChatMessage> _goldenMessages = <ChatMessage>[
  ChatMessage(
    id: 'g-u1',
    role: 'user',
    content: '锂电池仓库起火，现场有刺鼻白烟，首批力量如何处置？',
    createdAt: DateTime(2026, 6, 1, 14, 28).millisecondsSinceEpoch,
  ),
  ChatMessage(
    id: 'g-a1',
    role: 'assistant',
    content:
        '**核心判断：存在热失控复燃与有毒氟化氢烟气风险**\n\n'
        '- **上风向警戒**：全员佩戴正压式空气呼吸器，严禁无防护进入烟区。\n'
        '- **持续大流量冷却**：优先喷雾水流持续降温，严禁少量间断喷水。\n'
        '- **防爆泄压**：监测温度变化，警惕密闭空间烟气爆燃。\n'
        '<<<FOLLOW_UPS>>>\n'
        '展开锂电池复燃监测与冷却时长标准\n'
        '个人防护与洗消要点\n'
        '周边排水与环保围堰措施',
    createdAt: DateTime(2026, 6, 1, 14, 29).millisecondsSinceEpoch,
  ),
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final brightness in Brightness.values) {
    final themeTag = brightness == Brightness.light ? 'daylight' : 'night';

    testWidgets('M3d Copilot 欢迎态 ($themeTag)', (tester) async {
      final store = _makeGoldenStore(
        history: const [],
        hasIncidentContext: true,
      );
      addTearDown(store.dispose);
      final captureKey = GlobalKey();

      await _pumpCopilotGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        store: store,
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3d_copilot_welcome_$themeTag.png'),
      );
    });

    testWidgets('M3d Copilot 含追问胶囊对话流 ($themeTag)', (tester) async {
      final store = _makeGoldenStore(
        history: _goldenMessages,
        hasIncidentContext: true,
      );
      addTearDown(store.dispose);
      final captureKey = GlobalKey();

      await _pumpCopilotGolden(
        tester,
        brightness: brightness,
        captureKey: captureKey,
        store: store,
      );
      await expectLater(
        find.byKey(captureKey),
        matchesGoldenFile('goldens/m3d_copilot_chat_$themeTag.png'),
      );
    });
  }
}
