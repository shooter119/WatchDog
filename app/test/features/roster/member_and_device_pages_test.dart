import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:watchdog/core/network/api_config.dart';
import 'package:watchdog/core/network/api_exceptions.dart';
import 'package:watchdog/core/network/api_http_transport.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/roster/data/roster_repository.dart';
import 'package:watchdog/features/roster/ui/login_devices_page.dart';
import 'package:watchdog/features/roster/ui/member_review_page.dart';
import 'package:watchdog/features/roster/ui/offline_review_page.dart';
import 'package:watchdog/features/roster/ui/unit_stations_page.dart';
import 'package:watchdog/services/offline_queue.dart';

const _applicant = PendingMemberView(
  id: 'pending-1',
  realName: '测试申请人',
  stationName: '示例路站',
  applyReason: '调入',
  createdAt: 1700000000000,
  inRoster: true,
);

class _FakeMemberReviewGateway extends ChangeNotifier
    implements MemberReviewGateway {
  @override
  Listenable get changes => this;
  @override
  int protectedDataEpoch = 1;
  @override
  bool protectedDataRevoked = false;
  @override
  bool needsAuthentication = false;
  @override
  bool canReviewMembers = true;
  @override
  bool isLoading = false;
  @override
  String? error;
  @override
  String unitName = '示例测试单位';

  List<PendingMemberView> _pending = <PendingMemberView>[_applicant];
  List<MemberReviewHistoryItem> _history = <MemberReviewHistoryItem>[];
  List<MemberReviewHistoryItem> nextPageRows = <MemberReviewHistoryItem>[];
  bool failOnRefresh = false;
  Object? failOnHistory;
  int approvals = 0;
  int rejections = 0;

  @override
  List<PendingMemberView> get pendingMembers => _pending;
  @override
  List<MemberReviewHistoryItem> get reviewHistory => _history;

  void seedHistory(List<MemberReviewHistoryItem> items) {
    _history = <MemberReviewHistoryItem>[...items];
    notifyListeners();
  }

  void revokeCapability() {
    canReviewMembers = false;
    _pending = <PendingMemberView>[];
    _history = <MemberReviewHistoryItem>[];
    protectedDataEpoch++;
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    if (failOnRefresh) {
      error = '网络失败';
    } else {
      error = null;
    }
    notifyListeners();
  }

  @override
  Future<void> approveMember(String memberId) async {
    approvals++;
    _pending = <PendingMemberView>[];
    _history = <MemberReviewHistoryItem>[
      const MemberReviewHistoryItem(
        id: 'r1',
        realName: '测试申请人',
        reviewStatus: 'approved',
        reviewerName: '管理员甲',
        reviewedAt: 1700000001000,
      ),
    ];
  }

  @override
  Future<void> rejectMember(String memberId) async {
    rejections++;
    _pending = <PendingMemberView>[];
  }

  @override
  Future<List<MemberReviewHistoryItem>> fetchHistoryPage({
    required int offset,
  }) async {
    if (failOnHistory != null) throw failOnHistory!;
    return nextPageRows;
  }

  @override
  void appendHistoryPage(List<MemberReviewHistoryItem> rows) {
    _history = <MemberReviewHistoryItem>[..._history, ...rows];
    notifyListeners();
  }
}

class _FakeLoginDevicesGateway extends ChangeNotifier
    implements LoginDevicesGateway {
  bool authorized = true;
  final List<String?> revokedIds = <String?>[];

  @override
  Listenable get changes => this;
  @override
  bool get isAuthorized => authorized;

  void revokeSession() {
    authorized = false;
    notifyListeners();
  }

  @override
  Future<List<LoginDeviceView>> fetchDevices() async => <LoginDeviceView>[
    const LoginDeviceView(
      id: 'current',
      name: '本机',
      platform: 'Android',
      current: true,
      lastSeenAt: 1700000000000,
    ),
    if (revokedIds.isEmpty)
      const LoginDeviceView(
        id: 'other',
        name: '另一台平板',
        platform: 'Android',
        current: false,
        lastSeenAt: 1700000000000,
      ),
  ];

  @override
  Future<void> revokeDevice(String? deviceId) async {
    revokedIds.add(deviceId);
  }
}

class _FakeOfflineReviewGateway extends ChangeNotifier
    implements OfflineReviewGateway {
  bool authorized = true;
  bool timeoutOnce = true;
  final List<Map<String, dynamic>> attempts = <Map<String, dynamic>>[];

  @override
  Listenable get changes => this;
  @override
  bool get isAuthorized => authorized;

  void revokeSession() {
    authorized = false;
    notifyListeners();
  }

  @override
  Future<bool> isIncidentActive(String incidentId) async => true;

  @override
  Future<OfflineReviewEntrySnapshot?> fetchEntrySnapshot({
    required String incidentId,
    required String entryId,
  }) async => const OfflineReviewEntrySnapshot(
    id: 'entry',
    name: '队员',
    isActive: true,
    version: 4,
    pressureMpa: 16,
  );

  @override
  Future<void> submitReviewedOperation({
    required String incidentId,
    required String type,
    required Map<String, dynamic> payload,
    required String originalOpId,
    required String newOpId,
    int? expectedVersion,
  }) async {
    attempts.add(<String, dynamic>{
      'payload': Map<String, dynamic>.of(payload),
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
  Future<void> syncAfterReview() async {}
}

class _FakeRosterRepository extends RosterRepository {
  factory _FakeRosterRepository({
    List<Map<String, dynamic>> stations = const <Map<String, dynamic>>[],
    bool canManage = true,
  }) => _FakeRosterRepository._(
    ApiHttpTransport(
      const ApiConfig(baseUrl: 'http://test', incidentId: ''),
    ),
    stations: stations,
    canManage: canManage,
  );

  _FakeRosterRepository._(
    this._transport, {
    List<Map<String, dynamic>> stations = const <Map<String, dynamic>>[],
    this.canManage = true,
  }) : _stations = stations
           .map((e) => Map<String, dynamic>.from(e))
           .toList(),
       super(_transport);

  final ApiHttpTransport _transport;
  final List<Map<String, dynamic>> _stations;
  bool canManage;
  Object? fetchError;

  void dispose() => _transport.dispose();

  @override
  Future<List<Map<String, dynamic>>> fetchUnitStations({
    bool includeInactive = false,
  }) async {
    if (fetchError != null) throw fetchError!;
    return _stations.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  @override
  Future<Map<String, dynamic>> unitStationAccess() async => <String, dynamic>{
    'can_manage': canManage,
  };

  @override
  Future<Map<String, dynamic>> addUnitStation(String name) async {
    final added = <String, dynamic>{
      'id': 'st-${_stations.length + 1}',
      'name': name,
      'aliases': <String>[],
      'active': true,
      'version': 1,
    };
    _stations.add(added);
    return added;
  }

  @override
  Future<Map<String, dynamic>> updateUnitStation(
    String id,
    Map<String, dynamic> data,
  ) async {
    final idx = _stations.indexWhere((s) => s['id'].toString() == id);
    final updated = <String, dynamic>{
      ..._stations[idx],
      'name': data['name'],
      'aliases': data['aliases'],
      'active': data['active'],
      'version': ((_stations[idx]['version'] as num?)?.toInt() ?? 1) + 1,
    };
    _stations[idx] = updated;
    return updated;
  }
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Widget _wrapDs(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildCommandTheme(brightness),
    builder: (BuildContext context, Widget? appChild) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: appChild!,
    ),
    home: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('入队审批页展示申请说明，同意后移出待办，支持大字体', (WidgetTester tester) async {
    final gateway = _FakeMemberReviewGateway();
    addTearDown(gateway.dispose);

    await tester.pumpWidget(
      _wrapDs(MemberReviewPage(gateway: gateway), textScale: 1.3),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试申请人'), findsOneWidget);
    expect(find.text('已在语音名单'), findsOneWidget);
    expect(find.text('申请单位：示例测试单位'), findsOneWidget);
    expect(find.text('申请说明：调入'), findsOneWidget);

    await tester.tap(find.text('同意入队'));
    await tester.pumpAndSettle();
    expect(gateway.approvals, 1);
    expect(find.text('暂无待审批申请'), findsOneWidget);

    await tester.tap(find.text('已处理'));
    await tester.pumpAndSettle();
    expect(find.text('测试申请人'), findsOneWidget);
    expect(find.text('已同意'), findsOneWidget);
    expect(find.textContaining('处理人：管理员甲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('入队审批驳回需二次确认，失败可重试，分页加载且失权立即清空', (WidgetTester tester) async {
    final gateway = _FakeMemberReviewGateway();
    gateway.seedHistory(
      List<MemberReviewHistoryItem>.generate(
        50,
        (int i) => MemberReviewHistoryItem(
          id: 'h-$i',
          realName: '历史队员$i',
          reviewStatus: i.isEven ? 'approved' : 'rejected',
          reviewerName: '管理员甲',
          reviewedAt: 1700000001000 + i * 1000,
        ),
      ),
    );
    gateway.nextPageRows = const <MemberReviewHistoryItem>[
      MemberReviewHistoryItem(
        id: 'h-50',
        realName: '分页新队员',
        reviewStatus: 'approved',
        reviewerName: '管理员乙',
        reviewedAt: 1700000900000,
      ),
    ];
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_wrapDs(MemberReviewPage(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('驳回'));
    await tester.pumpAndSettle();
    expect(find.text('驳回入队申请'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(gateway.rejections, 0);

    gateway.failOnRefresh = true;
    await gateway.refresh();
    await tester.pumpAndSettle();
    expect(find.textContaining('审批信息加载失败'), findsOneWidget);
    expect(find.text('暂无待审批申请'), findsNothing);

    gateway.failOnRefresh = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('审批信息加载失败'), findsNothing);

    await tester.tap(find.text('已处理'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(find.text('加载更多'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(gateway.reviewHistory.length, 51);

    // 403/撤销权限后立即清空并展示无权限提示
    gateway.failOnHistory = ApiException('无权限', statusCode: 403);
    gateway.revokeCapability();
    await tester.pumpAndSettle();
    expect(find.text('无本单位审批权限，请重新认证或联系管理员'), findsOneWidget);
    expect(find.text('测试申请人'), findsNothing);
  });

  testWidgets('登录设备页 1.3 倍字体管理其他设备并二次确认撤销，失效后立即隐藏数据', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _FakeLoginDevicesGateway();
    addTearDown(gateway.dispose);

    await tester.pumpWidget(
      _wrapDs(LoginDevicesPage(gateway: gateway), textScale: 1.3),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前设备'), findsOneWidget);
    await tester.tap(find.text('退出该设备'));
    await tester.pumpAndSettle();
    expect(gateway.revokedIds, isEmpty);

    await tester.tap(find.text('确认退出'));
    await tester.pumpAndSettle();
    expect(gateway.revokedIds, <String?>['other']);

    gateway.revokeSession();
    await tester.pumpAndSettle();
    expect(find.text('登录已失效，请返回重新认证'), findsOneWidget);
    expect(find.text('当前设备'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离线冲突复核要求重输压力，重启页面后沿用原请求与操作号完成重试', (
    WidgetTester tester,
  ) async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'unit_id': 'unit',
      'auth_member_id': 'member',
    });
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('roster-offline-review-'),
    );
    final queue = OfflineQueue.forDatabase(
      factory: databaseFactoryFfi,
      path: '${dir!.path}/queue.db',
    );
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _FakeOfflineReviewGateway();
    addTearDown(() async {
      gateway.dispose();
      await queue.close();
      await dir.delete(recursive: true);
    });

    await tester.runAsync(() async {
      await queue.enqueue(
        incidentId: 'incident',
        type: 'pressure',
        occurredAt: 1700000000000,
        clientOpId: 'original-op',
        payload: <String, dynamic>{
          'entry_id': 'entry',
          'name': '队员',
          'pressure_mpa': 20,
          'expected_version': 1,
        },
      );
      await queue.close();
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/queue.db');
      await db.update(
        'offline_operations',
        <String, Object?>{
          'status': 'review',
          'result':
              '{"error":"其他设备已更新读数","current":{"name":"队员","pressure_mpa":16}}',
        },
        where: 'client_op_id = ?',
        whereArgs: <Object?>['original-op'],
      );
      await db.close();
    });

    await tester.pumpWidget(
      _wrapDs(
        OfflineReviewPage(gateway: gateway, queue: queue),
        textScale: 1.3,
      ),
    );
    await _settleIo(tester);

    await tester.tap(find.text('核对后重新提交'));
    await _settleIo(tester);
    expect(find.textContaining('服务器：队员，16.0'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '15');
    await tester.tap(find.text('确认'));
    await _settleIo(tester);

    expect(gateway.attempts, hasLength(1));
    expect(gateway.attempts.single['version'], 4);
    expect((gateway.attempts.single['payload'] as Map)['pressure_mpa'], 15);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(
      _wrapDs(
        OfflineReviewPage(gateway: gateway, queue: queue),
        textScale: 1.3,
      ),
    );
    await _settleIo(tester);

    await tester.tap(find.text('重试已确认的提交'));
    await _settleIo(tester);
    expect(gateway.attempts, hasLength(2));
    expect(gateway.attempts.first, gateway.attempts.last);
    expect(await tester.runAsync(() => queue.reviewOperations()), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离线复核支持旧记录认领、保留不应用以及登录失效后立即隐藏', (WidgetTester tester) async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'unit_id': 'unit',
      'auth_member_id': 'member',
    });
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('roster-offline-legacy-'),
    );
    final queue = OfflineQueue.forDatabase(
      factory: databaseFactoryFfi,
      path: '${dir!.path}/queue.db',
    );
    final gateway = _FakeOfflineReviewGateway();
    addTearDown(() async {
      gateway.dispose();
      await queue.close();
      await dir.delete(recursive: true);
    });

    await tester.runAsync(() async {
      await queue.enqueue(
        incidentId: 'incident',
        type: 'note',
        occurredAt: 1700000000000,
        clientOpId: 'legacy-op',
        payload: <String, dynamic>{'text': '东侧水压下降'},
      );
      await queue.close();
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/queue.db');
      await db.update(
        'offline_operations',
        <String, Object?>{
          'status': 'review',
          'owner_member_id': '',
          'owner_unit_id': '',
          'result': '{"error":"旧版本未记录归属"}',
        },
        where: 'client_op_id = ?',
        whereArgs: <Object?>['legacy-op'],
      );
      await db.close();
    });

    await tester.pumpWidget(
      _wrapDs(OfflineReviewPage(gateway: gateway, queue: queue)),
    );
    await _settleIo(tester);

    expect(find.text('确认本人旧记录'), findsOneWidget);
    await tester.tap(find.text('确认本人旧记录'));
    await _settleIo(tester);
    expect(find.text('确认是本人留下的旧记录？'), findsOneWidget);
    await tester.tap(find.text('确认本人记录'));
    await _settleIo(tester);

    expect(find.text('保留记录，不应用'), findsOneWidget);
    await tester.tap(find.text('保留记录，不应用'));
    await _settleIo(tester);
    await tester.tap(find.text('确认'));
    await _settleIo(tester);
    expect(find.text('没有待核对记录'), findsOneWidget);

    gateway.revokeSession();
    await tester.pumpAndSettle();
    expect(find.text('登录已失效，请返回重新认证'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单位常用队伍页支持新增、维护别名启停以及 360dp @ 130% 双主题零溢出', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _FakeRosterRepository(
      stations: const <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'st-1',
          'name': '示例路站',
          'aliases': <String>['示例一站', '北站'],
          'active': false,
          'version': 2,
        },
      ],
      canManage: true,
    );
    addTearDown(repo.dispose);

    await tester.pumpWidget(
      _wrapDs(
        UnitStationsPage(repository: repo, isOffline: true),
        brightness: Brightness.dark,
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('示例路站'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
    expect(find.text('示例一站'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('新增常用队伍'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '示例南站');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('示例南站'), findsOneWidget);

    await tester.tap(find.text('示例路站'));
    await tester.pumpAndSettle();
    expect(find.text('维护常用队伍'), findsOneWidget);
    await tester.tap(find.text('可用于后续登记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('已停用'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
