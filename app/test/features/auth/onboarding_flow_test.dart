import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/auth/state/onboarding_flow_store.dart';
import 'package:watchdog/features/auth/ui/auth_ui_parts.dart';
import 'package:watchdog/features/auth/ui/onboarding_flow_shell.dart';
import 'package:watchdog/features/auth/ui/unit_auth_page.dart';
import 'package:watchdog/features/incident/ui/incident_picker_page.dart';
import 'package:watchdog/services/settings.dart';

Widget _wrapApp(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildCommandTheme(brightness),
    themeAnimationDuration: Duration.zero,
    builder: (BuildContext context, Widget? appChild) {
      final mq = MediaQuery.of(context);
      return MediaQuery(
        data: mq.copyWith(
          textScaler: TextScaler.linear(textScale),
          viewInsets: viewInsets,
          disableAnimations: true,
        ),
        child: appChild!,
      );
    },
    home: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Settings.clearPendingApplication();
  });

  group('M3g 启动引导全屏流程 (OnboardingFlowShell)', () {
    testWidgets('未认证态：空字段校验、密码显隐切换与正常认证后无缝切入警情选择槽位', (tester) async {
      await Settings.setUnitName('示例市消防救援支队');
      await Settings.setRealName('张三');

      var authRequired = true;
      late StateSetter hostSetState;
      String? authedUnit, authedName, authedCode;

      await tester.pumpWidget(
        _wrapApp(
          StatefulBuilder(
            builder: (context, setState) {
              hostSetState = setState;
              return OnboardingFlowShell(
                authenticationRequired: authRequired,
                pendingPollInterval: null,
                onAuthenticate: (unit, name, code) async {
                  authedUnit = unit;
                  authedName = name;
                  authedCode = code;
                  hostSetState(() => authRequired = false);
                },
                incidentPickerBuilder: (_) => const Scaffold(
                  body: Center(child: Text('模拟警情选择页')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 默认单位与姓名自动回填
      final unitField = tester.widget<TextField>(
        find.byKey(const Key('auth-unit-name')),
      );
      final nameField = tester.widget<TextField>(
        find.byKey(const Key('auth-real-name')),
      );
      expect(unitField.controller?.text, '示例市消防救援支队');
      expect(nameField.controller?.text, '张三');

      // 缺少验证码时拦截并提示
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auth-error')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('auth-error')),
          matching: find.text('请输入单位验证码'),
        ),
        findsOneWidget,
      );

      // 切换验证码显隐
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('auth-unit-code')))
            .obscureText,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('auth-code-visibility-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('auth-unit-code')))
            .obscureText,
        isFalse,
      );

      // 填写验证码后认证成功，无缝切换到警情选择槽位
      await tester.enterText(find.byKey(const Key('auth-unit-code')), '1001');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();

      expect(authedUnit, '示例市消防救援支队');
      expect(authedName, '张三');
      expect(authedCode, '1001');
      expect(find.text('模拟警情选择页'), findsOneWidget);
    });

    testWidgets('MEMBER_NOT_ALLOWED 带模糊建议：点选候选仅回填不自动提交，也支持仍要提交入队申请', (
      tester,
    ) async {
      var authCalls = 0;
      var applyCalls = 0;

      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            authenticationRequired: true,
            pendingPollInterval: null,
            onAuthenticate: (_, _, _) async {
              authCalls++;
              throw ApiException(
                '没有找到这个姓名',
                statusCode: 403,
                code: 'MEMBER_NOT_ALLOWED',
                suggestions: const <String>['张伟', '张卫'],
              );
            },
            onApply: (
              unit,
              name,
              code, {
              stationName,
              phone,
              applyReason,
            }) async {
              applyCalls++;
              return <String, dynamic>{'status': 'pending'};
            },
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('auth-unit-name')),
        '示例县消防救援大队',
      );
      await tester.enterText(find.byKey(const Key('auth-real-name')), '张微');
      await tester.enterText(find.byKey(const Key('auth-unit-code')), '1001');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();

      expect(authCalls, 1);
      expect(find.text('没有找到这个姓名'), findsOneWidget);
      expect(find.text('你要找的是不是：'), findsOneWidget);
      expect(find.text('张伟'), findsWidgets);
      expect(find.text('张卫'), findsWidgets);

      // 点选弹窗中的候选项：回填姓名且不自动提交
      await tester.tap(find.text('张伟').last);
      await tester.pumpAndSettle();
      final nameField = tester.widget<TextField>(
        find.byKey(const Key('auth-real-name')),
      );
      expect(nameField.controller?.text, '张伟');
      expect(authCalls, 1);
      expect(applyCalls, 0);

      // 再次点击认证，选择“仍要提交入队申请” -> 二次确认 -> 进入待审页
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍要提交入队申请'));
      await tester.pumpAndSettle();
      expect(find.text('未加入单位名单'), findsOneWidget);
      await tester.tap(find.text('提交入队申请'));
      await tester.pumpAndSettle();

      expect(applyCalls, 1);
      expect(find.text('入队申请审核中'), findsOneWidget);
    });

    testWidgets('MEMBER_ROSTER_ONLY 弹出仅名单申请面板并成功提交进入待审批页', (tester) async {
      String? appliedUnit, appliedName, appliedCode;

      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            authenticationRequired: true,
            pendingPollInterval: null,
            onAuthenticate: (_, _, _) async {
              throw ApiException(
                '该姓名还没有登录权限',
                statusCode: 403,
                code: 'MEMBER_ROSTER_ONLY',
              );
            },
            onApply: (
              unit,
              name,
              code, {
              stationName,
              phone,
              applyReason,
            }) async {
              appliedUnit = unit;
              appliedName = name;
              appliedCode = code;
              await Settings.setPendingApplication(
                unitName: unit,
                unitCode: code,
                realName: name,
              );
              return <String, dynamic>{'status': 'pending'};
            },
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('auth-unit-name')),
        '示例县消防救援大队',
      );
      await tester.enterText(find.byKey(const Key('auth-real-name')), '李四');
      await tester.enterText(find.byKey(const Key('auth-unit-code')), '1001');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();

      expect(find.text('该姓名还没有登录权限'), findsOneWidget);
      expect(find.textContaining('已在语音识别名单中，但还没有登录权限'), findsOneWidget);
      await tester.tap(find.text('提交入队申请'));
      await tester.pumpAndSettle();

      expect(appliedUnit, '示例县消防救援大队');
      expect(appliedName, '李四');
      expect(appliedCode, '1001');
      expect(find.text('入队申请审核中'), findsOneWidget);
      expect(find.text('示例县消防救援大队'), findsOneWidget);
      expect(find.text('李四'), findsOneWidget);
    });

    testWidgets('主动点击入队申请入口填写队站与电话并提交进入待审批页', (tester) async {
      String? submittedStation, submittedPhone, submittedReason;

      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            authenticationRequired: true,
            pendingPollInterval: null,
            onAuthenticate: (_, _, _) async {},
            onApply: (
              unit,
              name,
              code, {
              stationName,
              phone,
              applyReason,
            }) async {
              submittedStation = stationName;
              submittedPhone = phone;
              submittedReason = applyReason;
              await Settings.setPendingApplication(
                unitName: unit,
                unitCode: code,
                realName: name,
                stationName: stationName,
                phone: phone,
              );
              return <String, dynamic>{'status': 'pending'};
            },
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('auth-apply-membership')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apply-unit-name')),
        '示例市消防救援支队',
      );
      await tester.enterText(find.byKey(const Key('apply-real-name')), '王五');
      await tester.enterText(find.byKey(const Key('apply-unit-code')), '2026');
      await tester.enterText(
        find.byKey(const Key('apply-station-name')),
        '示例路消防救援站',
      );
      await tester.enterText(
        find.byKey(const Key('apply-phone')),
        '13800001111',
      );
      await tester.enterText(
        find.byKey(const Key('apply-reason')),
        '战斗一班新入职',
      );
      await tester.tap(find.byKey(const Key('apply-sheet-submit')));
      await tester.pumpAndSettle();

      expect(submittedStation, '示例路消防救援站');
      expect(submittedPhone, '13800001111');
      expect(submittedReason, '战斗一班新入职');
      expect(find.text('入队申请审核中'), findsOneWidget);
      expect(find.text('示例路消防救援站'), findsOneWidget);
      expect(find.text('13800001111'), findsOneWidget);
    });

    testWidgets('待审批页：冷启动恢复、手动检查未通过、切回前台静默刷新自动通过、以及撤销切换账号', (
      tester,
    ) async {
      await Settings.setPendingApplication(
        unitName: '示例县消防救援大队',
        unitCode: '1001',
        realName: '赵六',
        stationName: '示例路站',
      );

      var approveNow = false;
      var checkCalls = 0;
      var authRequired = true;
      late StateSetter hostSetState;

      await tester.pumpWidget(
        _wrapApp(
          StatefulBuilder(
            builder: (context, setState) {
              hostSetState = setState;
              return OnboardingFlowShell(
                authenticationRequired: authRequired,
                pendingPollInterval: null,
                onAuthenticate: (_, _, _) async {
                  checkCalls++;
                  if (!approveNow) {
                    throw ApiException(
                      '仍在审核中',
                      statusCode: 403,
                      code: 'MEMBER_APPLICATION_PENDING',
                    );
                  }
                  hostSetState(() => authRequired = false);
                },
                incidentPickerBuilder: (_) => const Scaffold(
                  body: Center(child: Text('审批通过已进警情页')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 冷启动直接进入待审批页
      expect(find.text('入队申请审核中'), findsOneWidget);
      expect(find.text('赵六'), findsOneWidget);

      // 手动点击检查：尚未审批提示
      await tester.tap(find.byKey(const Key('pending-check-status')));
      await tester.pumpAndSettle();
      expect(checkCalls, 1);
      expect(find.text('站长尚未审批，请稍候再试'), findsOneWidget);

      // 模拟后台审批通过，切回前台触发静默刷新
      approveNow = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(checkCalls, 2);
      expect(find.text('审批通过已进警情页'), findsOneWidget);
      expect(await Settings.pendingApplication, isNull);
    });

    testWidgets('待审批页：定时前台静默轮询在后台暂停、回前台恢复，且撤销申请返回认证页', (
      tester,
    ) async {
      await Settings.setPendingApplication(
        unitName: '示例县消防救援大队',
        unitCode: '1001',
        realName: '孙七',
      );
      var pollCount = 0;
      final store = OnboardingFlowStore(
        authenticationRequired: true,
        pendingPollInterval: const Duration(milliseconds: 120),
        onAuthenticate: (_, _, _) async {
          pollCount++;
          throw ApiException(
            '等待审批',
            statusCode: 403,
            code: 'MEMBER_APPLICATION_PENDING',
          );
        },
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            store: store,
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('入队申请审核中'), findsOneWidget);

      // 前台等待一次定时轮询触发
      await tester.pump(const Duration(milliseconds: 150));
      expect(pollCount, greaterThanOrEqualTo(1));

      // 切入后台后暂停轮询
      final pausedCount = pollCount;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 280));
      expect(pollCount, pausedCount);

      // 切回前台后立即恢复静默刷新
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(pollCount, greaterThan(pausedCount));

      // 点击撤销申请并返回单位认证页
      final cancelBtn = find.byKey(const Key('pending-cancel-app'));
      await tester.ensureVisible(cancelBtn);
      await tester.pumpAndSettle();
      await tester.tap(cancelBtn);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auth-unit-name')), findsOneWidget);
      expect(await Settings.pendingApplication, isNull);
    });

    testWidgets('待审批被驳回（MEMBER_APPLICATION_REJECTED）时清空待审并回到认证页提示', (
      tester,
    ) async {
      await Settings.setPendingApplication(
        unitName: '示例县消防救援大队',
        unitCode: '1001',
        realName: '吴九',
      );
      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            authenticationRequired: true,
            pendingPollInterval: null,
            onAuthenticate: (_, _, _) async {
              throw ApiException(
                '已被驳回',
                statusCode: 403,
                code: 'MEMBER_APPLICATION_REJECTED',
              );
            },
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('入队申请审核中'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pending-check-status')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('auth-unit-name')), findsOneWidget);
      expect(find.byKey(const Key('auth-error')), findsOneWidget);
      expect(find.textContaining('已被驳回'), findsOneWidget);
      expect(await Settings.pendingApplication, isNull);
    });

    testWidgets('游客模式入口在单位认证页与待审批页均可正常触发', (tester) async {
      var guestEntries = 0;

      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            authenticationRequired: true,
            pendingPollInterval: null,
            onEnterGuestMode: () async {
              guestEntries++;
            },
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('auth-guest-mode')));
      await tester.pumpAndSettle();
      expect(guestEntries, 1);

      // 待审批页游客模式入口
      await Settings.setPendingApplication(
        unitName: '示例县消防救援大队',
        unitCode: '1001',
        realName: '周八',
      );
      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            key: const ValueKey<String>('pending-guest-shell'),
            authenticationRequired: true,
            pendingPollInterval: null,
            onEnterGuestMode: () async {
              guestEntries++;
            },
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pending-guest-mode')));
      await tester.pumpAndSettle();
      expect(guestEntries, 2);
    });

    testWidgets('360dp 窄屏 + 130% 大字号零溢出，主操作按钮 >= 56dp（认证页 + 待审批页）', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            authenticationRequired: true,
            pendingPollInterval: null,
            onAuthenticate: (_, _, _) async {},
            onApply: (_, _, _, {stationName, phone, applyReason}) async =>
                <String, dynamic>{},
            onEnterGuestMode: () async {},
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final submitSize = tester.getSize(find.byKey(const Key('auth-submit')));
      expect(submitSize.height, greaterThanOrEqualTo(DsSizes.primaryAction));
      final guestSize = tester.getSize(
        find.byKey(const Key('auth-guest-mode')),
      );
      expect(guestSize.height, greaterThanOrEqualTo(DsSizes.primaryAction));

      // 验证待审批页同样 360dp @ 130% 零溢出且主按钮 >= 56dp
      await Settings.setPendingApplication(
        unitName: '示例省示例市示例县消防救援大队特勤一站',
        unitCode: '1001',
        realName: '示例队员长姓名测试',
        stationName: '示例路消防救援特勤一站',
        phone: '13800001111',
      );
      await tester.pumpWidget(
        _wrapApp(
          OnboardingFlowShell(
            key: const ValueKey<String>('pending-360-shell'),
            authenticationRequired: true,
            pendingPollInterval: null,
            onAuthenticate: (_, _, _) async {},
            onEnterGuestMode: () async {},
            incidentPickerBuilder: (_) => const SizedBox.shrink(),
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final checkSize = tester.getSize(
        find.byKey(const Key('pending-check-status')),
      );
      expect(checkSize.height, greaterThanOrEqualTo(DsSizes.primaryAction));
    });

    testWidgets('软键盘弹出切换紧凑布局时 UnitAuthPage 输入框保持同一 State 且不失焦', (
      tester,
    ) async {
      final viewInsets = ValueNotifier<EdgeInsets>(EdgeInsets.zero);
      addTearDown(viewInsets.dispose);
      final store = OnboardingFlowStore(
        authenticationRequired: true,
        pendingPollInterval: null,
        onAuthenticate: (_, _, _) async {},
        onEnterGuestMode: () async {},
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildCommandTheme(Brightness.light),
          themeAnimationDuration: Duration.zero,
          builder: (BuildContext context, Widget? appChild) {
            return ValueListenableBuilder<EdgeInsets>(
              valueListenable: viewInsets,
              builder: (BuildContext context, EdgeInsets insets, _) {
                final mq = MediaQuery.of(context);
                return MediaQuery(
                  data: mq.copyWith(
                    viewInsets: insets,
                    disableAnimations: true,
                  ),
                  child: appChild!,
                );
              },
            );
          },
          home: UnitAuthPage(store: store),
        ),
      );
      await tester.pumpAndSettle();

      final unitFieldFinder = find.byKey(const Key('auth-unit-name'));
      final editableFinder = find.descendant(
        of: unitFieldFinder,
        matching: find.byType(EditableText),
      );
      await tester.tap(unitFieldFinder);
      await tester.pump();

      final initialEditable = tester.widget<EditableText>(editableFinder);
      final initialState = tester.state<EditableTextState>(editableFinder);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(initialEditable.focusNode.hasFocus, isTrue);
      expect(find.byKey(const Key('auth-guest-mode')), findsOneWidget);

      // 模拟系统软键盘弹出（viewInsets.bottom > 80），触发紧凑态重排
      viewInsets.value = const EdgeInsets.only(bottom: 320);
      await tester.pump();

      expect(find.byKey(const Key('auth-guest-mode')), findsNothing);
      final afterOpenEditable = tester.widget<EditableText>(editableFinder);
      final afterOpenState = tester.state<EditableTextState>(editableFinder);
      expect(identical(afterOpenState, initialState), isTrue);
      expect(afterOpenEditable.focusNode.hasFocus, isTrue);

      await tester.enterText(unitFieldFinder, '示例市消防救援支队');
      await tester.pump();
      expect(find.text('示例市消防救援支队'), findsOneWidget);

      // 来回切换键盘收起/再次弹出，焦点的同一性与已输入内容均不丢失
      viewInsets.value = EdgeInsets.zero;
      await tester.pump();
      expect(find.byKey(const Key('auth-guest-mode')), findsOneWidget);
      expect(
        identical(tester.state<EditableTextState>(editableFinder), initialState),
        isTrue,
      );
      expect(
        tester.widget<EditableText>(editableFinder).focusNode.hasFocus,
        isTrue,
      );

      viewInsets.value = const EdgeInsets.only(bottom: 320);
      await tester.pump();
      expect(find.byKey(const Key('auth-guest-mode')), findsNothing);
      expect(
        identical(tester.state<EditableTextState>(editableFinder), initialState),
        isTrue,
      );
      expect(
        tester.widget<EditableText>(editableFinder).focusNode.hasFocus,
        isTrue,
      );
      expect(find.text('示例市消防救援支队'), findsOneWidget);
    });

    testWidgets('加载态收敛与软键盘弹出时 IncidentPickerPage 搜索框保持聚焦', (
      tester,
    ) async {
      final viewInsets = ValueNotifier<EdgeInsets>(EdgeInsets.zero);
      final loading = ValueNotifier<bool>(true);
      addTearDown(viewInsets.dispose);
      addTearDown(loading.dispose);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildCommandTheme(Brightness.light),
          themeAnimationDuration: Duration.zero,
          builder: (BuildContext context, Widget? appChild) {
            return ValueListenableBuilder<EdgeInsets>(
              valueListenable: viewInsets,
              builder: (BuildContext context, EdgeInsets insets, _) {
                final mq = MediaQuery.of(context);
                return MediaQuery(
                  data: mq.copyWith(
                    viewInsets: insets,
                    disableAnimations: true,
                  ),
                  child: appChild!,
                );
              },
            );
          },
          home: ValueListenableBuilder<bool>(
            valueListenable: loading,
            builder: (BuildContext context, bool isLoading, _) {
              return IncidentPickerPage(
                activeIncidents: const [],
                loading: isLoading,
                userUnitName: '示例市消防救援支队',
                onSelect: (_) async {},
                onCreate: () async {},
              );
            },
          ),
        ),
      );
      await tester.pump();

      final searchFinder = find.byKey(const Key('incident-picker-search-field'));
      final editableFinder = find.descendant(
        of: searchFinder,
        matching: find.byType(EditableText),
      );
      await tester.tap(searchFinder);
      await tester.pump();

      final initialState = tester.state<EditableTextState>(editableFinder);
      expect(
        tester.widget<EditableText>(editableFinder).focusNode.hasFocus,
        isTrue,
      );

      loading.value = false;
      viewInsets.value = const EdgeInsets.only(bottom: 320);
      await tester.pump();

      expect(find.byKey(const Key('incident-picker-create-btn')), findsNothing);
      expect(
        identical(tester.state<EditableTextState>(editableFinder), initialState),
        isTrue,
      );
      expect(
        tester.widget<EditableText>(editableFinder).focusNode.hasFocus,
        isTrue,
      );
    });

    testWidgets('UnitAuthPage 展示火场智控品牌页头、框外固定标签与紧凑态 Logo', (
      tester,
    ) async {
      final viewInsets = ValueNotifier<EdgeInsets>(EdgeInsets.zero);
      addTearDown(viewInsets.dispose);
      final store = OnboardingFlowStore(
        authenticationRequired: true,
        pendingPollInterval: null,
        onAuthenticate: (_, _, _) async {},
        onEnterGuestMode: () async {},
      );
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildCommandTheme(Brightness.light),
          themeAnimationDuration: Duration.zero,
          builder: (BuildContext context, Widget? appChild) {
            return ValueListenableBuilder<EdgeInsets>(
              valueListenable: viewInsets,
              builder: (BuildContext context, EdgeInsets insets, _) {
                final mq = MediaQuery.of(context);
                return MediaQuery(
                  data: mq.copyWith(
                    viewInsets: insets,
                    disableAnimations: true,
                  ),
                  child: appChild!,
                );
              },
            );
          },
          home: UnitAuthPage(store: store),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 常态渲染 FireControlLogo 32dp + 「火场智控」品牌行 + 精简副标题，且移除静态「单位实名接入」胶囊
      expect(find.byKey(const Key('auth-brand-row')), findsOneWidget);
      final normalLogo = tester.widget<FireControlLogo>(
        find.byType(FireControlLogo),
      );
      expect(normalLogo.size, 32);
      expect(find.text('火场智控'), findsOneWidget);
      expect(find.text('先完成用户认证'), findsOneWidget);
      expect(find.text('认证后同步查看并记录本单位警情与空呼。'), findsOneWidget);
      expect(find.byType(StatusPill), findsNothing);
      expect(find.text('单位实名接入'), findsNothing);

      // 2. 三个表单项均使用框外固定标签，且 TextField 内部无浮动 labelText
      expect(find.byType(AuthLabeledField), findsNWidgets(3));
      expect(find.text('单位名称'), findsOneWidget);
      expect(find.text('真实姓名'), findsOneWidget);
      expect(find.text('单位验证码'), findsOneWidget);

      for (final fieldKey in const <Key>[
        Key('auth-unit-name'),
        Key('auth-real-name'),
        Key('auth-unit-code'),
      ]) {
        final field = tester.widget<TextField>(find.byKey(fieldKey));
        expect(field.decoration?.labelText, isNull);
      }

      // 3. 软键盘弹出进入紧凑态时展示 FireControlLogo 36dp 与「用户认证」标题
      viewInsets.value = const EdgeInsets.only(bottom: 320);
      await tester.pump();
      expect(find.byKey(const Key('auth-brand-row')), findsNothing);
      final compactLogo = tester.widget<FireControlLogo>(
        find.byType(FireControlLogo),
      );
      expect(compactLogo.size, 36);
      expect(find.text('用户认证'), findsOneWidget);
      expect(find.text('使用单位账号继续'), findsOneWidget);
    });
  });
}
