import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/login_devices_page.dart';
import 'package:watchdog/pages/offline_review_page.dart';
import 'package:watchdog/services/offline_queue.dart';
import 'package:watchdog/state/app_controller.dart';

class _Controller extends AppController {
  bool revoked = false;
  @override
  bool get needsAuthentication => revoked;
  void revoke() {
    revoked = true;
    notifyListeners();
  }

  @override
  Future<void> sync() async {}
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'http://localhost', incidentId: 'incident');
  final revokedIds = <String?>[];
  final attempts = <Map<String, dynamic>>[];
  bool timeoutOnce = true;
  @override
  ApiClient forIncident(String id) => this;
  @override
  void dispose() {}
  @override
  Future<List<Map<String, dynamic>>> fetchLoginDevices() async => [
    {
      'id': 'current',
      'name': '本机',
      'platform': 'Android',
      'current': true,
      'last_seen_at': 1700000000000,
    },
    if (revokedIds.isEmpty)
      {
        'id': 'other',
        'name': '另一台平板',
        'platform': 'Android',
        'current': false,
        'last_seen_at': 1700000000000,
      },
  ];
  @override
  Future<void> revokeLoginDevice(String? id) async {
    revokedIds.add(id);
  }

  @override
  Future<Incident> fetchIncident(String id) async => const Incident(
    id: 'incident',
    number: '测试警情',
    status: 'active',
    createdAt: 1,
    lastActivityAt: 1,
  );
  @override
  Future<List<Entry>> fetchEntries({bool activeOnly = false}) async => [
    Entry(
      id: 'entry',
      name: '队员',
      version: 4,
      pressureMpa: 16,
      durationMin: 10,
      entryAt: 1,
      exitAt: 600001,
      source: 'voice',
    ),
  ];
  @override
  Future<void> submitReviewedOperation({
    required String type,
    required Map<String, dynamic> payload,
    required String originalOpId,
    required String newOpId,
    int? expectedVersion,
  }) async {
    attempts.add({
      'payload': Map.of(payload),
      'original': originalOpId,
      'op': newOpId,
      'version': expectedVersion,
    });
    if (timeoutOnce) {
      timeoutOnce = false;
      throw TimeoutException('网络未确认');
    }
  }

  @override
  Future<Map<String, dynamic>> uploadOfflineOperations(
    List<Map<String, dynamic>> operations,
  ) async => {
    'results': [
      for (final op in operations)
        {
          'client_op_id': op['client_op_id'],
          'accepted': false,
          'code': 'VERSION_CONFLICT',
          'error': '其他设备已更新读数',
          'current': {'name': '队员', 'pressure_mpa': 16},
        },
    ],
  };
}

Future<void> settleIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Widget shell(Widget child) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(320, 800),
      textScaler: TextScaler.linear(1.3),
    ),
    child: child,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('设备页1.3倍字体可管理其他设备，确认后撤销；失效后立即隐藏数据', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    final controller = _Controller()..api = api;
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(LoginDevicesPage(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('当前设备'), findsOneWidget);
    await tester.tap(find.text('退出该设备'));
    await tester.pumpAndSettle();
    expect(api.revokedIds, isEmpty);
    await tester.tap(find.text('确认退出'));
    await tester.pumpAndSettle();
    expect(api.revokedIds, ['other']);
    controller.revoke();
    await tester.pumpAndSettle();
    expect(find.text('登录已失效，请返回重新认证'), findsOneWidget);
    expect(find.text('当前设备'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('人工复核要求重新输入压力，重启页面后重试使用相同请求和操作号', (tester) async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({
      'unit_id': 'unit',
      'auth_member_id': 'member',
    });
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('review-page-'),
    );
    final queue = OfflineQueue.forDatabase(
      factory: databaseFactoryFfi,
      path: '${dir!.path}/queue.db',
    );
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    final controller = _Controller()..api = api;
    addTearDown(() async {
      controller.dispose();
      await queue.close();
      await dir.delete(recursive: true);
    });
    await tester.runAsync(() async {
      await queue.enqueue(
        incidentId: 'incident',
        type: 'pressure',
        occurredAt: 1700000000000,
        clientOpId: 'original-op',
        payload: {
          'entry_id': 'entry',
          'name': '队员',
          'pressure_mpa': 20,
          'expected_version': 1,
        },
      );
      await queue.drain((_) => api);
    });
    await tester.pumpWidget(
      shell(OfflineReviewPage(controller: controller, queue: queue)),
    );
    await settleIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, '核对后重新提交'));
    await settleIo(tester);
    expect(find.textContaining('服务器：队员，16.0'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '15');
    await tester.tap(find.text('确认'));
    await settleIo(tester);
    expect(api.attempts, hasLength(1));
    expect(api.attempts.single['version'], 4);
    expect((api.attempts.single['payload'] as Map)['pressure_mpa'], 15);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(
      shell(OfflineReviewPage(controller: controller, queue: queue)),
    );
    await settleIo(tester);
    await tester.tap(find.text('重试已确认的提交'));
    await settleIo(tester);
    expect(api.attempts, hasLength(2));
    expect(api.attempts.first, api.attempts.last);
    expect(await tester.runAsync(() => queue.reviewOperations()), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
