import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/app/shell/command_app_shell.dart';
import 'package:watchdog/app/shell/shell_keys.dart';
import 'package:watchdog/app/shell/shell_voice_bridge.dart';
import 'package:watchdog/features/copilot/data/models/chat_message.dart';
import 'package:watchdog/features/monitor/data/models/entry.dart';
import 'package:watchdog/features/notes/data/models/note.dart';
import 'package:watchdog/features/notes/data/models/note_category.dart';
import 'package:watchdog/features/voice/data/models/voice_parse.dart';
import 'package:watchdog/features/voice/state/voice_session_store.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/state/app_controller.dart';

class _StubAudioService implements AudioService {
  bool _recording = false;
  int startCalls = 0;
  int stopCalls = 0;
  final Uint8List stopBytes = Uint8List.fromList(List<int>.filled(128, 7));

  @override
  bool get isRecording => _recording;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {
    startCalls++;
    _recording = true;
  }

  @override
  Stream<double> amplitudeStream() => const Stream<double>.empty();

  @override
  Future<Uint8List> stop() async {
    stopCalls++;
    _recording = false;
    return stopBytes;
  }

  @override
  Future<void> dispose() async {}
}

class _FakeIntegrationController extends AppController {
  _FakeIntegrationController({List<Entry> initialEntries = const <Entry>[]}) {
    entries = List<Entry>.of(initialEntries);
  }

  final List<String> addedNotes = <String>[];
  final List<({List<String> names, String action, String category})>
  actionLogs = <({List<String> names, String action, String category})>[];
  final List<String> askedQuestions = <String>[];
  final List<({String id, double pressureMpa})> mergedPressures =
      <({String id, double pressureMpa})>[];
  final List<String> exitedIds = <String>[];
  String nextChatTranscript = '室内烟气层过低如何内攻';
  int _idSeed = 0;

  @override
  bool get needsAuthentication => false;

  @override
  bool get needsIncidentSelection => false;

  @override
  bool get requiresIncident => false;

  @override
  bool get isGuest => false;

  @override
  Future<void> init() async {}

  @override
  Future<void> checkUpdateSilently() async {}

  @override
  Future<void> sync() async {}

  @override
  Future<void> refreshNow() async {}

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => const <ChatMessage>[];

  @override
  Future<String> transcribeAudio(Uint8List bytes, {String? opId}) async =>
      nextChatTranscript;

  @override
  Future<String> askAssistantStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const <ChatMessage>[],
  }) async {
    askedQuestions.add(message);
    const reply = '保持低姿前进，先测温排烟再分段推进。';
    onChunk(reply);
    return reply;
  }

  @override
  void cancelAssistantRequest() {}

  @override
  Future<Entry?> createEntryFromVoice({
    required String name,
    required double pressureMpa,
    String? rawText,
    bool force = false,
    double? volumeL,
    String? opId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final vol = volumeL ?? calcConfig.cylinderVolL;
    final dur = calcConfig
        .durationMinFor(pressureMpa, cylinderVolL: vol)
        .round();
    final created = Entry(
      id: 'e-${++_idSeed}',
      name: name,
      pressureMpa: pressureMpa,
      durationMin: dur,
      entryAt: now,
      exitAt: now + dur * 60000,
      source: 'voice',
      rawText: rawText,
      cylinderVolL: vol,
      consumptionLpm: calcConfig.consumptionLpm,
    );
    entries = <Entry>[created, ...entries];
    notifyListeners();
    return created;
  }

  @override
  Future<Entry> mergeEntryPressure({
    required String id,
    required double pressureMpa,
    String? opId,
    int? expectedVersion,
  }) async {
    mergedPressures.add((id: id, pressureMpa: pressureMpa));
    final current = entries.firstWhere((e) => e.id == id);
    final updated = current.copyWith(
      pressureMpa: pressureMpa,
      version: current.version + 1,
    );
    entries = <Entry>[for (final e in entries) e.id == id ? updated : e];
    notifyListeners();
    return updated;
  }

  @override
  Future<void> markExited(
    String id, {
    String? opId,
    int? expectedVersion,
  }) async {
    exitedIds.add(id);
    final now = DateTime.now().millisecondsSinceEpoch;
    entries = <Entry>[
      for (final e in entries) e.id == id ? e.copyWith(exitedAt: now) : e,
    ];
    notifyListeners();
  }

  @override
  Future<Note> addNote(String text, {String? category, String? opId}) async {
    addedNotes.add(text);
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = Note(
      id: 'n-${++_idSeed}',
      text: text,
      category: category ?? NoteCategory.fromText(text),
      createdAt: now,
      updatedAt: now,
    );
    notes = <Note>[note, ...notes];
    notifyListeners();
    return note;
  }

  @override
  Future<Note> addActionLog({
    required Iterable<String> names,
    required String action,
    required String category,
    Map<String, double>? pressuresMpa,
    String? opId,
  }) async {
    final list = names.toList(growable: false);
    actionLogs.add((names: list, action: action, category: category));
    return addNote('${list.join('、')}$action', category: category, opId: opId);
  }
}

Entry _makeActiveEntry(String id, String name, {double pressureMpa = 28}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return Entry(
    id: id,
    name: name,
    pressureMpa: pressureMpa,
    durationMin: 24,
    entryAt: now - 60000,
    exitAt: now + 23 * 60000,
    source: 'voice',
  );
}

class _TestHarness {
  _TestHarness({
    required this.controller,
    required this.globalAudio,
    required this.copilotAudio,
    required this.voiceStore,
    required this.shell,
  });

  final _FakeIntegrationController controller;
  final _StubAudioService globalAudio;
  final _StubAudioService copilotAudio;
  final VoiceSessionStore voiceStore;
  final CommandAppShell shell;

  void dispose() {
    voiceStore.dispose();
    controller.dispose();
  }
}

_TestHarness _createHarness({
  List<Entry> initialEntries = const <Entry>[],
  required String Function() nextTranscript,
  required ParseResult Function(String text) nextParse,
}) {
  final controller = _FakeIntegrationController(initialEntries: initialEntries);
  final globalAudio = _StubAudioService();
  final copilotAudio = _StubAudioService();
  final voiceStore = VoiceSessionStore(
    audioService: globalAudio,
    isCloudAsrEnabled: () => true,
    isCloudParseEnabled: () => true,
    cloudTranscribe: (Uint8List _, {String? opId}) async => nextTranscript(),
    cloudParse: (String text, {String? opId}) async => nextParse(text),
    rosterNamesProvider: () => const <String>['张三', '李四', '王五'],
  );
  final shell = CommandAppShell(
    controller: controller,
    chatAudioService: copilotAudio,
    voiceSessionStore: voiceStore,
    enableStartupSideEffects: false,
    commandTabBuilder: (_) => const Center(child: Text('指挥台占位')),
    mineTabBuilder: (_) => const Center(child: Text('我的占位')),
  );
  return _TestHarness(
    controller: controller,
    globalAudio: globalAudio,
    copilotAudio: copilotAudio,
    voiceStore: voiceStore,
    shell: shell,
  );
}

Future<void> _longPressVoiceButton(
  WidgetTester tester, {
  Future<void> Function()? whileHeld,
}) async {
  final center = tester.getCenter(find.byKey(ShellKeys.voiceBtn));
  final gesture = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
  if (whileHeld != null) {
    await whileHeld();
  }
  await gesture.up();
  await tester.pump();
  await tester.pumpAndSettle();
}

int? _currentTab(WidgetTester tester) =>
    tester.widget<IndexedStack>(find.byType(IndexedStack)).index;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    ThemeController.instance.resetForTest();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
  });

  group('CommandAppShell M3a/M3b/M3d 接线集成测试', () {
    testWidgets('跨页原地录音进场 -> 确认入场 -> 跳 Tab 1 MonitorPage 实时显示', (
      tester,
    ) async {
      final h = _createHarness(
        nextTranscript: () => '张三二十八兆帕进场',
        nextParse: (_) => ParseResult(
          action: 'enter',
          intent: VoiceIntent.entry,
          people: <ParsePerson>[ParsePerson(name: '张三', pressureMpa: 28)],
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.shell);
      await tester.pumpAndSettle();

      // 切到 Tab 3（我的）长按中置语音键：原地弹出全局录音浮层，不跳页。
      await tester.tap(find.byKey(ShellKeys.tabMine));
      await tester.pumpAndSettle();
      expect(_currentTab(tester), ShellVoiceBridge.mineTabIndex);

      await _longPressVoiceButton(
        tester,
        whileHeld: () async {
          expect(_currentTab(tester), ShellVoiceBridge.mineTabIndex);
          expect(find.byKey(const Key('voice-recording-overlay')), findsOneWidget);
        },
      );

      // 松手后展示进场确认 Sheet，点击全部确认 -> 跳 Tab 1 MonitorPage 并显示张三。
      expect(find.byKey(const Key('voice-confirm-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-confirm-all-btn')));
      await tester.pumpAndSettle();

      expect(_currentTab(tester), ShellVoiceBridge.monitorTabIndex);
      expect(find.byKey(const Key('monitor-page')), findsOneWidget);
      expect(find.text('张三'), findsOneWidget);
      expect(h.controller.entries.length, 1);
      expect(h.controller.actionLogs.last.action, '进场');
      expect(tester.takeException(), isNull);
    });

    testWidgets('同名在场人员触发 SameNameConflictSheet 合并回调', (tester) async {
      final h = _createHarness(
        initialEntries: <Entry>[_makeActiveEntry('e-existing', '张三', pressureMpa: 28)],
        nextTranscript: () => '张三二十四兆帕',
        nextParse: (_) => ParseResult(
          action: 'enter',
          intent: VoiceIntent.entry,
          people: <ParsePerson>[ParsePerson(name: '张三', pressureMpa: 24)],
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.shell);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ShellKeys.tabMonitor));
      await tester.pumpAndSettle();

      await _longPressVoiceButton(tester);
      expect(find.byKey(const Key('voice-confirm-sheet')), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-confirm-all-btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // 同名冲突弹窗由外壳回调弹出，点击合并后更新原记录压力并关闭确认框。
      expect(find.byKey(const Key('same-name-merge-btn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('same-name-merge-btn')));
      await tester.pumpAndSettle();

      expect(h.controller.mergedPressures.length, 1);
      expect(h.controller.mergedPressures.single.id, 'e-existing');
      expect(h.controller.mergedPressures.single.pressureMpa, 24);
      expect(find.byKey(const Key('voice-confirm-sheet')), findsNothing);
    });

    testWidgets('5 类意图分发：note -> Tab 0、ask -> Tab 2 自动发送、exit（指定/全员确认）、ignore -> 丢弃提示', (
      tester,
    ) async {
      var transcript = '';
      late ParseResult parsed;

      final h = _createHarness(
        initialEntries: <Entry>[
          _makeActiveEntry('e-1', '张三'),
          _makeActiveEntry('e-2', '李四'),
          _makeActiveEntry('e-3', '王五'),
        ],
        nextTranscript: () => transcript,
        nextParse: (_) => parsed,
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.shell);
      await tester.pumpAndSettle();

      // 1) note -> 自动记日志并切回 Tab 0。
      await tester.tap(find.byKey(ShellKeys.tabMonitor));
      await tester.pumpAndSettle();
      transcript = '东侧出水阵地已展开';
      parsed = ParseResult(action: 'none', intent: VoiceIntent.note, people: const []);
      await _longPressVoiceButton(tester);
      expect(h.controller.addedNotes, contains('东侧出水阵地已展开'));
      expect(_currentTab(tester), ShellVoiceBridge.commandTabIndex);

      // 2) ignore -> 在当前页丢弃并弹出提示，不跳转。
      await tester.tap(find.byKey(ShellKeys.tabMonitor));
      await tester.pumpAndSettle();
      transcript = '嗯嗯呃';
      parsed = ParseResult(action: 'none', intent: VoiceIntent.ignore, people: const []);
      await _longPressVoiceButton(tester);
      expect(_currentTab(tester), ShellVoiceBridge.monitorTabIndex);
      expect(find.byKey(const Key('voice-recording-overlay')), findsNothing);
      expect(find.text('未识别到有效指令，请重新录入'), findsOneWidget);

      // 3) exitNamed -> 批量标记指定人员出场并记撤离日志。
      transcript = '张三李四出火场';
      parsed = ParseResult(
        action: 'exit',
        intent: VoiceIntent.exit,
        people: <ParsePerson>[ParsePerson(name: '张三'), ParsePerson(name: '李四')],
      );
      await _longPressVoiceButton(tester);
      expect(h.controller.exitedIds, containsAll(<String>['e-1', 'e-2']));
      expect(h.controller.actionLogs.last.action, '出场');

      // 4) exitAll -> 弹出 VoiceExitConfirmSheet 二次确认后标记剩余人员王五离场。
      transcript = '全员撤离';
      parsed = ParseResult(action: 'exit', intent: VoiceIntent.exit, people: const []);
      await _longPressVoiceButton(tester);
      expect(find.byKey(const Key('voice-exit-confirm-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-exit-confirm-btn')));
      await tester.pumpAndSettle();
      expect(h.controller.exitedIds, contains('e-3'));

      // 5) ask -> 切至 Tab 2（智能辅助）并自动提交问题。
      transcript = '锂电池火灾如何处置';
      parsed = ParseResult(action: 'none', intent: VoiceIntent.ask, people: const []);
      await _longPressVoiceButton(tester);
      expect(_currentTab(tester), ShellVoiceBridge.copilotTabIndex);
      expect(h.controller.askedQuestions, contains('锂电池火灾如何处置'));
      expect(find.text('锂电池火灾如何处置'), findsOneWidget);
    });

    testWidgets('Tab 2（智能辅助）长按语音键走 Copilot 就地语音提问，不触发全局语音浮层', (
      tester,
    ) async {
      final h = _createHarness(
        nextTranscript: () => '不应调用全局语音',
        nextParse: (_) => ParseResult(
          action: 'none',
          intent: VoiceIntent.ignore,
          people: const [],
        ),
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(h.shell);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ShellKeys.tabCopilot));
      await tester.pumpAndSettle();
      expect(_currentTab(tester), ShellVoiceBridge.copilotTabIndex);

      await _longPressVoiceButton(
        tester,
        whileHeld: () async {
          expect(_currentTab(tester), ShellVoiceBridge.copilotTabIndex);
          expect(find.byKey(const Key('voice-recording-overlay')), findsNothing);
          expect(h.copilotAudio.startCalls, 1);
          expect(h.globalAudio.startCalls, 0);
        },
      );

      expect(h.copilotAudio.stopCalls, 1);
      expect(h.globalAudio.startCalls, 0);
      expect(h.controller.askedQuestions, contains('室内烟气层过低如何内攻'));
      expect(find.text('室内烟气层过低如何内攻'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
