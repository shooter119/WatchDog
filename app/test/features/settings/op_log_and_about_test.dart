import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/app/app_version.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/settings/ui/about_page.dart';
import 'package:watchdog/features/settings/ui/op_log_page.dart';
import 'package:watchdog/services/op_log_service.dart';

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildCommandTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final svc = OpLogService.instance;
    await svc.init();
    await svc.setSyncEnabled(true);
    await svc.clearLocal();
  });

  group('OpLogPage 操作日志', () {
    testWidgets('按 opId 分组展示步骤，支持展开查看、脱敏检查、手动上传与同步开关', (tester) async {
      final svc = OpLogService.instance;
      svc.record('op-test-1', 'record_start', '开始录音');
      svc.record(
        'op-test-1',
        'transcribe_ok',
        '转写成功',
        data: <String, dynamic>{'text': '张伟，20兆帕'},
      );
      svc.record(
        'op-test-1',
        'op_end',
        '本次操作结束',
        data: <String, dynamic>{'outcome': 'enter_ok'},
      );
      svc.record('op-test-2', 'record_start', '开始录音');
      svc.record('op-test-2', 'transcribe_err', '转写失败: 服务器错误', level: 'error');
      expect(svc.logs.any((e) => e.data?['text_length'] == 7), isTrue);

      var flushCalls = 0;
      await _pumpPage(
        tester,
        OpLogPage(onFlush: () async => flushCalls++),
      );

      // 最新操作在前；步骤默认折叠
      expect(find.text('转写失败: 服务器错误'), findsWidgets);
      expect(find.text('进场登记完成'), findsOneWidget);
      expect(find.text('同步到服务器'), findsOneWidget);
      expect(find.text('transcribe_err').hitTestable(), findsNothing);

      // 展开 op-test-2 查看步骤
      await tester.tap(find.text('转写失败: 服务器错误').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('transcribe_err').hitTestable(), findsOneWidget);
      expect(find.text('record_start').hitTestable(), findsOneWidget);

      // 展开 op-test-1，原始语音文本经过脱敏不出现
      await tester.tap(find.text('进场登记完成'));
      await tester.pumpAndSettle();
      expect(find.textContaining('张伟，20兆帕'), findsNothing);

      // 手动点击立即同步触发回调
      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();
      expect(flushCalls, 1);

      // 关闭同步开关
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(svc.syncEnabled, isFalse);
      expect(find.text('已关闭，仅保存在本机'), findsOneWidget);
    });

    testWidgets('清空本地日志通过 CommandSheet 二次确认执行', (tester) async {
      final svc = OpLogService.instance;
      svc.record('op-clear-1', 'op_end', '结束', data: <String, dynamic>{'outcome': 'exit_ok'});

      await _pumpPage(tester, const OpLogPage());
      expect(find.text('出火场登记完成'), findsOneWidget);

      final clearBtn = find.byKey(const Key('op-log-clear-button'));
      await tester.scrollUntilVisible(clearBtn, 200);
      await tester.tap(clearBtn);
      await tester.pumpAndSettle();

      // 弹出 CommandSheet 二次确认，点取消不清空
      expect(find.byType(CommandSheet), findsOneWidget);
      expect(find.text('清空本地操作日志？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(svc.logs, isNotEmpty);

      // 再次点击并确认清空
      await tester.tap(clearBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.pump();
      expect(svc.logs, isEmpty);
      expect(find.text('暂无操作日志'), findsOneWidget);
    });

    testWidgets('360dp @ 130% 字号下空态零溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpPage(tester, const OpLogPage(), textScale: 1.3);
      expect(find.text('暂无操作日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AboutPage 关于我们', () {
    testWidgets('展示 README 核心章节与功能分组，且不显示任何版本号', (tester) async {
      await _pumpPage(tester, const AboutPage());

      expect(find.text('关于我们'), findsOneWidget);
      expect(find.text('火场智控'), findsOneWidget);
      expect(find.text('为什么会有这个 App'), findsOneWidget);
      expect(find.textContaining('v$appVersion'), findsNothing);
      expect(find.textContaining(appVersion), findsNothing);

      final list = find.byType(ListView).first;
      for (final section in const <String>[
        '它是怎么用的',
        '它能帮你什么',
        '现场记录',
        '监控与报警',
        '资料与协同',
        '设置与数据',
        '场景',
        '关于这个项目',
        '开源许可',
        '后端部署',
      ]) {
        for (var i = 0; i < 30 && find.text(section).evaluate().isEmpty; i++) {
          await tester.drag(list, const Offset(0, -240));
          await tester.pumpAndSettle();
        }
        expect(find.text(section), findsOneWidget, reason: '缺少章节: $section');
        expect(find.textContaining(appVersion), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
