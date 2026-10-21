import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/admin_login.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/home_page.dart';
import 'package:watchdog/pages/admin_scanner_page.dart';
import 'package:watchdog/pages/settings_page.dart';
import 'package:watchdog/services/settings.dart';
import 'package:watchdog/state/app_controller.dart';

const capability = AdminCapability(
  memberId: 'm',
  name: '合成成员',
  unitName: '合成消防单位',
  unitRole: 'admin',
  role: 'unit_admin',
);
final qr =
    'https://fireman119.xyz/admin/scan#12345678-1234-4123-8123-123456789abc.${'a' * 43}';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test', incidentId: '');
  AdminCapability? grant = capability;
  final confirmations = <bool>[];
  @override
  Future<AdminCapability?> fetchAdminCapability() async => grant;
  @override
  Future<void> confirmAdminLogin(
    AdminLoginCode code, {
    bool cancel = false,
  }) async {
    confirmations.add(cancel);
  }
}

class _Controller extends AppController {
  bool allowed = true;
  bool guest = false;
  int epoch = 0;
  _Controller(_Api client) {
    api = client;
    adminCapability = client.grant;
  }
  @override
  bool get canReadKeySites => allowed && !guest;
  @override
  bool get isGuest => guest;
  @override
  bool get needsAuthentication => !allowed;
  @override
  bool get protectedDataRevoked => !allowed;
  @override
  int get protectedDataEpoch => epoch;
  void revoke() {
    allowed = false;
    adminCapability = null;
    epoch++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test('扫码严格匹配本站规范，不接受跨站、跳转、端口或额外内容', () {
    expect(
      AdminLoginCode.parse(qr)?.id,
      '12345678-1234-4123-8123-123456789abc',
    );
    for (final invalid in [
      qr.replaceFirst('https:', 'http:'),
      qr.replaceFirst('fireman119.xyz', 'fireman119.xyz.evil.test'),
      qr.replaceFirst('/admin/scan', '/admin/scan?next=evil'),
      qr.replaceFirst('xyz/', 'xyz:443/'),
      '$qr\n',
      '$qr.extra',
      'javascript:alert(1)',
      'https://example.test',
    ]) {
      expect(AdminLoginCode.parse(invalid), isNull, reason: '非规范二维码必须拒绝');
    }
  });
  testWidgets('扫描后显示本人姓名单位角色，只有明确确认才提交', (tester) async {
    final api = _Api(), controller = _Controller(_Api());
    controller.api = api;
    late ValueChanged<String> detect;
    await tester.pumpWidget(
      MaterialApp(
        home: AdminScannerPage(
          controller: controller,
          scannerBuilder: (callback) {
            detect = callback;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    detect('https://example.test');
    await tester.pumpAndSettle();
    expect(find.textContaining('不会打开其它链接'), findsOneWidget);
    expect(api.confirmations, isEmpty);
    detect(qr);
    await tester.pumpAndSettle();
    expect(find.textContaining('姓名：合成成员'), findsOneWidget);
    expect(find.textContaining('后台角色：单位后台管理员'), findsOneWidget);
    expect(api.confirmations, isEmpty);
    await tester.tap(find.text('确认登录'));
    await tester.pumpAndSettle();
    expect(api.confirmations, [false]);
    expect(find.textContaining('已确认网页登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('取消扫码登录向服务端取消挑战，绝不确认', (tester) async {
    final api = _Api();
    final controller = _Controller(api);
    late ValueChanged<String> detect;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('原页面')),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => AdminScannerPage(
            controller: controller,
            scannerBuilder: (callback) {
              detect = callback;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    detect(qr);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消登录'));
    await tester.pumpAndSettle();
    expect(api.confirmations, [true]);
    expect(find.text('原页面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('后台撤权或App退出立即清除扫码确认页中的身份', (tester) async {
    final api = _Api();
    final controller = _Controller(api);
    late ValueChanged<String> detect;
    await tester.pumpWidget(
      MaterialApp(
        home: AdminScannerPage(
          controller: controller,
          scannerBuilder: (callback) {
            detect = callback;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    detect(qr);
    await tester.pumpAndSettle();
    api.grant = null;
    await controller.refreshAdminCapability();
    await tester.pumpAndSettle();
    expect(find.textContaining('姓名：合成成员'), findsNothing);
    expect(find.text('确认登录'), findsNothing);
    expect(api.confirmations, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('身份Hero统一显示管理员，撤权隐藏扫码，退出同步清除身份', (tester) async {
    await Settings.setRealName('合成成员');
    await Settings.setUnitId('u');
    await Settings.setUnitName('合成消防单位');
    await Settings.setUnitCode('test');
    await Settings.setUserRole('admin');
    final api = _Api();
    final controller = _Controller(api);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('合成成员'), findsOneWidget);
    expect(find.text('合成消防单位'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.textContaining('单位角色'), findsNothing);
    expect(find.textContaining('后台角色'), findsNothing);
    expect(find.textContaining('认证状态'), findsNothing);
    expect(find.textContaining('平台管理员'), findsNothing);
    expect(find.byKey(const Key('admin-scan')), findsOneWidget);
    expect(find.text('现场地图'), findsNothing);
    expect(find.byKey(const Key('leave-unit')), findsNothing);
    api.grant = null;
    await controller.refreshAdminCapability();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin-scan')), findsNothing);
    controller.revoke();
    await tester.pumpAndSettle();
    expect(find.text('合成成员'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('单位manager仍显示管理员，普通成员显示认证用户', (tester) async {
    await Settings.setRealName('合成成员');
    await Settings.setUnitId('u');
    await Settings.setUnitName('合成消防单位');
    await Settings.setUnitCode('test');
    await Settings.setUserRole('manager');
    final api = _Api()..grant = null;
    final controller = _Controller(api);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('管理员'), findsOneWidget);
    expect(find.byKey(const Key('admin-scan')), findsNothing);

    await Settings.setUserRole('member');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('认证用户'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('320dp大字号身份Hero完整换行，扫码触控区域至少48dp', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await Settings.setRealName('合成成员');
    await Settings.setUnitId('u');
    await Settings.setUnitName('合成消防单位');
    await Settings.setUnitCode('test');
    final api = _Api();
    final controller = _Controller(api);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byKey(const Key('admin-scan')));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('身份Hero使用黑色卡面并保留姓名单位等级层级', (tester) async {
    await Settings.setRealName('合成成员');
    await Settings.setUnitId('u');
    await Settings.setUnitName('合成消防单位');
    await Settings.setUnitCode('test');
    await Settings.setUserRole('member');
    final api = _Api()..grant = null;
    final controller = _Controller(api);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    final hero = tester.widget<Container>(
      find.byKey(const Key('identity-hero')),
    );
    final decoration = hero.decoration! as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.colors.first.computeLuminance(), lessThan(0.02));
    expect(find.text('我的身份'), findsNothing);
    expect(find.text('合成成员'), findsOneWidget);
    expect(find.text('合成消防单位'), findsOneWidget);
    expect(find.text('认证用户'), findsOneWidget);
    expect(find.text('用户等级'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  testWidgets('首页两列工具卡大字号横屏可滚动，相机无悬浮入口', (tester) async {
    tester.view.physicalSize = const Size(900, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    final controller = _Controller(api)..guest = true;
    controller.currentIncident = const Incident(
      id: 'i',
      number: '合成警情',
      status: 'active',
      createdAt: 1,
      lastActivityAt: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(body: HomePage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('现场工具'), findsOneWidget);
    expect(find.text('单机模式'), findsOneWidget);
    expect(find.text('重点单位'), findsOneWidget);
    expect(find.text('水印相机'), findsOneWidget);
    expect(find.text('定位分享'), findsOneWidget);
    expect(find.text('视频资源'), findsOneWidget);
    expect(find.text('按住下方按钮说话'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('tool-重点单位'))).width,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('tool-定位分享'))).width,
      greaterThanOrEqualTo(48),
    );
    final topY = tester.getTopLeft(find.byKey(const ValueKey('tool-重点单位'))).dy;
    for (final title in ['重点单位', '水印相机', '定位分享', '视频资源']) {
      final finder = find.byKey(ValueKey('tool-$title'));
      expect(tester.getTopLeft(finder).dy, topY);
      expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.dispose();
  });
  test('后台权限请求乱序时，迟到的旧授权不能覆盖已撤销状态', () async {
    final api = _DelayedApi();
    final controller = _Controller(api);
    final first = controller.refreshAdminCapability();
    final second = controller.refreshAdminCapability();
    api.requests[1].complete(null);
    await second;
    expect(controller.adminCapability, isNull);
    api.requests[0].complete(capability);
    await first;
    expect(controller.adminCapability, isNull);
    controller.dispose();
  });
}

class _DelayedApi extends _Api {
  final requests = <Completer<AdminCapability?>>[];
  @override
  Future<AdminCapability?> fetchAdminCapability() {
    final request = Completer<AdminCapability?>();
    requests.add(request);
    return request.future;
  }
}
