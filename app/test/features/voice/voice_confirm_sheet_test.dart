import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/voice/state/voice_draft_person.dart';
import 'package:watchdog/features/voice/state/voice_session_types.dart';
import 'package:watchdog/features/voice/ui/voice_confirm_sheet.dart';
import 'package:watchdog/features/voice/ui/voice_exit_confirm_sheet.dart';

Widget _wrapApp(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 800),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
    ),
  );
}

class _StatefulConfirmHarness extends StatefulWidget {
  const _StatefulConfirmHarness({
    required this.initialDrafts,
    this.transcript,
    this.rosterNames = const <String>[],
    this.activeEntryNames = const <String>{},
    this.onConfirmAll,
    this.onContinueVoice,
    this.onRetry,
  });

  final List<VoiceDraftPerson> initialDrafts;
  final String? transcript;
  final List<String> rosterNames;
  final Set<String> activeEntryNames;
  final ValueChanged<List<VoiceDraftPerson>>? onConfirmAll;
  final VoidCallback? onContinueVoice;
  final VoidCallback? onRetry;

  @override
  State<_StatefulConfirmHarness> createState() => _StatefulConfirmHarnessState();
}

class _StatefulConfirmHarnessState extends State<_StatefulConfirmHarness> {
  late final List<VoiceDraftPerson> _drafts = List<VoiceDraftPerson>.of(
    widget.initialDrafts,
  );
  String? _inlineError;

  @override
  Widget build(BuildContext context) {
    return VoiceConfirmSheet(
      drafts: _drafts,
      calcParams: const VoiceCalcParams(cylinderVolL: 6.8, consumptionLpm: 80),
      transcript: widget.transcript,
      inlineError: _inlineError,
      rosterNames: widget.rosterNames,
      activeEntryNames: widget.activeEntryNames,
      onNameChanged: (int i, String v) => setState(() {
        _drafts[i] = _drafts[i].copyWith(name: v);
        _inlineError = null;
      }),
      onPressureChanged: (int i, String v) => setState(() {
        _drafts[i] = _drafts[i].copyWith(pressureText: v);
        _inlineError = null;
      }),
      onVolumeChanged: (int i, double v) => setState(() {
        _drafts[i] = _drafts[i].copyWith(volumeL: v);
        _inlineError = null;
      }),
      onRemoveAt: (int i) => setState(() {
        _drafts.removeAt(i);
        _inlineError = null;
      }),
      onConfirmAll: () {
        final problems = validateVoiceDrafts(_drafts);
        if (problems.isNotEmpty) {
          setState(() => _inlineError = problems.join('\n'));
          return;
        }
        widget.onConfirmAll?.call(List<VoiceDraftPerson>.of(_drafts));
      },
      onContinueVoice: () => widget.onContinueVoice?.call(),
      onRetry: () => widget.onRetry?.call(),
    );
  }
}

void main() {
  group('VoiceConfirmSheet 进场确认弹窗', () {
    testWidgets('多人布局展示全部人员卡片、转写条、可用时间预览与 >=56dp 主按钮', (tester) async {
      List<VoiceDraftPerson>? confirmed;
      await tester.pumpWidget(
        _wrapApp(
          _StatefulConfirmHarness(
            transcript: '张三20兆帕，李四22兆帕进场',
            initialDrafts: const [
              VoiceDraftPerson(id: 'd1', name: '张三', pressureText: '20'),
              VoiceDraftPerson(id: 'd2', name: '李四', pressureText: '22'),
            ],
            onConfirmAll: (drafts) => confirmed = drafts,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('voice-confirm-sheet')), findsOneWidget);
      expect(find.byKey(const Key('voice-person-card-0')), findsOneWidget);
      expect(find.byKey(const Key('voice-person-card-1')), findsOneWidget);
      expect(find.text('确认名单（2 人）：请下滑核对后一次性确认'), findsOneWidget);
      expect(find.text('全部确认进入火场（2 人）'), findsOneWidget);
      expect(find.text('可用时间 17 分钟'), findsOneWidget);
      expect(find.text('可用时间 19 分钟'), findsOneWidget);

      final primaryRect = tester.getRect(
        find.byKey(const Key('voice-confirm-all-btn')),
      );
      expect(primaryRect.height, greaterThanOrEqualTo(56));

      await tester.tap(find.byKey(const Key('voice-confirm-all-btn')));
      await tester.pump();
      expect(confirmed?.map((d) => d.name).toList(), ['张三', '李四']);
    });

    testWidgets('单人自适应布局展示单人标题与按钮，移除一人后从多人切换回单人', (tester) async {
      await tester.pumpWidget(
        _wrapApp(
          const _StatefulConfirmHarness(
            initialDrafts: [
              VoiceDraftPerson(id: 'd1', name: '张三', pressureText: '20'),
              VoiceDraftPerson(id: 'd2', name: '李四', pressureText: '22'),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('全部确认进入火场（2 人）'), findsOneWidget);

      await tester.tap(find.text('移除该人员').first);
      await tester.pump();

      expect(find.text('核对进场信息'), findsOneWidget);
      expect(find.text('确认进入火场，开始倒计时'), findsOneWidget);
      expect(find.byKey(const Key('voice-person-card-0')), findsOneWidget);
      expect(find.byKey(const Key('voice-person-card-1')), findsNothing);
      final nameField = tester.widget<TextField>(
        find.byKey(const Key('voice-person-name-0')),
      );
      expect(nameField.controller?.text, '李四');
    });

    testWidgets('缺压力时一次性列出全部校验错误，补填后消除错误并可提交', (tester) async {
      List<VoiceDraftPerson>? confirmed;
      await tester.pumpWidget(
        _wrapApp(
          _StatefulConfirmHarness(
            initialDrafts: const [
              VoiceDraftPerson(id: 'd1', name: '张三', pressureText: ''),
              VoiceDraftPerson(id: 'd2', name: '李四', pressureText: ''),
            ],
            onConfirmAll: (drafts) => confirmed = drafts,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('voice-confirm-all-btn')));
      await tester.pump();
      expect(find.textContaining('「张三」缺少气瓶压力'), findsOneWidget);
      expect(find.textContaining('「李四」缺少气瓶压力'), findsOneWidget);
      expect(confirmed, isNull);

      await tester.enterText(find.byKey(const Key('voice-person-pressure-0')), '20');
      await tester.enterText(find.byKey(const Key('voice-person-pressure-1')), '22');
      await tester.pump();
      expect(find.textContaining('缺少气瓶压力'), findsNothing);

      await tester.tap(find.byKey(const Key('voice-confirm-all-btn')));
      await tester.pump();
      expect(confirmed?.length, 2);
    });

    testWidgets('非名单姓名留空提示与名单建议芯片点击自动填充', (tester) async {
      await tester.pumpWidget(
        _wrapApp(
          const _StatefulConfirmHarness(
            rosterNames: ['张三', '李四', '王五'],
            initialDrafts: [
              VoiceDraftPerson(
                id: 'd1',
                name: '',
                sourceName: '赵某',
                pressureText: '20',
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('「赵某」不在名单内'), findsOneWidget);
      expect(find.text('名单建议'), findsOneWidget);

      await tester.tap(find.text('王五'));
      await tester.pump();

      final nameField = tester.widget<TextField>(
        find.byKey(const Key('voice-person-name-0')),
      );
      expect(nameField.controller?.text, '王五');
      expect(find.textContaining('不在名单内'), findsNothing);
    });

    testWidgets('在场同名提醒展示与 6.8L / 9L 容积芯片切换实时重算可用时间', (tester) async {
      await tester.pumpWidget(
        _wrapApp(
          const _StatefulConfirmHarness(
            activeEntryNames: {'张三'},
            initialDrafts: [
              VoiceDraftPerson(
                id: 'd1',
                name: '张三',
                pressureText: '20',
                volumeL: 6.8,
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('「张三」已在火场内'), findsOneWidget);
      expect(find.text('可用时间 17 分钟'), findsOneWidget);

      final chip9 = find.byKey(const Key('voice-person-vol-9'));
      expect(tester.getRect(chip9).height, greaterThanOrEqualTo(48));
      await tester.tap(chip9);
      await tester.pump();

      expect(find.text('可用时间 23 分钟'), findsOneWidget);
    });

    testWidgets('继续语音添加与重新语音输入按钮触发回调', (tester) async {
      var continued = 0;
      var retried = 0;
      await tester.pumpWidget(
        _wrapApp(
          _StatefulConfirmHarness(
            initialDrafts: const [
              VoiceDraftPerson(id: 'd1', name: '张三', pressureText: '20'),
            ],
            onContinueVoice: () => continued++,
            onRetry: () => retried++,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('voice-continue-record-btn')));
      await tester.tap(find.text('重新语音输入'));
      await tester.pump();

      expect(continued, 1);
      expect(retried, 1);
    });

    testWidgets('360dp 窄屏 + 130% 字号下进场确认弹窗零溢出且字段竖排可读', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 740),
              textScaler: TextScaler.linear(1.3),
              disableAnimations: true,
            ),
            child: const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: _StatefulConfirmHarness(
                  transcript: '张三20兆帕，李四22兆帕，钢瓶9升进入火场',
                  rosterNames: ['张三', '李四', '王五'],
                  activeEntryNames: {'张三'},
                  initialDrafts: [
                    VoiceDraftPerson(
                      id: 'd1',
                      name: '张三',
                      pressureText: '20',
                      volumeL: 9.0,
                    ),
                    VoiceDraftPerson(
                      id: 'd2',
                      name: '',
                      sourceName: '未知队员',
                      pressureText: '22',
                      volumeL: 9.0,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final nameRect = tester.getRect(
        find.byKey(const Key('voice-person-name-0')),
      );
      final pressureRect = tester.getRect(
        find.byKey(const Key('voice-person-pressure-0')),
      );
      expect(pressureRect.top, greaterThanOrEqualTo(nameRect.bottom));
      expect(
        tester.getRect(find.byKey(const Key('voice-confirm-all-btn'))).height,
        greaterThanOrEqualTo(56),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('VoiceExitConfirmSheet 离场二次确认弹窗', () {
    testWidgets('全员离场展示在场名单、语音原文与 >=56dp 危险确认按钮并回调确认/取消', (tester) async {
      var confirmed = 0;
      var cancelled = 0;
      await tester.pumpWidget(
        _wrapApp(
          VoiceExitConfirmSheet(
            entries: const [
              VoiceActiveEntry(id: 'e1', name: '张三', version: 1, pressureMpa: 20),
              VoiceActiveEntry(id: 'e2', name: '李四', version: 1, pressureMpa: 18),
            ],
            voiceText: '全体人员撤出火场',
            isAllExit: true,
            onConfirm: () => confirmed++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('全员离场确认'), findsOneWidget);
      expect(find.text('当前在场 2 人'), findsWidgets);
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('李四'), findsOneWidget);
      expect(find.text('“全体人员撤出火场”'), findsOneWidget);

      final confirmBtn = find.byKey(const Key('voice-exit-confirm-btn'));
      expect(tester.getRect(confirmBtn).height, greaterThanOrEqualTo(56));

      await tester.tap(confirmBtn);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(confirmed, 1);
      expect(cancelled, 1);
    });

    testWidgets('指定人员批量离场模式与 360dp @ 130% 零溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.dark),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(360, 700),
              textScaler: TextScaler.linear(1.3),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: VoiceExitConfirmSheet(
                  entries: [
                    VoiceActiveEntry(id: 'e1', name: '张三', version: 1),
                    VoiceActiveEntry(id: 'e2', name: '李四', version: 1),
                    VoiceActiveEntry(id: 'e3', name: '王五', version: 1),
                  ],
                  voiceText: '张三、李四、王五已撤离火场',
                  isAllExit: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('确认人员离场'), findsOneWidget);
      expect(find.text('批量离场'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('showVoiceExitConfirmSheet 模态弹出并正确返回 bool 结果', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => CommandButton(
                label: '打开',
                onPressed: () async {
                  result = await showVoiceExitConfirmSheet(
                    context: context,
                    entries: const [
                      VoiceActiveEntry(id: 'e1', name: '张三', version: 1),
                    ],
                    voiceText: '全员撤离',
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-exit-confirm-btn')));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });
  });
}
