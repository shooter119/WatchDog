import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/app/app_version.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/settings/state/settings_store.dart';
import 'package:watchdog/features/settings/ui/about_page.dart';
import 'package:watchdog/features/settings/ui/component_gallery_page.dart';
import 'package:watchdog/features/settings/ui/op_log_page.dart';
import 'package:watchdog/features/settings/ui/profile_hub_page.dart';
import 'package:watchdog/features/settings/ui/settings_widgets.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/services/theme_controller.dart';

Future<void> _scrollToVisible(
  WidgetTester tester,
  Finder scrollable,
  Finder target, {
  int maxDrags = 28,
}) async {
  for (var i = 0; i < maxDrags; i++) {
    if (target.evaluate().length == 1) {
      final targetRect = tester.getRect(target);
      final viewportRect = tester.getRect(scrollable);
      if (targetRect.top >= viewportRect.top &&
          targetRect.bottom <= viewportRect.bottom) {
        break;
      }
    }
    await tester.drag(scrollable, const Offset(0, -280));
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
}

Future<void> _pumpProfileHub(
  WidgetTester tester,
  SettingsStore store, {
  ProfileHubRoutes routes = const ProfileHubRoutes(),
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
      home: ProfileHubPage(store: store, routes: routes),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const screenChannel = MethodChannel('watchdog/screen');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeController.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, (_) async => null);
  });

  tearDown(() {
    ThemeController.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, null);
  });

  group('ProfileHubPage 设置与入口', () {
    testWidgets('发现新版本时更新卡片保持单行标题', (tester) async {
      final store = SettingsStore(
        gateway: const SettingsGateway(isDebugMode: false),
        update: const SettingsUpdateSnapshot(
          pendingUpdate: UpdateInfo(tagName: 'v9.9.9+99', apkUrl: 'x'),
          checkDone: true,
        ),
      );
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('版本更新'));
      expect(find.textContaining('发现新版本 v9.9.9+99'), findsNothing);
      expect(find.text('版本更新'), findsOneWidget);
      expect(find.textContaining('有新版 · v$appVersion'), findsOneWidget);
    });

    testWidgets('测试版环境不显示有新版红点与提示', (tester) async {
      final store = SettingsStore(
        gateway: const SettingsGateway(isDebugMode: true),
        update: const SettingsUpdateSnapshot(
          pendingUpdate: UpdateInfo(tagName: 'v9.9.9+99', apkUrl: 'x'),
          checkDone: true,
        ),
      );
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('版本更新'));
      expect(find.textContaining('有新版'), findsNothing);
      expect(find.text('测试版 · v$appVersion'), findsOneWidget);
    });

    testWidgets('检查失败时更新卡片仍保持单行入口', (tester) async {
      final store = SettingsStore(
        update: const SettingsUpdateSnapshot(
          checkDone: true,
          checkError: '更新服务不可达（HTTP 0）',
        ),
      );
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('版本更新'));
      expect(find.text('检查更新失败，点击重试'), findsNothing);
      expect(find.text('版本更新'), findsOneWidget);
    });

    testWidgets('渲染各分区，无保存按钮', (tester) async {
      final store = SettingsStore();
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      final list = find.byType(ListView).first;
      expect(find.text('我的身份'), findsNothing);
      expect(find.text('未选择单位'), findsOneWidget);
      for (final label in const <String>[
        '人员与热词',
        '单位常用队伍',
        '归档警情',
        '数据统计',
        '操作日志',
        '计算参数',
        '语音识别',
        '提醒方式',
        '服务连接',
        '版本更新',
        '关于项目',
      ]) {
        await _scrollToVisible(tester, list, find.text(label));
        expect(find.text(label), findsOneWidget);
      }
      await _scrollToVisible(tester, list, find.textContaining('v$appVersion'));
      expect(find.textContaining('v$appVersion'), findsOneWidget);
      expect(find.text('保存设置'), findsNothing);
    });

    testWidgets('水印设置与单位常用队伍使用统一的 SurfaceCard 与语义图标', (tester) async {
      final store = SettingsStore();
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      final list = find.byType(ListView).first;

      await _scrollToVisible(tester, list, find.text('水印设置'));
      expect(
        find.ancestor(of: find.text('水印设置'), matching: find.byType(SurfaceCard)),
        findsOneWidget,
      );
      expect(find.byIcon(DsIcons.watermark), findsOneWidget);

      await _scrollToVisible(tester, list, find.text('单位常用队伍'));
      expect(
        find.ancestor(of: find.text('单位常用队伍'), matching: find.byType(SurfaceCard)),
        findsOneWidget,
      );
      expect(find.byIcon(DsIcons.stations), findsOneWidget);
    });

    testWidgets('身份 Hero 合并展示，普通设置项保持统一行高且同组共卡', (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);

      final store = SettingsStore();
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);

      expect(find.byType(CircleAvatar), findsNothing);
      expect(find.text('未认证'), findsNWidgets(2));
      const labels = <String>['水印设置', '人员与热词'];
      double? commonHeight;
      for (final label in labels) {
        final row = find.byKey(Key('settings-row-$label'));
        final height = tester.getSize(row).height;
        expect(height, inInclusiveRange(48, 72));
        commonHeight ??= height;
        expect(height, closeTo(commonHeight, 0.5));
      }

      final rosterCard = tester.widget<SurfaceCard>(
        find.ancestor(of: find.text('人员与热词'), matching: find.byType(SurfaceCard)).first,
      );
      final stationsCard = tester.widget<SurfaceCard>(
        find.ancestor(of: find.text('单位常用队伍'), matching: find.byType(SurfaceCard)).first,
      );
      expect(rosterCard, same(stationsCard));
    });

    testWidgets('分组、操作日志图标区分与状态摘要实时联动', (tester) async {
      final store = SettingsStore();
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      expect(find.byKey(const Key('profile-connection-pill')), findsNothing);
      final list = find.byType(ListView).first;

      for (final section in const <String>[
        '现场与采集',
        '队站管理',
        '数据与记录',
        '系统设置',
        '界面外观',
        '连接与维护',
      ]) {
        await _scrollToVisible(tester, list, find.text(section));
        expect(find.text(section), findsOneWidget);
      }

      await _scrollToVisible(tester, list, find.text('操作日志'));
      expect(find.byIcon(DsIcons.opLog), findsOneWidget);

      await _scrollToVisible(tester, list, find.text('计算参数'));
      expect(find.text('6.8L · 10/5分'), findsOneWidget);
      await _scrollToVisible(tester, list, find.text('语音识别'));
      expect(find.text('在线识别'), findsOneWidget);
      await _scrollToVisible(tester, list, find.text('提醒方式'));
      expect(find.text('播报·警报·常亮'), findsOneWidget);

      await tester.tap(find.text('提醒方式'));
      await tester.pumpAndSettle();
      await _scrollToVisible(tester, list, find.text('屏幕常亮'));
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text('屏幕常亮'), matching: find.byType(SwitchListTile)),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('播报·警报'), findsOneWidget);

      await _scrollToVisible(tester, list, find.text('服务连接'));
      final serverRow = find.byKey(const Key('settings-row-服务连接'));
      expect(find.descendant(of: serverRow, matching: find.text('已连接')), findsOneWidget);
    });

    testWidgets('顶部连接状态胶囊可直达并展开服务连接，失败态同步重试', (tester) async {
      var retried = 0;
      final store = SettingsStore(
        gateway: SettingsGateway(onRefreshNow: () async => retried++),
        connection: const SettingsConnectionSnapshot(syncError: '连接超时'),
      );
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      expect(find.text('服务器地址'), findsNothing);

      await tester.tap(find.byKey(const Key('profile-connection-pill')));
      await tester.pumpAndSettle();
      expect(retried, 1);
      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('服务器地址'));
      expect(find.text('服务器地址'), findsOneWidget);
    });

    testWidgets('修改文本框后失焦即自动保存并更新 Settings.modifiedAt', (tester) async {
      var fixedNow = 1700000001000;
      final store = SettingsStore(
        gateway: SettingsGateway(nowMs: () => fixedNow),
      );
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);

      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('计算参数'));
      await tester.tap(find.text('计算参数'));
      await tester.pumpAndSettle();
      await _scrollToVisible(tester, list, find.widgetWithText(TextField, '消耗率'));
      await tester.enterText(find.widgetWithText(TextField, '消耗率'), '55');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(await Settings.consumptionLpm, 55);
      expect(await Settings.modifiedAt, fixedNow);
    });

    testWidgets('非法参数校验失败时不落盘并展示保存失败状态', (tester) async {
      final store = SettingsStore();
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);

      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('计算参数'));
      await tester.tap(find.text('计算参数'));
      await tester.pumpAndSettle();
      await _scrollToVisible(tester, list, find.widgetWithText(TextField, '消耗率'));
      await tester.enterText(find.widgetWithText(TextField, '消耗率'), '0');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(store.saveState, SettingsSaveState.failed);
      expect(await Settings.consumptionLpm, 80);
      expect(await Settings.modifiedAt, 0);
    });

    testWidgets('切换开关立即保存；切换外观与后台值守不写 Settings.modifiedAt', (tester) async {
      final selectedThemes = <String>[];
      final store = SettingsStore(
        gateway: SettingsGateway(
          nowMs: () => 1700000002000,
          onSelectThemeId: selectedThemes.add,
          requestNotificationPermission: () async {},
          requestIgnoreBatteryOptimization: () async {},
        ),
      );
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);

      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('暗曜'));
      await tester.tap(find.byKey(const Key('theme-option-night-tactical')));
      await tester.pumpAndSettle();
      expect(selectedThemes, <String>['night-tactical']);
      expect(await Settings.modifiedAt, 0);

      // 回到提醒方式验证耗电提示与开关即时保存
      await tester.drag(list, const Offset(0, 600));
      await tester.pumpAndSettle();
      await _scrollToVisible(tester, list, find.text('提醒方式'));
      await tester.tap(find.text('提醒方式'));
      await tester.pumpAndSettle();
      expect(
        find.text('开启时请允许通知与电池白名单；值守约每小时 1%–2% 电量，建议仅在处置期间开启。'),
        findsOneWidget,
      );

      await _scrollToVisible(tester, list, find.text('后台值守模式'));
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text('后台值守模式'), matching: find.byType(SwitchListTile)),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(await Settings.keepAliveEnabled, isTrue);
      expect(await Settings.modifiedAt, 0);

      await _scrollToVisible(tester, list, find.text('屏幕常亮'));
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text('屏幕常亮'), matching: find.byType(SwitchListTile)),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(await Settings.keepScreenOn, isFalse);
      expect(await Settings.modifiedAt, 1700000002000);
    });

    testWidgets('游客模式与管理员权限门禁及退出单位二次确认', (tester) async {
      var leftUnit = 0;
      var openedScan = 0;
      var openedVideo = 0;
      var openedReview = 0;

      // 1) 游客模式
      final guestStore = SettingsStore(
        gateway: SettingsGateway(onLeaveUnit: () async => leftUnit++),
        identity: const SettingsIdentitySnapshot(isGuest: true),
        connection: const SettingsConnectionSnapshot(isGuest: true),
      );
      addTearDown(guestStore.dispose);
      await _pumpProfileHub(tester, guestStore);
      expect(find.text('游客模式'), findsOneWidget);
      expect(find.text('未选择单位'), findsOneWidget);
      expect(find.text('游客'), findsOneWidget);
      expect(find.text('加入单位'), findsOneWidget);
      expect(find.byKey(const Key('admin-scan')), findsNothing);
      expect(find.byKey(const Key('video-resource-settings')), findsNothing);
      expect(find.byIcon(Icons.arrow_forward_outlined), findsNothing);

      // 2) 管理员身份 + 扫码 + 视频源管理 + 入队审批 + 退出单位二次确认
      final adminStore = SettingsStore(
        gateway: SettingsGateway(
          onLeaveUnit: () async => leftUnit++,
          onRefreshAndCheckAdminScan: () async => true,
        ),
        identity: const SettingsIdentitySnapshot(
          authenticated: true,
          realName: '张三',
          unitName: '示例县消防救援大队',
          userRole: 'admin',
          canScanAdmin: true,
          canReviewMembers: true,
          pendingMemberCount: 2,
          offlineReviewCount: 1,
          hasApi: true,
        ),
      );
      addTearDown(adminStore.dispose);
      await _pumpProfileHub(
        tester,
        adminStore,
        routes: ProfileHubRoutes(
          onOpenAdminScanner: (_) async => openedScan++,
          onOpenVideoAdmin: (_) async => openedVideo++,
          onOpenMemberReview: (_) async => openedReview++,
        ),
      );

      expect(find.text('张三'), findsOneWidget);
      expect(find.text('管理员'), findsOneWidget);
      expect(find.text('示例县消防救援大队'), findsOneWidget);
      expect(find.text('1 条离线记录待核对'), findsOneWidget);
      expect(find.byKey(const Key('admin-scan')), findsOneWidget);
      expect(find.byKey(const Key('video-resource-settings')), findsOneWidget);
      expect(find.text('入队审批'), findsOneWidget);

      await tester.tap(find.byKey(const Key('admin-scan')));
      await tester.pumpAndSettle();
      expect(openedScan, 1);

      await tester.tap(find.byKey(const Key('video-resource-settings')));
      await tester.pumpAndSettle();
      expect(openedVideo, 1);

      await tester.tap(find.text('入队审批'));
      await tester.pumpAndSettle();
      expect(openedReview, 1);

      // 退出单位二次确认（先点菜单再确认 CommandSheet）
      await tester.tap(find.byKey(const Key('user-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出当前单位'));
      await tester.pumpAndSettle();
      expect(find.text('退出当前单位？'), findsOneWidget);
      expect(leftUnit, 0);
      await tester.tap(find.text('退出单位'));
      await tester.pumpAndSettle();
      expect(leftUnit, 1);
      expect(adminStore.identity.effectiveAuthenticated, isFalse);
    });

    testWidgets('操作日志、关于项目与调试组件画廊默认路由可进入', (tester) async {
      final store = SettingsStore();
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      final list = find.byType(ListView).first;

      await _scrollToVisible(tester, list, find.text('操作日志'));
      await tester.tap(find.text('操作日志'));
      await tester.pumpAndSettle();
      expect(find.byType(OpLogPage), findsOneWidget);
      expect(find.text('同步到服务器'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await _scrollToVisible(tester, list, find.text('关于项目'));
      await tester.tap(find.text('关于项目'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('为什么会有这个 App'), findsOneWidget);
      expect(find.textContaining('v$appVersion'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await _scrollToVisible(tester, list, find.text('UI 规范与组件画廊（调试）'));
      await tester.tap(find.text('UI 规范与组件画廊（调试）'));
      await tester.pumpAndSettle();
      expect(find.byType(ComponentGalleryPage), findsOneWidget);
      expect(find.text('Design System v3.0 预览'), findsOneWidget);
    });

    testWidgets('360dp @ 130% 与 320dp @ 200% 大字号全页滚动零溢出', (tester) async {
      for (final (width, scale) in const <(double, double)>[
        (360.0, 1.3),
        (320.0, 2.0),
      ]) {
        tester.view.physicalSize = Size(width * 2, 800 * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.reset);

        final store = SettingsStore(
          identity: const SettingsIdentitySnapshot(
            authenticated: true,
            realName: '消防救援一号安全员',
            unitName: '示例省示范市示例县消防救援大队示例路站',
            userRole: 'admin',
            canScanAdmin: true,
            canReviewMembers: true,
            pendingMemberCount: 3,
            offlineReviewCount: 2,
            hasApi: true,
          ),
        );
        addTearDown(store.dispose);
        await _pumpProfileHub(tester, store, textScale: scale);
        expect(tester.takeException(), isNull);

        final list = find.byType(ListView).first;
        for (var i = 0; i < 12; i++) {
          await tester.drag(list, const Offset(0, -240));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('离线模型未下载时关闭联网语音识别弹出提示并支持下载', (tester) async {
      var installed = false;
      var downloadCalls = 0;
      final store = SettingsStore(
        gateway: SettingsGateway(
          availableStorageBytes: () async => 512 * 1024 * 1024,
          localAsr: SettingsLocalAsrGateway(
            isModelInstalled: () async => installed,
            downloadModel: ({onProgress}) async {
              downloadCalls++;
              onProgress?.call(50, 100);
              installed = true;
            },
            removeModel: () async => installed = false,
          ),
        ),
      );
      addTearDown(store.dispose);
      await _pumpProfileHub(tester, store);
      final list = find.byType(ListView).first;
      await _scrollToVisible(tester, list, find.text('语音识别'));
      await tester.tap(find.text('语音识别'));
      await tester.pumpAndSettle();
      await _scrollToVisible(tester, list, find.text('联网语音识别'));

      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text('联网语音识别'), matching: find.byType(SwitchListTile)),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未下载本地语音模型'), findsOneWidget);
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(downloadCalls, 1);
      expect(store.asrCloudEnabled, isFalse);
      expect(store.modelInstalled, isTrue);
    });
  });

  group('SettingsWidgets 单元测试', () {
    testWidgets('SettingsSaveStatusBadge 三态渲染正确', (tester) async {
      for (final (state, text) in const <(SettingsSaveState, String?)>[
        (SettingsSaveState.idle, null),
        (SettingsSaveState.saving, '保存中'),
        (SettingsSaveState.saved, '已保存'),
        (SettingsSaveState.failed, '保存失败'),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildCommandTheme(Brightness.light),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: SettingsSaveStatusBadge(state: state),
              ),
            ),
          ),
        );
        if (text == null) {
          expect(find.byType(Text), findsNothing);
        } else {
          expect(find.text(text), findsOneWidget);
        }
      }
    });
  });
}
