import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_basic_info_sheet.dart';
import 'package:watchdog/features/incident/ui/sheets/incident_details_edit_sheet.dart';

Widget _wrapHost({
  required Widget child,
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  bool disableAnimations = true,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: w!,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('showIncidentCreateSheet', () {
    testWidgets('全项留空可直接确认创建，零摩擦保留默认编号模式', (WidgetTester tester) async {
      IncidentCreateDraft? draft;
      await tester.pumpWidget(
        _wrapHost(
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '新建警情',
              onPressed: () async {
                draft = await showIncidentCreateSheet(context);
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('新建警情'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-create-confirm-btn')));
      await tester.pumpAndSettle();

      expect(draft, isNotNull);
      expect(draft!.title, isEmpty);
      expect(draft!.location, isEmpty);
      expect(draft!.category, DsIncidentCategory.fire);
      expect(draft!.categoryExplicitlySelected, isFalse);
      expect(draft!.latitude, isNull);
      expect(draft!.longitude, isNull);
    });

    testWidgets('支持填写名称/地点、切换三大类以及一键定位回填和清除重置坐标', (
      WidgetTester tester,
    ) async {
      IncidentCreateDraft? draft;
      var locateCalls = 0;

      await tester.pumpWidget(
        _wrapHost(
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '新建警情',
              onPressed: () async {
                draft = await showIncidentCreateSheet(
                  context,
                  onLocateAddress: () async {
                    locateCalls++;
                    return const IncidentLocatedAddress(
                      address: '示例市示例区示范大道188号',
                      latitude: 31.2304,
                      longitude: 121.4737,
                    );
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('新建警情'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('incident-create-title-field')),
        '示例大道物流园抢险',
      );
      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();

      expect(locateCalls, 1);
      expect(find.text('示例市示例区示范大道188号'), findsOneWidget);
      expect(find.byKey(const Key('incident-locate-status')), findsOneWidget);

      // 清除地点后应同步清空坐标，再次定位后恢复
      await tester.tap(find.byTooltip('清除地点'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-create-category-rescue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-create-confirm-btn')));
      await tester.pumpAndSettle();

      expect(draft?.title, '示例大道物流园抢险');
      expect(draft?.location, '示例市示例区示范大道188号');
      expect(draft?.category, DsIncidentCategory.rescue);
      expect(draft?.categoryExplicitlySelected, isTrue);
      expect(draft?.latitude, 31.2304);
      expect(draft?.longitude, 121.4737);
    });

    testWidgets('定位失败提示清晰中文错误且不阻断手动输入保存', (WidgetTester tester) async {
      IncidentCreateDraft? draft;
      await tester.pumpWidget(
        _wrapHost(
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '新建警情',
              onPressed: () async {
                draft = await showIncidentCreateSheet(
                  context,
                  onLocateAddress: () async => const IncidentLocatedAddress(
                    errorMessage: '未授予位置权限，请在系统设置中开启或手动输入',
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('新建警情'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();
      expect(find.text('未授予位置权限，请在系统设置中开启或手动输入'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('incident-create-location-field')),
        '示例县示范路18号',
      );
      await tester.tap(find.byKey(const Key('incident-create-confirm-btn')));
      await tester.pumpAndSettle();

      expect(draft?.location, '示例县示范路18号');
      expect(draft?.latitude, isNull);
    });

    testWidgets('360dp @ 130% 大字号零溢出且退场动画期间不提前释放控制器', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      IncidentCreateDraft? draft;
      await tester.pumpWidget(
        _wrapHost(
          textScale: 1.3,
          disableAnimations: false,
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '打开新建',
              onPressed: () async {
                draft = await showIncidentCreateSheet(
                  context,
                  onLocateAddress: () async => const IncidentLocatedAddress(
                    address: '示例市示例区示范路1号',
                    latitude: 31.2,
                    longitude: 121.4,
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开新建'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('incident-create-title-field')),
        '示例工业园仓库火灾',
      );
      await tester.tap(find.byKey(const Key('incident-create-confirm-btn')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();

      expect(draft?.title, '示例工业园仓库火灾');
      expect(tester.takeException(), isNull);
    });
  });

  group('showIncidentBasicInfoSheet', () {
    testWidgets('回填初始名称与事发地点并支持一键定位更新后零异常退场', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      IncidentBasicInfoResult? result;
      await tester.pumpWidget(
        _wrapHost(
          textScale: 1.3,
          brightness: Brightness.dark,
          disableAnimations: false,
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '编辑警情',
              onPressed: () async {
                result = await showIncidentBasicInfoSheet(
                  context,
                  initialTitle: '旧名称',
                  initialLocation: '旧地址1号',
                  onLocateAddress: () async => const IncidentLocatedAddress(
                    address: '示例镇示范村66号',
                    latitude: 30.5,
                    longitude: 120.2,
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('编辑警情'));
      await tester.pumpAndSettle();

      expect(find.text('旧名称'), findsOneWidget);
      expect(find.text('旧地址1号'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('incident-rename-field')),
        '更新后火灾名称',
      );
      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident-rename-save-btn')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();

      expect(result?.title, '更新后火灾名称');
      expect(result?.location, '示例镇示范村66号');
      expect(result?.latitude, 30.5);
      expect(result?.longitude, 120.2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('一键定位回填后若人工改写事发地点，保存时旧定位坐标应失效置空', (
      WidgetTester tester,
    ) async {
      IncidentBasicInfoResult? result;
      await tester.pumpWidget(
        _wrapHost(
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '编辑警情',
              onPressed: () async {
                result = await showIncidentBasicInfoSheet(
                  context,
                  initialTitle: '警情A',
                  initialLocation: '示例路1号',
                  onLocateAddress: () async => const IncidentLocatedAddress(
                    address: '示例镇示范村66号',
                    latitude: 30.5,
                    longitude: 120.2,
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('编辑警情'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-locate-btn')));
      await tester.pumpAndSettle();
      expect(find.text('示例镇示范村66号'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('incident-location-field')),
        '手动修改示例街88号',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-rename-save-btn')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();

      expect(result?.location, '手动修改示例街88号');
      expect(result?.latitude, isNull);
      expect(result?.longitude, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('showIncidentDetailsEditSheet', () {
    testWidgets('原有经纬度且手动修改事发地点时显式返回 latitude/longitude=null', (
      WidgetTester tester,
    ) async {
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        _wrapHost(
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '修改资料',
              onPressed: () async {
                result = await showIncidentDetailsEditSheet(
                  context,
                  initialData: const <String, dynamic>{
                    'location': '示例路1号',
                    'event_summary': '厂房冒烟',
                    'latitude': '30.500000',
                    'longitude': '120.200000',
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('修改资料'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('incident-detail-field-location')),
        '手动改为示例街99号',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-details-edit-save-btn')));
      await tester.pumpAndSettle();

      expect(result?['location'], '手动改为示例街99号');
      expect(result?.containsKey('latitude'), isTrue);
      expect(result?.containsKey('longitude'), isTrue);
      expect(result?['latitude'], isNull);
      expect(result?['longitude'], isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仅修改非地点字段时不返回坐标清空字段', (WidgetTester tester) async {
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        _wrapHost(
          child: Builder(
            builder: (BuildContext context) => CommandButton(
              label: '修改资料',
              onPressed: () async {
                result = await showIncidentDetailsEditSheet(
                  context,
                  initialData: const <String, dynamic>{
                    'location': '示例路1号',
                    'event_summary': '厂房冒烟',
                    'latitude': '30.500000',
                    'longitude': '120.200000',
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('修改资料'));
      await tester.pumpAndSettle();

      final summaryFinder = find.byKey(
        const Key('incident-detail-field-event_summary'),
      );
      await tester.ensureVisible(summaryFinder);
      await tester.enterText(summaryFinder, '二楼仓库明火');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('incident-details-edit-save-btn')));
      await tester.pumpAndSettle();

      expect(result?['location'], '示例路1号');
      expect(result?['event_summary'], '二楼仓库明火');
      expect(result?.containsKey('latitude'), isFalse);
      expect(result?.containsKey('longitude'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
