import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:watchdog/core/network/network.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/auth/data/auth_repository.dart';
import 'package:watchdog/features/auth/data/models/admin_login.dart';
import 'package:watchdog/features/auth/ui/admin_scanner_page.dart';

const AdminCapability _capability = AdminCapability(
  memberId: 'm-demo-1',
  name: '合成成员',
  unitName: '合成消防单位',
  unitRole: 'admin',
  role: 'unit_admin',
);

final String _validQr =
    'https://fireman119.xyz/admin/scan#12345678-1234-4123-8123-123456789abc.${'a' * 43}';

class _FakeAccessState extends ChangeNotifier {
  bool canReadKeySites = true;
  AdminCapability? capability = _capability;
  AdminCapability? nextRefreshedCapability = _capability;
  int epoch = 0;
  Object clientIdentity = Object();
  final List<({AdminLoginCode code, bool cancel})> submissions =
      <({AdminLoginCode code, bool cancel})>[];
  Object? submitError;

  Future<void> refreshCapability() async {
    capability = nextRefreshedCapability;
    notifyListeners();
  }

  void revoke() {
    canReadKeySites = false;
    capability = null;
    nextRefreshedCapability = null;
    epoch++;
    notifyListeners();
  }

  AdminScannerGateway toGateway() => AdminScannerGateway(
    accessListenable: this,
    canReadKeySites: () => canReadKeySites,
    readAdminCapability: () => capability,
    readProtectedDataEpoch: () => epoch,
    readClientIdentity: () => clientIdentity,
    refreshAdminCapability: refreshCapability,
    confirmAdminLogin: (AdminLoginCode code, {bool cancel = false}) async {
      if (submitError != null) throw submitError!;
      submissions.add((code: code, cancel: cancel));
    },
  );
}

Widget _wrapApp(
  Widget home, {
  GlobalKey<NavigatorState>? navigatorKey,
  double textScale = 1.0,
}) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    debugShowCheckedModeBanner: false,
    theme: buildCommandTheme(Brightness.light),
    themeAnimationDuration: Duration.zero,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: home,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M3g 后台扫码登录页 (AdminScannerPage)', () {
    test('扫码严格匹配本站规范，拒绝跨站、跳转、端口或额外内容', () {
      final parsed = AdminLoginCode.parse(_validQr);
      expect(parsed?.id, '12345678-1234-4123-8123-123456789abc');
      expect(parsed?.scan, 'a' * 43);

      for (final invalid in <String>[
        _validQr.replaceFirst('https:', 'http:'),
        _validQr.replaceFirst('fireman119.xyz', 'fireman119.xyz.evil.test'),
        _validQr.replaceFirst('/admin/scan', '/admin/scan?next=evil'),
        _validQr.replaceFirst('xyz/', 'xyz:443/'),
        '$_validQr\n',
        '$_validQr.extra',
        'javascript:alert(1)',
        'https://example.test',
      ]) {
        expect(AdminLoginCode.parse(invalid), isNull, reason: '非规范二维码必须拒绝');
      }
    });

    test('confirmAdminLogin 通过独立 POST 请求体提交凭据，绝不把凭据拼入 URL', () async {
      late http.Request captured;
      final client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(jsonEncode(<String, Object>{'ok': true}), 200);
      });
      final transport = ApiHttpTransport(
        const ApiConfig(
          baseUrl: 'https://example.test',
          incidentId: '',
          sessionToken: 'sess-demo',
          deviceId: 'dev-demo',
          unitId: 'unit-demo',
        ),
        clientFactory: () => client,
      );
      addTearDown(transport.dispose);

      final code = AdminLoginCode.parse(_validQr)!;
      await AuthRepository(transport).confirmAdminLogin(code, cancel: false);

      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/admin-app/confirm');
      expect(captured.url.hasQuery, isFalse);
      expect(captured.url.hasFragment, isFalse);
      expect(captured.url.toString(), isNot(contains(code.scan)));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['id'], code.id);
      expect(body['scan'], code.scan);
      expect(body['cancel'], isFalse);
    });

    test('adminLoginError 正确映射服务端业务错误码', () {
      expect(
        adminLoginError(
          ApiException('invalid', statusCode: 400, code: 'ADMIN_CHALLENGE_INVALID'),
        ),
        contains('已过期'),
      );
      expect(
        adminLoginError(
          ApiException('forbidden', statusCode: 403, code: 'ADMIN_FORBIDDEN'),
        ),
        contains('后台授权已失效'),
      );
      expect(
        adminLoginError(
          ApiException('limited', statusCode: 429, code: 'ADMIN_RATE_LIMITED'),
        ),
        contains('操作频繁'),
      );
      expect(
        adminLoginError(
          ApiException('expired', statusCode: 401, code: 'SESSION_EXPIRED'),
        ),
        contains('App 认证已失效'),
      );
      expect(adminLoginError(Exception('net')), contains('确认失败'));
    });

    testWidgets('扫描后展示本人姓名单位角色，仅明确点击确认才提交 POST 确认', (tester) async {
      final access = _FakeAccessState();
      addTearDown(access.dispose);
      late ValueChanged<String> detect;

      await tester.pumpWidget(
        _wrapApp(
          AdminScannerPage(
            gateway: access.toGateway(),
            scannerBuilder: (onDetected) {
              detect = onDetected;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 非本站链接被拒绝且不触发提交
      detect('https://example.test');
      await tester.pumpAndSettle();
      expect(find.textContaining('不会打开其它链接'), findsOneWidget);
      expect(access.submissions, isEmpty);

      // 合法二维码展示确认信息，尚未提交
      detect(_validQr);
      await tester.pumpAndSettle();
      expect(find.textContaining('姓名：合成成员'), findsOneWidget);
      expect(find.textContaining('消防单位：合成消防单位'), findsOneWidget);
      expect(find.textContaining('后台角色：单位后台管理员'), findsOneWidget);
      expect(access.submissions, isEmpty);

      // 确认与取消按钮均满足 >= 56dp 主操作触控热区
      expect(
        tester.getSize(find.byKey(const Key('admin-confirm-login'))).height,
        greaterThanOrEqualTo(DsSizes.primaryAction),
      );
      expect(
        tester.getSize(find.byKey(const Key('admin-cancel-login'))).height,
        greaterThanOrEqualTo(DsSizes.primaryAction),
      );

      // 点击确认后仅提交一次 cancel=false 并展示完成态
      await tester.tap(find.byKey(const Key('admin-confirm-login')));
      await tester.pumpAndSettle();
      expect(access.submissions.length, 1);
      expect(access.submissions.single.cancel, isFalse);
      expect(find.text('已确认网页登录'), findsOneWidget);
    });

    testWidgets('点击取消登录向服务端发送 cancel=true 并退出扫码页', (tester) async {
      final access = _FakeAccessState();
      addTearDown(access.dispose);
      late ValueChanged<String> detect;
      final navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        _wrapApp(
          const Scaffold(body: Center(child: Text('原页面'))),
          navigatorKey: navKey,
        ),
      );
      unawaited(
        navKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => AdminScannerPage(
              gateway: access.toGateway(),
              scannerBuilder: (onDetected) {
                detect = onDetected;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      detect(_validQr);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-cancel-login')));
      await tester.pumpAndSettle();

      expect(access.submissions.length, 1);
      expect(access.submissions.single.cancel, isTrue);
      expect(find.text('原页面'), findsOneWidget);
    });

    testWidgets('确认页触发系统返回（PopScope）自动向服务端发送 cancel=true', (tester) async {
      final access = _FakeAccessState();
      addTearDown(access.dispose);
      late ValueChanged<String> detect;
      final navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        _wrapApp(
          const Scaffold(body: Center(child: Text('上一页'))),
          navigatorKey: navKey,
        ),
      );
      unawaited(
        navKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => AdminScannerPage(
              gateway: access.toGateway(),
              scannerBuilder: (onDetected) {
                detect = onDetected;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      detect(_validQr);
      await tester.pumpAndSettle();
      await navKey.currentState!.maybePop();
      await tester.pumpAndSettle();

      expect(access.submissions.length, 1);
      expect(access.submissions.single.cancel, isTrue);
      expect(find.text('上一页'), findsOneWidget);
    });

    testWidgets('后台撤权或 App 退出立即清除确认页身份并阻止提交', (tester) async {
      final access = _FakeAccessState();
      addTearDown(access.dispose);
      late ValueChanged<String> detect;

      await tester.pumpWidget(
        _wrapApp(
          AdminScannerPage(
            gateway: access.toGateway(),
            scannerBuilder: (onDetected) {
              detect = onDetected;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      detect(_validQr);
      await tester.pumpAndSettle();
      expect(find.textContaining('姓名：合成成员'), findsOneWidget);

      access.revoke();
      await tester.pumpAndSettle();

      expect(find.textContaining('姓名：合成成员'), findsNothing);
      expect(find.byKey(const Key('admin-confirm-login')), findsNothing);
      expect(find.text('无有效后台授权'), findsOneWidget);
      expect(access.submissions, isEmpty);
    });

    testWidgets('确认页在 360dp + 130% 大字号下零溢出并清晰显示错误提示', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final access = _FakeAccessState()
        ..submitError = ApiException(
          'expired',
          statusCode: 400,
          code: 'ADMIN_CHALLENGE_INVALID',
        );
      addTearDown(access.dispose);
      late ValueChanged<String> detect;

      await tester.pumpWidget(
        _wrapApp(
          AdminScannerPage(
            gateway: access.toGateway(),
            scannerBuilder: (onDetected) {
              detect = onDetected;
              return const SizedBox.expand();
            },
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();

      detect(_validQr);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-confirm-login')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('admin-scanner-error')), findsOneWidget);
      expect(find.textContaining('二维码已过期'), findsOneWidget);
    });
  });
}
