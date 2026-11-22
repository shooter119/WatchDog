import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/data/models/incident.dart';
import 'package:watchdog/features/incident/data/models/incident_force.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_action_sheets.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_basic_info_sheet.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_force_edit_sheet.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_level_sheet.dart';
import 'package:watchdog/features/incident/ui/widgets/incident_category_chip.dart';
import 'package:watchdog/features/incident/ui/widgets/incident_category_style.dart';
import 'package:watchdog/features/incident/ui/widgets/incident_situation_card.dart';

Widget _wrap(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: w!,
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  final fixedNow = DateTime(2026, 11, 13, 14, 30);

  group('IncidentCategoryStyle 与 IncidentCardViewModel', () {
    test('classify 按显式字段与关键词归类且默认火灾扑救', () {
      expect(IncidentCategoryStyle.classify(), DsIncidentCategory.fire);
      expect(
        IncidentCategoryStyle.classify(category: '一级火灾扑救'),
        DsIncidentCategory.fire,
      );
      expect(
        IncidentCategoryStyle.classify(category: '二级抢险救援'),
        DsIncidentCategory.rescue,
      );
      expect(
        IncidentCategoryStyle.classify(category: '社会救助'),
        DsIncidentCategory.aid,
      );
      expect(
        IncidentCategoryStyle.classify(situation: '电梯困人请求开锁协助'),
        DsIncidentCategory.aid,
      );
      expect(
        IncidentCategoryStyle.classify(situation: '高速路段货车侧翻漏油'),
        DsIncidentCategory.rescue,
      );
    });

    test('清洗冗余省市区前缀与重复区县并在 title 等于地址时提炼事件名', () {
      final createdAt = DateTime(2026, 11, 13, 9, 5).millisecondsSinceEpoch;
      final incident = Incident(
        id: 'clean-1',
        number: '2026-11-13-02',
        title: '示例省示例市示例县示例县示范路18号',
        info: const <String, dynamic>{
          'location': '示例省示例市示例县示例县示范路18号',
          'original_category': '二级火灾扑救',
          'specific_type': '居民住宅',
          'situation': '二级火灾扑救 · 示范小区居民楼冒烟，暂无人员被困 · 官方状态: 到场',
        },
        status: 'active',
        createdAt: createdAt,
        lastActivityAt: createdAt,
      );

      final vm = IncidentCardViewModel.fromIncident(incident, now: fixedNow);
      expect(vm.category, DsIncidentCategory.fire);
      expect(vm.locationText, '示例县示范路18号');
      expect(vm.hasRealLocation, isTrue);
      expect(vm.eventTitle, '示范小区居民楼冒烟');
      expect(vm.timeText, '今日 09:05');
      expect(vm.officialStatus, '到场');
      expect(vm.isTerminalStatus, isFalse);
      expect(vm.extraNotes.any((String s) => s.contains('示范小区居民楼冒烟')), isFalse);
    });

    test('时间格式化覆盖今日/昨日/当年/跨年/缺省与 4 级地址兜底链', () {
      final yesterdayMs = DateTime(2026, 11, 12, 8, 9).millisecondsSinceEpoch;
      final sameYearMs = DateTime(2026, 5, 4, 21, 7).millisecondsSinceEpoch;
      final prevYearMs = DateTime(2025, 12, 31, 23, 59).millisecondsSinceEpoch;

      expect(
        IncidentCardViewModel.formatIncidentTime(
          Incident(
            id: 't1',
            number: 'n',
            status: 'active',
            createdAt: yesterdayMs,
            lastActivityAt: yesterdayMs,
          ),
          now: fixedNow,
        ),
        '昨日 08:09',
      );
      expect(
        IncidentCardViewModel.formatIncidentTime(
          Incident(
            id: 't2',
            number: 'n',
            status: 'active',
            createdAt: sameYearMs,
            lastActivityAt: sameYearMs,
          ),
          now: fixedNow,
        ),
        '05-04 21:07',
      );
      expect(
        IncidentCardViewModel.formatIncidentTime(
          Incident(
            id: 't3',
            number: 'n',
            status: 'active',
            createdAt: prevYearMs,
            lastActivityAt: prevYearMs,
          ),
          now: fixedNow,
        ),
        '2025-12-31 23:59',
      );
      expect(
        IncidentCardViewModel.formatIncidentTime(
          const Incident(
            id: 't4',
            number: 'n',
            status: 'active',
            createdAt: 0,
            lastActivityAt: 0,
          ),
          now: fixedNow,
        ),
        '时间待补充',
      );
      expect(
        IncidentCardViewModel.fromIncident(
          const Incident(
            id: 'loc-4',
            number: 'n',
            status: 'active',
            createdAt: 0,
            lastActivityAt: 0,
            info: <String, dynamic>{'crime_address': '示范路4号'},
          ),
          now: fixedNow,
        ).locationText,
        '示范路4号',
      );
    });
  });

  group('IncidentSituationCard', () {
    testWidgets('基于 IncidentHeader 渲染，折叠记忆与新增在场人员自动收起生效', (
      WidgetTester tester,
    ) async {
      final memory = <String, bool>{'inc-mem': true};
      const incident = Incident(
        id: 'inc-mem',
        number: '2026-11-13-01',
        title: '示范商场火警',
        info: <String, dynamic>{
          'location': '示范路88号',
          'original_category': '一级火灾扑救',
          'incident_status': '出动',
        },
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );

      await tester.pumpWidget(
        _wrap(
          IncidentSituationCard(
            incident: incident,
            hasActiveEntries: false,
            loadExpanded: (String id) async => memory[id],
            saveExpanded: (String id, bool v) async => memory[id] = v,
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(IncidentHeader), findsOneWidget);
      expect(find.byKey(const Key('incident-card-details')), findsOneWidget);
      expect(find.text('力量待登记'), findsOneWidget);
      final pendingPill = tester.widget<StatusPill>(
        find.widgetWithText(StatusPill, '力量待登记'),
      );
      expect(pendingPill.status, DsStatus.neutral);

      // 新增在场人员时自动收起并落盘 false
      await tester.pumpWidget(
        _wrap(
          IncidentSituationCard(
            incident: incident,
            hasActiveEntries: true,
            loadExpanded: (String id) async => memory[id],
            saveExpanded: (String id, bool v) async => memory[id] = v,
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('incident-card-details')), findsNothing);
      expect(memory['inc-mem'], isFalse);
    });

    testWidgets('终态归队隐藏力量待登记，已登记力量时折叠态展示紧凑力量摘要', (
      WidgetTester tester,
    ) async {
      const incident = Incident(
        id: 'inc-force',
        number: '2026-11-13-05',
        title: '示范厂房抢险',
        info: <String, dynamic>{
          'location': '示例工业园3号',
          'original_category': '二级抢险救援',
          'incident_status': '归队',
        },
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );
      const forces = <IncidentForce>[
        IncidentForce(
          id: 'f1',
          incidentId: 'inc-force',
          stationName: '示例路站',
          vehicleCount: 2,
          personnelCount: 6,
          createdAt: 1,
          updatedAt: 1,
          version: 1,
        ),
      ];

      await tester.pumpWidget(
        _wrap(
          IncidentSituationCard(
            incident: incident,
            forces: forces,
            initialExpanded: false,
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('incident-category-badge-rescue')),
        findsNothing,
      );
      expect(find.byIcon(DsIcons.categoryRescue), findsOneWidget);
      expect(find.byIcon(DsIcons.locationPin), findsOneWidget);
      expect(find.byKey(const Key('incident-collapsed-forces')), findsOneWidget);
      expect(find.text('示例路站 2车6人'), findsOneWidget);

      await tester.tap(find.byKey(const Key('incident-collapse-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident-card-details')), findsOneWidget);
      expect(find.text('力量待登记'), findsNothing);
      expect(find.text('1支队伍'), findsNWidgets(2));
    });

    testWidgets('更多菜单支持改名、退出与归档二次确认 Key(incident-archive-confirm-btn)', (
      WidgetTester tester,
    ) async {
      String? renamedTo;
      var exited = 0;
      var archived = 0;
      const incident = Incident(
        id: 'inc-actions',
        number: '2026-11-13-06',
        title: '示范仓库火灾',
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );

      await tester.pumpWidget(
        _wrap(
          IncidentSituationCard(
            incident: incident,
            initialExpanded: false,
            onRename: (String title) async => renamedTo = title,
            onExit: () async => exited++,
            onArchive: () async => archived++,
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 改名
      await tester.tap(find.byKey(const Key('incident-more-menu-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rename-incident')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('incident-rename-field')),
        '示范物流园火灾',
      );
      await tester.tap(find.byKey(const Key('incident-rename-save-btn')));
      await tester.pumpAndSettle();
      expect(renamedTo, '示范物流园火灾');

      // 2. 退出取消不生效，确认后生效
      await tester.tap(find.byKey(const Key('incident-more-menu-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exit-incident-menu-item')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(exited, 0);

      await tester.tap(find.byKey(const Key('incident-more-menu-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exit-incident-menu-item')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-exit-confirm-btn')));
      await tester.pumpAndSettle();
      expect(exited, 1);

      // 3. 归档二次确认
      await tester.tap(find.byKey(const Key('incident-more-menu-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('archive-incident-menu-item')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('incident-archive-confirm-btn')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('incident-archive-confirm-btn')));
      await tester.pumpAndSettle();
      expect(archived, 1);
    });

    testWidgets('showIncidentLevelSheet 切换三大类芯片联动更新级别并返回结果', (
      WidgetTester tester,
    ) async {
      IncidentLevelResult? result;
      const incident = Incident(
        id: 'inc-level',
        number: '2026-11-13-09',
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
        info: <String, dynamic>{'original_category': '一级火灾扑救'},
      );

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () async {
                result = await showIncidentLevelSheet(
                  context,
                  incident: incident,
                );
              },
              child: const Text('警情调整'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('警情调整'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-category-chip-aid')));
      await tester.pumpAndSettle();
      expect(find.text('二级社会救助'), findsOneWidget);

      await tester.tap(find.text('二级社会救助'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('incident-level-save')));
      await tester.pumpAndSettle();

      expect(result?.level, '二级社会救助');
      expect(result?.disasterCategory, 'aid');
    });

    testWidgets('showIncidentForceEditSheet 校验数字范围并支持同站合并弹窗', (
      WidgetTester tester,
    ) async {
      IncidentForceEditResult? editResult;
      IncidentForce? mergeTarget;

      await tester.pumpWidget(
        _wrap(
          Column(
            children: <Widget>[
              Builder(
                builder: (BuildContext context) => ElevatedButton(
                  onPressed: () async {
                    editResult = await showIncidentForceEditSheet(
                      context,
                      stationNames: const <String>['示例路站', '和平站'],
                    );
                  },
                  child: const Text('登记力量'),
                ),
              ),
              Builder(
                builder: (BuildContext context) => ElevatedButton(
                  onPressed: () async {
                    mergeTarget = await showIncidentForceMergeSheet(
                      context,
                      source: const IncidentForce(
                        id: 'f-src',
                        incidentId: 'inc-1',
                        stationName: '示例路中队',
                        vehicleCount: 1,
                        personnelCount: 5,
                        createdAt: 1,
                        updatedAt: 1,
                        version: 1,
                      ),
                      candidates: const <IncidentForce>[
                        IncidentForce(
                          id: 'f-dst',
                          incidentId: 'inc-1',
                          stationName: '示例路站',
                          vehicleCount: 2,
                          personnelCount: 8,
                          createdAt: 1,
                          updatedAt: 1,
                          version: 2,
                        ),
                      ],
                      targetName: '示例路站',
                      vehiclesText: '3',
                      peopleText: '12',
                    );
                  },
                  child: const Text('合并力量'),
                ),
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.text('登记力量'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('force-vehicles-field')), '1000');
      await tester.tap(find.byKey(const Key('force-edit-save-btn')));
      await tester.pump();
      expect(find.textContaining('0至999'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('force-vehicles-field')), '2');
      await tester.enterText(find.byKey(const Key('force-people-field')), '10');
      await tester.tap(find.byKey(const Key('force-edit-save-btn')));
      await tester.pumpAndSettle();
      expect(editResult?.stationName, '示例路站');
      expect(editResult?.vehicleCount, 2);
      expect(editResult?.personnelCount, 10);

      await tester.tap(find.text('合并力量'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不累加原数量'), findsOneWidget);
      await tester.tap(find.byKey(const Key('force-merge-confirm-btn')));
      await tester.pumpAndSettle();
      expect(mergeTarget?.id, 'f-dst');
    });

    testWidgets('360dp @ 130% 大字号展开态势卡与防孤字文本零溢出', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const incident = Incident(
        id: 'inc-scale',
        number: '2026-11-13-11',
        title: '示例县示例镇示例示范新村三组十二号民房火灾',
        info: <String, dynamic>{
          'location': '示例县示范路188号',
          'original_category': '二级火灾扑救',
          'incident_status': '到场',
        },
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );

      await tester.pumpWidget(
        _wrap(
          Column(
            children: <Widget>[
              IncidentSituationCard(
                incident: incident,
                initialExpanded: true,
                forces: const <IncidentForce>[
                  IncidentForce(
                    id: 'f1',
                    incidentId: 'inc-scale',
                    stationName: '示例路消防救援站',
                    vehicleCount: 3,
                    personnelCount: 15,
                    createdAt: 1,
                    updatedAt: 1,
                    version: 1,
                  ),
                ],
                now: fixedNow,
              ),
              const IncidentAntiOrphanText(
                text: '示例县示例镇示例示范新村三组十二号',
                style: TextStyle(fontSize: 13),
                maxLines: 2,
              ),
            ],
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('showIncidentRenameSheet 保存退出动画期间不触发控制器提前释放异常', (
      WidgetTester tester,
    ) async {
      String? renamed;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => CommandButton(
                label: '打开改名',
                onPressed: () async {
                  renamed = await showIncidentRenameSheet(
                    ctx,
                    initialTitle: '旧警情名称',
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开改名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('incident-rename-field')),
        '示例工业园厂房火灾',
      );
      await tester.tap(find.byKey(const Key('incident-rename-save-btn')));
      // 逐帧步进退出动画，验证退场期间零异常
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();
      expect(renamed, '示例工业园厂房火灾');
      expect(tester.takeException(), isNull);
    });

    testWidgets('配置 onEditBasicInfo 时菜单显示「编辑警情信息」并回传名称/地点与坐标', (
      WidgetTester tester,
    ) async {
      IncidentBasicInfoResult? saved;
      const incident = Incident(
        id: 'inc-edit-info',
        number: '2026-11-22-01',
        title: '自建示例警情',
        info: <String, dynamic>{'location': '示例路12号'},
        status: 'active',
        createdAt: 1,
        lastActivityAt: 1,
      );

      await tester.pumpWidget(
        _wrap(
          IncidentSituationCard(
            incident: incident,
            initialExpanded: false,
            onEditBasicInfo: (IncidentBasicInfoResult result) async =>
                saved = result,
            onLocateAddress: () async => const IncidentLocatedAddress(
              address: '示例大道188号北门',
              latitude: 31.25,
              longitude: 121.48,
            ),
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-more-menu-btn')));
      await tester.pumpAndSettle();
      expect(find.text('编辑警情信息'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rename-incident')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('incident-rename-field')))
            .controller
            ?.text,
        '自建示例警情',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('incident-location-field')))
            .controller
            ?.text,
        '示例路12号',
      );

      await tester.enterText(
        find.byKey(const Key('incident-rename-field')),
        '示范物流仓库火情',
      );
      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-rename-save-btn')));
      await tester.pumpAndSettle();

      expect(saved?.title, '示范物流仓库火情');
      expect(saved?.location, '示例大道188号北门');
      expect(saved?.latitude, 31.25);
      expect(saved?.longitude, 121.48);
    });
  });
}
