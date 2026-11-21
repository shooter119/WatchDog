import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/app/shell/command_app_shell.dart';
import 'package:watchdog/app/shell/onboarding_assembly.dart';
import 'package:watchdog/app/shell/shell_keys.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/auth/data/models/admin_login.dart';
import 'package:watchdog/features/auth/ui/admin_scanner_page.dart';
import 'package:watchdog/features/auth/ui/onboarding_flow_shell.dart';
import 'package:watchdog/features/auth/ui/unit_auth_page.dart';
import 'package:watchdog/features/incident/ui/incident_import_page.dart';
import 'package:watchdog/features/incident/ui/incident_picker_page.dart';
import 'package:watchdog/features/monitor/ui/monitor_stats_screen.dart';
import 'package:watchdog/features/roster/ui/archived_incidents_page.dart';
import 'package:watchdog/features/roster/ui/login_devices_page.dart';
import 'package:watchdog/features/roster/ui/member_review_page.dart';
import 'package:watchdog/features/roster/ui/offline_review_page.dart';
import 'package:watchdog/features/roster/ui/roster_page.dart';
import 'package:watchdog/features/settings/ui/about_page.dart';
import 'package:watchdog/features/settings/ui/op_log_page.dart';
import 'package:watchdog/features/settings/ui/profile_hub_page.dart';
import 'package:watchdog/features/settings/ui/watermark_settings_page.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/services/system_pip.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_palette.dart';

class _WiringFakeController extends AppController {
  _WiringFakeController({
    bool needsAuth = false,
    bool needsIncident = false,
    bool guest = false,
    Incident? incident,
    List<Incident> activeList = const <Incident>[],
    ApiClient? fakeApi,
  }) : _needsAuth = needsAuth,
       _needsIncident = needsIncident,
       _guest = guest {
    currentIncident = incident;
    activeIncidents = List<Incident>.of(activeList);
    api = fakeApi;
  }

  bool _needsAuth;
  bool _needsIncident;
  final bool _guest;
  int authenticateCalls = 0;
  int enterWithoutIncidentCalls = 0;
  int refreshAdminCalls = 0;

  @override
  bool get needsAuthentication => _needsAuth;

  @override
  bool get needsIncidentSelection => _needsIncident;

  @override
  bool get isGuest => _guest;

  @override
  bool get canReadKeySites => !_needsAuth && !_guest && api != null;

  @override
  bool get requiresIncident => !_guest && currentIncident == null;

  @override
  Future<void> init() async {}

  @override
  Future<void> checkUpdateSilently() async {}

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<void> refreshNow() async {}

  @override
  Future<void> loadRoster() async {}

  @override
  Future<void> refreshPendingMembersCount() async {}

  @override
  Future<void> refreshAdminCapability() async {
    refreshAdminCalls++;
  }

  @override
  Future<List<Incident>> archivedIncidents() async => const <Incident>[];

  @override
  Future<void> fetchExternalIncidents({bool forceRefresh = false}) async {}

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => const <ChatMessage>[];

  @override
  Future<void> authenticate({
    required String unitName,
    required String realName,
    required String unitCode,
  }) async {
    authenticateCalls++;
    _needsAuth = false;
    _needsIncident = true;
    notifyListeners();
  }

  @override
  void enterWithoutIncident() {
    enterWithoutIncidentCalls++;
    _needsIncident = false;
    notifyListeners();
  }
}

Incident _sampleIncident() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return Incident(
    id: 'inc-wire-1',
    number: '20261122-009',
    title: '示例县示例路仓储火警',
    status: 'active',
    createdAt: now - 300000,
    lastActivityAt: now,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'unit_id': 'unit-demo',
      'unit_name': '示例市消防救援大队',
      'unit_code': '1001',
      'real_name': '张三',
      'user_role': 'admin',
    });
    ThemeController.instance.resetForTest();
    SystemPip.resetForTesting();
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
    SystemPip.resetForTesting();
  });

  group('M3f ProfileHubAssembly Tab 3 全量接线验证', () {
    testWidgets('Tab 3 挂载 DS v3.0 ProfileHubPage、主题瞬切并导航至核心二级页', (
      tester,
    ) async {
      final fakeApi = ApiClient(
        baseUrl: 'http://127.0.0.1:9',
        incidentId: 'inc-wire-1',
        unitId: 'unit-demo',
        sessionToken: 'demo-token',
      );
      addTearDown(fakeApi.dispose);

      final controller = _WiringFakeController(
        incident: _sampleIncident(),
        fakeApi: fakeApi,
      )
        ..canReviewMembers = true
        ..pendingMemberCount = 2
        ..offlineReviewCount = 1
        ..adminCapability = const AdminCapability(
          memberId: 'm-1',
          name: '张三',
          unitName: '示例市消防救援大队',
          unitRole: 'admin',
          role: 'unit_admin',
        );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        CommandAppShell(
          controller: controller,
          enableStartupSideEffects: false,
          commandTabBuilder: (_) => const SizedBox(key: Key('stub-cmd')),
          monitorTabBuilder: (_) => const SizedBox(key: Key('stub-mon')),
          copilotTabBuilder: (_) => const SizedBox(key: Key('stub-cop')),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ShellKeys.tabMine));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileHubPage), findsOneWidget);
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('示例市消防救援大队'), findsOneWidget);

      Future<void> openAndVerify<T extends Widget>(Finder target) async {
        await tester.scrollUntilVisible(
          target,
          240,
          scrollable: find.descendant(
            of: find.byType(ProfileHubPage),
            matching: find.byType(Scrollable),
          ).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(find.byType(T), findsOneWidget);
        Navigator.of(tester.element(find.byType(T))).pop();
        await tester.pumpAndSettle();
      }

      // 1. 现场与采集 -> DS v3.0 水印设置
      await openAndVerify<WatermarkSettingsPage>(find.text('水印设置'));
      // 2. 队站管理 -> DS v3.0 入队审批 & 人员与热词
      await openAndVerify<MemberReviewPage>(find.text('入队审批'));
      await openAndVerify<RosterPage>(find.text('人员与热词'));
      // 3. 数据与记录 -> DS v3.0 归档警情 / 数据统计 / 操作日志
      await openAndVerify<ArchivedIncidentsPage>(find.text('归档警情'));
      await openAndVerify<MonitorStatsScreen>(find.text('数据统计'));
      await openAndVerify<OpLogPage>(find.text('操作日志'));
      // 4. 界面外观 -> 切换暗曜主题，ThemeController 同步生效
      final nightFinder = find.text('暗曜');
      await tester.scrollUntilVisible(
        nightFinder,
        240,
        scrollable: find.descendant(
          of: find.byType(ProfileHubPage),
          matching: find.byType(Scrollable),
        ).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(nightFinder);
      await tester.pumpAndSettle();
      expect(ThemeController.instance.currentId, AppPalette.nightTactical.id);
      // 5. 连接与维护 -> DS v3.0 关于项目
      await openAndVerify<AboutPage>(find.text('关于项目'));

      // 6. 身份 Hero -> 滚回顶部验证离线待核对、登录设备与扫码页路由
      await tester.scrollUntilVisible(
        find.byKey(const Key('identity-hero')),
        -400,
        scrollable: find.descendant(
          of: find.byType(ProfileHubPage),
          matching: find.byType(Scrollable),
        ).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-scan')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.refreshAdminCalls, 1);
      expect(find.byType(AdminScannerPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(AdminScannerPage))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('1 条离线记录待核对'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(OfflineReviewPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(OfflineReviewPage))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('user-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录设备'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LoginDevicesPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(LoginDevicesPage))).pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('M3g OnboardingAssembly 启动门禁与警情导入全量接线验证', () {
    testWidgets('启动门禁串联 OnboardingFlowShell(UnitAuthPage -> IncidentPickerPage) 并解锁外壳', (
      tester,
    ) async {
      final fakeApi = ApiClient(
        baseUrl: 'http://127.0.0.1:9',
        incidentId: '',
        unitId: 'unit-demo',
        sessionToken: 'demo-token',
      );
      addTearDown(fakeApi.dispose);

      final active = _sampleIncident();
      final controller = _WiringFakeController(
        needsAuth: true,
        needsIncident: true,
        activeList: <Incident>[active],
        fakeApi: fakeApi,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        CommandAppShell(
          controller: controller,
          enableStartupSideEffects: false,
          commandTabBuilder: (_) => const Center(
            child: Text('指挥台已解锁', key: Key('unlocked-command-tab')),
          ),
          monitorTabBuilder: (_) => const SizedBox.shrink(),
          copilotTabBuilder: (_) => const SizedBox.shrink(),
          mineTabBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();

      // 步骤 1：未认证 -> DS v3.0 OnboardingFlowShell + UnitAuthPage
      expect(find.byKey(ShellKeys.startupGate), findsOneWidget);
      expect(find.byType(OnboardingFlowShell), findsOneWidget);
      expect(find.byType(UnitAuthPage), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('auth-unit-name')),
        '示例市消防救援大队',
      );
      await tester.enterText(
        find.byKey(const Key('auth-real-name')),
        '张三',
      );
      await tester.enterText(
        find.byKey(const Key('auth-unit-code')),
        '1001',
      );
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();

      // 步骤 2：认证通过 -> 无缝切换至 DS v3.0 IncidentPickerPage
      expect(controller.authenticateCalls, 1);
      expect(find.byType(IncidentPickerPage), findsOneWidget);
      expect(find.text('示例县示例路仓储火警'), findsOneWidget);

      // 步骤 3：免选警情直接进入 App -> 解锁门禁回到 Tab 0
      await tester.tap(find.text('直接进入 App'));
      await tester.pumpAndSettle();

      expect(controller.enterWithoutIncidentCalls, 1);
      expect(find.byKey(ShellKeys.startupGate), findsNothing);
      expect(find.byKey(const Key('unlocked-command-tab')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OnboardingAssembly.openIncidentImport 打开 DS v3.0 IncidentImportPage', (
      tester,
    ) async {
      final fakeApi = ApiClient(
        baseUrl: 'http://127.0.0.1:9',
        incidentId: 'inc-wire-1',
        unitId: 'unit-demo',
        sessionToken: 'demo-token',
      );
      addTearDown(fakeApi.dispose);

      final controller = _WiringFakeController(
        incident: _sampleIncident(),
        fakeApi: fakeApi,
      );
      addTearDown(controller.dispose);

      final assembly = OnboardingAssembly(
        controller: controller,
        onSelectTab: (_) {},
        onShowMessage: (_, {Duration duration = const Duration(seconds: 2)}) {},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(Brightness.light),
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: ElevatedButton(
                key: const Key('open-import-btn'),
                onPressed: () => assembly.openIncidentImport(ctx),
                child: const Text('打开导入'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-import-btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(IncidentImportPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360dp @ 130% 昼白与暗曜下 Tab 3 与启动引导门禁零溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final controller = _WiringFakeController(
        needsAuth: true,
        needsIncident: true,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        CommandAppShell(
          controller: controller,
          enableStartupSideEffects: false,
          commandTabBuilder: (_) => const SizedBox.shrink(),
          monitorTabBuilder: (_) => const SizedBox.shrink(),
          copilotTabBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UnitAuthPage), findsOneWidget);
      expect(tester.takeException(), isNull);

      ThemeController.instance.select(AppPalette.nightTactical);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
