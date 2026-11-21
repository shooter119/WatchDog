import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/features/voice/data/models/voice_parse.dart';
import 'package:watchdog/features/voice/state/voice_draft_person.dart';
import 'package:watchdog/features/voice/state/voice_intent_router.dart';

class _RouterHarness {
  _RouterHarness({
    List<VoiceActiveEntry>? activeEntries,
    this.sameNameChoice,
    this.confirmAllExitResult = true,
    this.throwOnNote = false,
    this.throwOnActionLog = false,
    this.conflictOnCreateName,
  }) : activeEntries = List<VoiceActiveEntry>.of(
         activeEntries ?? const <VoiceActiveEntry>[],
       );

  final List<VoiceActiveEntry> activeEntries;
  VoiceSameNameChoice? sameNameChoice;
  bool confirmAllExitResult;
  bool throwOnNote;
  bool throwOnActionLog;
  String? conflictOnCreateName;

  final List<String> createdNames = <String>[];
  final List<String> createdOpIds = <String>[];
  final List<String> mergedIds = <String>[];
  final List<String> exitedIds = <String>[];
  final List<Map<String, dynamic>> actionLogs = <Map<String, dynamic>>[];
  final List<String> routedNotes = <String>[];
  final List<String> routedAsks = <String>[];
  final List<String> spoken = <String>[];
  final List<String> messages = <String>[];
  final List<String> callOrder = <String>[];
  int entryConfirmedCount = 0;
  int noActiveNotifyCount = 0;
  int flushCount = 0;

  VoiceIntentRouter build() => VoiceIntentRouter(
    activeEntriesProvider: () => List<VoiceActiveEntry>.unmodifiable(activeEntries),
    onCreateEntry: ({
      required String name,
      required double pressureMpa,
      required double volumeL,
      String? rawText,
      bool force = false,
      String? opId,
    }) async {
      if (conflictOnCreateName == name) {
        throw VoiceEntryConflictException(
          VoiceActiveEntry(
            id: 'conflict-$name',
            name: name,
            version: 3,
            pressureMpa: 20,
          ),
        );
      }
      createdNames.add(name);
      if (opId != null) createdOpIds.add(opId);
    },
    onMergeEntryPressure: ({
      required String id,
      required int expectedVersion,
      required double pressureMpa,
      String? opId,
    }) async {
      mergedIds.add(id);
    },
    onMarkExited: ({
      required String id,
      required int expectedVersion,
      String? opId,
    }) async {
      exitedIds.add(id);
    },
    onResolveSameName: (existing, pressureMpa) async => sameNameChoice,
    onWriteActionLog: ({
      required List<String> names,
      required String action,
      Map<String, double>? pressuresMpa,
      required String category,
      required String opId,
    }) async {
      callOrder.add('action_log');
      if (throwOnActionLog) throw StateError('log write failed');
      actionLogs.add(<String, dynamic>{
        'names': names,
        'action': action,
        'pressures': pressuresMpa,
        'category': category,
        'opId': opId,
      });
    },
    onRouteNote: (text) async {
      if (throwOnNote) throw StateError('network down');
      routedNotes.add(text);
    },
    onRouteAsk: (text) => routedAsks.add(text),
    onConfirmAllExit: (active, voiceText) async => confirmAllExitResult,
    onNotifyNoActiveEntriesForAllExit: () async => noActiveNotifyCount++,
    onEntryConfirmed: () {
      callOrder.add('entry_confirmed');
      entryConfirmedCount++;
    },
    onSpeak: (text) => spoken.add(text),
    onShowMessage: (msg, {Duration duration = const Duration(seconds: 2)}) =>
        messages.add(msg),
    onFlushOpLogs: () => flushCount++,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('VoiceIntentRouter 5 类意图路由与进出场事务', () {
    test('5 类意图分类：entryConfirm / entryEmpty / exitNamed / exitAll / note / ask / ignore', () {
      final router = _RouterHarness().build();
      expect(
        router.classify(
          ParseResult(
            intent: VoiceIntent.entry,
            action: 'enter',
            people: const [ParsePerson(name: '张三', pressureMpa: 20)],
          ),
        ),
        VoiceRouteType.entryConfirm,
      );
      expect(
        router.classify(
          ParseResult(intent: VoiceIntent.entry, action: 'enter', people: const []),
        ),
        VoiceRouteType.entryEmpty,
      );
      expect(
        router.classify(
          ParseResult(
            intent: VoiceIntent.exit,
            action: 'exit',
            people: const [ParsePerson(name: '张三')],
          ),
        ),
        VoiceRouteType.exitNamed,
      );
      expect(
        router.classify(
          ParseResult(intent: VoiceIntent.exit, action: 'exit', people: const []),
        ),
        VoiceRouteType.exitAll,
      );
      expect(
        router.classify(
          ParseResult(intent: VoiceIntent.note, action: 'unknown', people: const []),
        ),
        VoiceRouteType.note,
      );
      expect(
        router.classify(
          ParseResult(intent: VoiceIntent.ask, action: 'unknown', people: const []),
        ),
        VoiceRouteType.ask,
      );
      expect(
        router.classify(
          ParseResult(intent: VoiceIntent.ignore, action: 'unknown', people: const []),
        ),
        VoiceRouteType.ignore,
      );
    });

    test('note / ask / ignore / entryEmpty 分发与日志失败可见反馈', () async {
      final h = _RouterHarness();
      final router = h.build();

      final noteOk = await router.routeParsed(
        text: '二楼东侧出水控火',
        parsed: ParseResult(
          intent: VoiceIntent.note,
          action: 'unknown',
          people: const [],
        ),
      );
      expect(noteOk.type, VoiceRouteType.note);
      expect(noteOk.noteSaved, isTrue);
      expect(h.routedNotes, ['二楼东侧出水控火']);

      final askOut = await router.routeParsed(
        text: '液化石油气泄漏怎么办',
        parsed: ParseResult(
          intent: VoiceIntent.ask,
          action: 'unknown',
          people: const [],
        ),
      );
      expect(askOut.type, VoiceRouteType.ask);
      expect(h.routedAsks, ['液化石油气泄漏怎么办']);

      final ignoreOut = await router.routeParsed(
        text: '喂测试',
        parsed: ParseResult(
          intent: VoiceIntent.ignore,
          action: 'unknown',
          people: const [],
        ),
      );
      expect(ignoreOut.type, VoiceRouteType.ignore);
      expect(ignoreOut.errorMessage, '未识别到有效指令，请重新录入');

      final emptyEntry = await router.routeParsed(
        text: '准备进入火场',
        parsed: ParseResult(
          intent: VoiceIntent.entry,
          action: 'enter',
          people: const [],
        ),
      );
      expect(emptyEntry.type, VoiceRouteType.entryEmpty);
      expect(emptyEntry.errorMessage, contains('未识别到进场人员姓名'));

      final failing = _RouterHarness(throwOnNote: true);
      final noteFail = await failing.build().routeParsed(
        text: '水带爆裂',
        parsed: ParseResult(
          intent: VoiceIntent.note,
          action: 'unknown',
          people: const [],
        ),
      );
      expect(noteFail.noteSaved, isFalse);
      expect(failing.messages.single, contains('记日志失败'));
    });

    test('指定人员批量退场：在场人员离场并写撤离日志，不在场人员返回未找到提示', () async {
      final h = _RouterHarness(
        activeEntries: const [
          VoiceActiveEntry(id: 'e-1', name: '张三', version: 2, pressureMpa: 18),
        ],
      );
      final res = await h.build().executeNamedExit(['张三', '李四'], opId: 'op-1');

      expect(h.exitedIds, ['e-1']);
      expect(res.exitedNames, ['张三']);
      expect(res.notFoundNames, ['李四']);
      expect(res.errorMessage, '未找到在场人员「李四」');
      expect(h.actionLogs.single['category'], '撤离');
      expect(h.actionLogs.single['action'], '出场');
      expect(h.spoken.single, '张三 已登记出火场');
      expect(h.flushCount, 1);
    });

    test('全员离场：无人时提示、取消时不操作、确认后全员离场并写撤离日志', () async {
      final emptyH = _RouterHarness();
      final emptyRes = await emptyH.build().executeAllExit('全员撤离', opId: 'op-0');
      expect(emptyRes.noActiveEntries, isTrue);
      expect(emptyH.noActiveNotifyCount, 1);

      final cancelH = _RouterHarness(
        activeEntries: const [
          VoiceActiveEntry(id: 'e-1', name: '张三', version: 1),
        ],
        confirmAllExitResult: false,
      );
      final cancelRes = await cancelH.build().executeAllExit('全员撤离', opId: 'op-1');
      expect(cancelRes.cancelled, isTrue);
      expect(cancelH.exitedIds, isEmpty);
      expect(cancelH.messages, contains('已取消全员离场'));

      final okH = _RouterHarness(
        activeEntries: const [
          VoiceActiveEntry(id: 'e-1', name: '张三', version: 1),
          VoiceActiveEntry(id: 'e-2', name: '李四', version: 2),
        ],
        confirmAllExitResult: true,
      );
      final okRes = await okH.build().executeAllExit('全体撤出火场', opId: 'op-2');
      expect(okH.exitedIds, ['e-1', 'e-2']);
      expect(okRes.exitedNames, ['张三', '李四']);
      expect(okH.actionLogs.single['category'], '撤离');
      expect(okH.spoken.single, '全体人员已登记离场');
    });

    test('confirmAllEntries 缺压力先整体校验拦截且不发起创建', () async {
      final h = _RouterHarness();
      final res = await h.build().confirmAllEntries(const [
        VoiceDraftPerson(id: '1', name: '张三', pressureText: ''),
        VoiceDraftPerson(id: '2', name: '李四', pressureText: ''),
      ]);

      expect(res.allDone, isFalse);
      expect(res.validationErrors.length, 2);
      expect(res.validationErrors[0], contains('「张三」缺少气瓶压力'));
      expect(res.validationErrors[1], contains('「李四」缺少气瓶压力'));
      expect(h.createdNames, isEmpty);
    });

    test('confirmAllEntries 全量成功：ASCII opId、先跳监控再写部署日志与 TTS', () async {
      final h = _RouterHarness();
      final res = await h.build().confirmAllEntries(
        const [
          VoiceDraftPerson(id: '1', name: '张三', pressureText: '20', volumeL: 6.8),
          VoiceDraftPerson(id: '2', name: '李四', pressureText: '22', volumeL: 9.0),
        ],
        transcript: '张三20兆帕，李四22兆帕',
        opId: 'op-99',
      );

      expect(res.allDone, isTrue);
      expect(h.createdNames, ['张三', '李四']);
      // X-Op-Id 必须是纯 ASCII
      for (final id in h.createdOpIds) {
        expect(id.codeUnits.every((c) => c < 128), isTrue);
      }
      expect(h.entryConfirmedCount, 1);
      expect(h.callOrder, ['entry_confirmed', 'action_log']);
      expect(h.actionLogs.single['category'], '部署');
      expect(h.actionLogs.single['pressures'], {'张三': 20.0, '李四': 22.0});
      expect(h.spoken.single, '张三、李四，已开始倒计时');
    });

    test('confirmAllEntries 同名冲突回调：merge 合并压力、force 提示区分并中断保留未提交草稿', () async {
      final mergeH = _RouterHarness(
        activeEntries: const [
          VoiceActiveEntry(id: 'e-z', name: '张三', version: 4, pressureMpa: 18),
        ],
        sameNameChoice: VoiceSameNameChoice.merge,
      );
      final mergeRes = await mergeH.build().confirmAllEntries(const [
        VoiceDraftPerson(id: '1', name: '张三', pressureText: '24'),
      ]);
      expect(mergeRes.allDone, isTrue);
      expect(mergeH.mergedIds, ['e-z']);
      expect(mergeH.createdNames, isEmpty);

      final forceH = _RouterHarness(
        conflictOnCreateName: '张三',
        sameNameChoice: VoiceSameNameChoice.force,
      );
      final forceRes = await forceH.build().confirmAllEntries(const [
        VoiceDraftPerson(id: '1', name: '张三', pressureText: '20'),
        VoiceDraftPerson(id: '2', name: '李四', pressureText: '22'),
      ]);
      expect(forceRes.allDone, isFalse);
      expect(forceRes.keptDrafts.map((d) => d.name).toList(), ['张三', '李四']);
      expect(forceRes.errorMessage, contains('区分同名人员'));
    });

    test('confirmAllEntries 火场日志写入失败不回滚已成功的进场登记', () async {
      final h = _RouterHarness(throwOnActionLog: true);
      final res = await h.build().confirmAllEntries(const [
        VoiceDraftPerson(id: '1', name: '张三', pressureText: '20'),
      ]);

      expect(res.allDone, isTrue);
      expect(h.createdNames, ['张三']);
      expect(res.actionLogError, isNotNull);
      expect(h.messages.last, contains('火场日志写入失败'));
    });
  });
}
