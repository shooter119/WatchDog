import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/app/app_feature_flags.dart';
import 'package:watchdog/app/app_scope.dart';
import 'package:watchdog/app/shell/command_app_shell.dart';
import 'package:watchdog/app/shell/shell_keys.dart';
import 'package:watchdog/app/shell/shell_voice_bridge.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/video/ui/pip_shell.dart';
import 'package:watchdog/main.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/models/video_resources.dart';
import 'package:watchdog/services/system_pip.dart';
import 'package:watchdog/services/theme_controller.dart';
import 'package:watchdog/services/video_playback_session.dart';
import 'package:watchdog/state/app_controller.dart';

const VideoResource _kTestVideo = VideoResource(
  id: 'shell-test-cam',
  name: '测试监控通道',
  streamUrl: 'https://video.example.test/shell.flv',
);

class _ShellFakeController extends AppController {
  _ShellFakeController({
    bool needsAuth = false,
    bool needsIncident = false,
    bool requiresInc = false,
    bool guest = false,
    int pendingMembers = 0,
    super.appScope,
  }) : _needsAuth = needsAuth,
       _needsIncident = needsIncident,
       _requiresIncident = requiresInc,
       _guest = guest,
       _pendingMembers = pendingMembers;

  bool _needsAuth;
  bool _needsIncident;
  bool _requiresIncident;
  bool _guest;
  int _pendingMembers;

  int leaveUnitCalls = 0;
  int requestIncidentSelectionCalls = 0;
  final List<bool> pipStates = <bool>[];

  @override
  bool get needsAuthentication => _needsAuth;

  @override
  bool get needsIncidentSelection => _needsIncident;

  @override
  bool get requiresIncident => _requiresIncident;

  @override
  bool get isGuest => _guest;

  @override
  int get pendingMemberCount => _pendingMembers;

  void updateGate({
    bool? needsAuth,
    bool? needsIncident,
    bool? requiresInc,
    bool? guest,
    int? pendingMembers,
  }) {
    if (needsAuth != null) _needsAuth = needsAuth;
    if (needsIncident != null) _needsIncident = needsIncident;
    if (requiresInc != null) _requiresIncident = requiresInc;
    if (guest != null) _guest = guest;
    if (pendingMembers != null) _pendingMembers = pendingMembers;
    notifyListeners();
  }

  @override
  void setPipActive(bool active) {
    pipStates.add(active);
    super.setPipActive(active);
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> checkUpdateSilently() async {}

  @override
  void startSync() {}

  @override
  Future<void> sync() async {}

  @override
  Future<List<ChatMessage>> fetchChatHistory() async => const <ChatMessage>[];

  @override
  Future<void> leaveUnit() async {
    leaveUnitCalls++;
  }

  @override
  void requestIncidentSelection() {
    requestIncidentSelectionCalls++;
  }
}

Widget _stubTab(String keyName, String label) {
  return Center(
    child: Text(label, key: Key(keyName)),
  );
}

CommandAppShell _buildStubShell({
  required _ShellFakeController controller,
  VideoPlaybackSession? videoPlayback,
  ShellVoiceSlot? voiceSlot,
}) {
  return CommandAppShell(
    controller: controller,
    videoPlayback: videoPlayback,
    voiceSlot: voiceSlot,
    enableStartupSideEffects: false,
    commandTabBuilder: (_) => _stubTab('stub-tab-command', '指挥台内容'),
    monitorTabBuilder: (_) => _stubTab('stub-tab-monitor', '现场监控内容'),
    copilotTabBuilder: (_) => _stubTab('stub-tab-copilot', '智能辅助内容'),
    mineTabBuilder: (_) => _stubTab('stub-tab-mine', '我的内容'),
    startupGateBuilder: (_) => const ColoredBox(
      color: Colors.black54,
      child: Center(child: Text('启动门禁锁', key: Key('stub-startup-gate'))),
    ),
    floatingVideoBuilder: (_) => const SizedBox(
      width: 140,
      height: 80,
      child: Center(child: Text('悬浮视频窗', key: Key('stub-floating-video'))),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppFeatureFlags.resetForTesting();
    ThemeController.instance.resetForTest();
    SystemPip.resetForTesting();
  });

  tearDown(() {
    AppFeatureFlags.resetForTesting();
    ThemeController.instance.resetForTest();
    SystemPip.resetForTesting();
  });

  group('WatchDogApp 默认新外壳验证', () {
    testWidgets('默认唯一挂载 CommandAppShell 且默认落在 Tab 0（指挥台）', (
      tester,
    ) async {
      final newShellController = _ShellFakeController();
      addTearDown(newShellController.dispose);
      await tester.pumpWidget(
        WatchDogApp(controller: newShellController),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ShellKeys.root), findsOneWidget);
      expect(find.byKey(ShellKeys.navBar), findsOneWidget);
      expect(find.byKey(ShellKeys.voiceBtn), findsOneWidget);
      final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
      expect(stack.index, ShellVoiceBridge.commandTabIndex);
      expect(tester.takeException(), isNull);
    });
  });

  group('CommandAppShell 导航、门禁、游客横幅、PiP、悬浮窗与语音桥接', () {
    testWidgets('默认 Tab 0（指挥台）且支持 4-Tab 完整切换', (tester) async {
      final controller = _ShellFakeController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildStubShell(controller: controller));
      await tester.pumpAndSettle();

      IndexedStack currentStack() =>
          tester.widget<IndexedStack>(find.byType(IndexedStack));

      expect(currentStack().index, 0);
      expect(find.text('指挥台'), findsOneWidget);
      expect(find.text('现场监控'), findsOneWidget);
      expect(find.text('智能辅助'), findsOneWidget);
      expect(find.text('我的'), findsOneWidget);

      await tester.tap(find.byKey(ShellKeys.tabMonitor));
      await tester.pumpAndSettle();
      expect(currentStack().index, 1);

      await tester.tap(find.byKey(ShellKeys.tabCopilot));
      await tester.pumpAndSettle();
      expect(currentStack().index, 2);

      await tester.tap(find.byKey(ShellKeys.tabMine));
      await tester.pumpAndSettle();
      expect(currentStack().index, 3);

      await tester.tap(find.byKey(ShellKeys.tabCommand));
      await tester.pumpAndSettle();
      expect(currentStack().index, 0);
    });

    testWidgets('启动认证/选警情门禁锁定 PopScope 并拦截 Tab 切换，解锁后恢复', (tester) async {
      final controller = _ShellFakeController(
        needsAuth: true,
        needsIncident: true,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildStubShell(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byKey(ShellKeys.startupGate), findsOneWidget);
      final lockedPopScope = tester.widget<PopScope>(find.byType(PopScope));
      expect(lockedPopScope.canPop, isFalse);

      // 门禁锁定时底栏被 IgnorePointer 屏蔽，点击不应切换 Tab。
      await tester.tap(find.byKey(ShellKeys.tabMonitor), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 0);

      // 仅剩选警情门禁时仍保持锁定。
      controller.updateGate(needsAuth: false, needsIncident: true);
      await tester.pumpAndSettle();
      expect(find.byKey(ShellKeys.startupGate), findsOneWidget);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);

      // 完全解锁后移除门禁、恢复 PopScope 且允许切换 Tab。
      controller.updateGate(needsAuth: false, needsIncident: false);
      await tester.pumpAndSettle();
      expect(find.byKey(ShellKeys.startupGate), findsNothing);
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isTrue);

      await tester.tap(find.byKey(ShellKeys.tabMonitor));
      await tester.pumpAndSettle();
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);
    });

    testWidgets('游客模式顶栏横幅展示语义 Key 且点击「转为正式队员」触发 leaveUnit', (
      tester,
    ) async {
      final controller = _ShellFakeController(guest: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildStubShell(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byKey(ShellKeys.guestBanner), findsOneWidget);
      expect(find.byKey(const Key('guest-convert-btn')), findsOneWidget);
      expect(find.text('游客模式（数据仅保存在本机）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('guest-convert-btn')));
      await tester.pumpAndSettle();
      expect(controller.leaveUnitCalls, 1);

      controller.updateGate(guest: false);
      await tester.pumpAndSettle();
      expect(find.byKey(ShellKeys.guestBanner), findsNothing);
    });

    testWidgets('SystemPip 激活时切换至 CommandPipShell(ShellKeys.pipHost) 并同步控制器状态', (
      tester,
    ) async {
      final controller = _ShellFakeController();
      final video = VideoPlaybackSession.forTesting(resource: _kTestVideo);
      addTearDown(controller.dispose);
      addTearDown(video.dispose);

      await tester.pumpWidget(
        _buildStubShell(controller: controller, videoPlayback: video),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ShellKeys.pipHost), findsNothing);
      expect(find.byKey(ShellKeys.navBar), findsOneWidget);

      SystemPip.isActive.value = true;
      await tester.pump();
      expect(find.byKey(ShellKeys.pipHost), findsOneWidget);
      expect(find.byType(CommandPipShell), findsOneWidget);
      expect(find.byKey(ShellKeys.navBar), findsNothing);
      expect(controller.pipStates.last, isTrue);

      SystemPip.isActive.value = false;
      await tester.pump();
      expect(find.byKey(ShellKeys.pipHost), findsNothing);
      expect(find.byKey(ShellKeys.navBar), findsOneWidget);
      expect(controller.pipStates.last, isFalse);
    });

    testWidgets('悬浮视频窗按播放会话呈现态显示与隐藏（ShellKeys.floatingVideo）', (
      tester,
    ) async {
      final controller = _ShellFakeController();
      final video = VideoPlaybackSession.forTesting(resource: _kTestVideo);
      addTearDown(controller.dispose);
      addTearDown(video.dispose);

      await tester.pumpWidget(
        _buildStubShell(controller: controller, videoPlayback: video),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ShellKeys.floatingVideo), findsNothing);

      video.enterFloating();
      await tester.pumpAndSettle();
      expect(find.byKey(ShellKeys.floatingVideo), findsOneWidget);
      expect(find.byKey(const Key('stub-floating-video')), findsOneWidget);

      video.returnInline();
      await tester.pumpAndSettle();
      expect(find.byKey(ShellKeys.floatingVideo), findsNothing);
    });

    testWidgets('中置语音键短按提示/回指挥台，长按按 Tab 分流指挥台与智能辅助就地录音', (
      tester,
    ) async {
      final controller = _ShellFakeController();
      addTearDown(controller.dispose);

      var cmdStart = 0;
      var cmdEnd = 0;
      var copilotStart = 0;
      var copilotEnd = 0;
      var copilotDismiss = 0;

      final slot = ShellVoiceSlot(
        beginCommandRecording: () => cmdStart++,
        finishCommandRecording: () => cmdEnd++,
        beginCopilotRecording: () async => copilotStart++,
        finishCopilotRecording: () async => copilotEnd++,
        dismissCopilotKeyboard: () => copilotDismiss++,
      );

      await tester.pumpWidget(
        _buildStubShell(controller: controller, voiceSlot: slot),
      );
      await tester.pumpAndSettle();

      // Tab 0 短按 -> 提示长按说话。
      await tester.tap(find.byKey(ShellKeys.voiceBtn));
      await tester.pump();
      expect(find.text('长按说话，松开识别'), findsOneWidget);

      // Tab 0 长按开始/松手 -> 触发指挥台录音回调。
      final voiceCenter = tester.getCenter(find.byKey(ShellKeys.voiceBtn));
      final cmdGesture = await tester.startGesture(voiceCenter);
      await tester.pump(const Duration(milliseconds: 600));
      expect(cmdStart, 1);
      await cmdGesture.up();
      await tester.pump();
      expect(cmdEnd, 1);

      // 切至 Tab 1 后短按中置语音键 -> 回到 Tab 0（指挥台）。
      await tester.tap(find.byKey(ShellKeys.tabMonitor));
      await tester.pumpAndSettle();
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);
      await tester.tap(find.byKey(ShellKeys.voiceBtn));
      await tester.pumpAndSettle();
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 0);

      // 切至 Tab 2（智能辅助）长按 -> 就地触发 Copilot 录音且保持在 Tab 2。
      await tester.tap(find.byKey(ShellKeys.tabCopilot));
      await tester.pumpAndSettle();
      final copilotGesture = await tester.startGesture(voiceCenter);
      await tester.pump(const Duration(milliseconds: 600));
      expect(copilotDismiss, 1);
      expect(copilotStart, 1);
      await copilotGesture.up();
      await tester.pump();
      expect(copilotEnd, 1);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 2);
    });

    testWidgets('360dp 窄屏与 130% 系统字号下（昼白/暗曜 + 游客横幅 + 徽章）零溢出', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final controller = _ShellFakeController(guest: true, pendingMembers: 3);
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildStubShell(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byKey(ShellKeys.guestBanner), findsOneWidget);
      expect(find.byKey(ShellKeys.navBar), findsOneWidget);
      expect(find.byKey(ShellKeys.voiceBtn), findsOneWidget);
      expect(tester.takeException(), isNull);

      final voiceSize = tester.getSize(find.byKey(ShellKeys.voiceBtn));
      expect(voiceSize.width, greaterThanOrEqualTo(DsSizes.voiceButton));
      expect(voiceSize.height, greaterThanOrEqualTo(DsSizes.voiceButton));

      final convertSize = tester.getSize(
        find.byKey(const Key('guest-convert-btn')),
      );
      expect(convertSize.height, greaterThanOrEqualTo(DsSizes.touchTarget));

      // 切换暗曜主题复检零溢出。
      ThemeController.instance.select(AppThemePreference.night);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('AppController AppScope 桥接校验', () {
    test('惰性构建 AppScope、共享组织词库并随控制器释放，不干扰外部注入 Scope', () {
      final controller = _ShellFakeController();
      expect(controller.attachedAppScope, isNull);

      final scope = controller.appScope;
      expect(controller.attachedAppScope, same(scope));
      expect(controller.syncStore, same(scope.syncStore));
      expect(controller.sessionStore, same(scope.sessionStore));
      expect(controller.incidentStore, same(scope.incidentStore));
      expect(controller.rosterStore, same(scope.rosterStore));
      expect(controller.updateStore, same(scope.updateStore));
      expect(scope.rosterStore.orgDirectory, same(controller.orgDirectory));

      controller.dispose();
      expect(scope.isDisposed, isTrue);

      final externalScope = AppScope(
        createDefaultLocalAsr: false,
        enableStartupMaintenance: false,
      );
      addTearDown(externalScope.dispose);
      final bridged = _ShellFakeController(appScope: externalScope);
      expect(bridged.attachedAppScope, same(externalScope));
      bridged.dispose();
      expect(externalScope.isDisposed, isFalse);
    });
  });
}
