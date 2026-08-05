import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/board_page.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';
import 'package:watchdog/theme/app_widgets.dart';

AppController _controllerWith(List<Entry> entries) {
  final c = AppController();
  c.entries = entries;
  return c;
}

Entry _entry({required String name, required int remainingMin}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final duration = 40;
  final remainingMs = remainingMin * 60000;
  return Entry(
    id: 'e-$name',
    name: name,
    pressureMpa: 20,
    durationMin: duration,
    entryAt: now - (duration * 60 - remainingMin) * 60000,
    exitAt: now + remainingMs,
    source: 'voice',
    rawText: null,
  );
}

void main() {
  testWidgets('board 空状态：亮色背景 + 语音引导', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: BoardPage(controller: _controllerWith([]), onGoVoice: () {}),
      ),
    ));
    expect(find.text('暂无人员在场'), findsOneWidget);
    expect(find.text('去语音录入'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, isNull);
    expect(Theme.of(tester.element(find.byType(BoardPage))).scaffoldBackgroundColor, AppColors.background);
  });

  testWidgets('人员卡片四种状态渲染且无溢出', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: BoardPage(
          controller: _controllerWith([
            _entry(name: '张伟', remainingMin: 30),
            _entry(name: '李娜', remainingMin: 8),
            _entry(name: '王强', remainingMin: 3),
            _entry(name: '赵磊', remainingMin: -2),
          ]),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 规范 5.1：按危险程度排序（超时 → 报警 → 注意 → 安全），安全卡片在列表末尾
    expect(find.text('超时'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('报警'), 200);
    expect(find.text('报警'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('注意'), 200);
    expect(find.text('注意'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('安全'), 200);
    expect(find.text('安全'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('状态颜色映射符合规范', (tester) async {
    expect(EntryStatus.of('normal').color, AppColors.safe);
    expect(EntryStatus.of('warn').color, AppColors.caution);
    expect(EntryStatus.of('alarm').color, AppColors.alarm);
    expect(EntryStatus.of('timeout').color, AppColors.timeout);
    expect(EntryStatus.of('normal').fg, AppColors.textPrimary);
    expect(EntryStatus.of('alarm').fg, AppColors.onStatus);
  });
}
