import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/pages/member_review_page.dart';
import 'package:watchdog/models/admin_login.dart';
import 'package:watchdog/state/app_controller.dart';

const applicant = UnitMember(
  id: 'pending-1',
  unitId: 'unit-a',
  realName: '测试申请人',
  role: 'member',
  status: 'disabled',
  reviewStatus: 'pending',
  stationName: '一站',
  applyReason: '调入',
  createdAt: 1700000000000,
  inRoster: true,
);

class ReviewApi extends ApiClient {
  ReviewApi() : super(baseUrl: 'http://test', incidentId: '', unitId: 'unit-a');
  bool allowed = true;
  bool fail = false;
  int approvals = 0;
  int rejections = 0;
  int capabilityCalls = 0;
  Completer<bool>? gate;
  List<UnitMember> pending = [applicant];
  List<Map<String, dynamic>> history = [];
  @override
  Future<bool> fetchMemberReviewCapability() async {
    capabilityCalls++;
    if (gate != null) return gate!.future;
    if (fail) throw Exception('网络失败');
    return allowed;
  }

  @override
  Future<List<UnitMember>> fetchPendingMembers() async => [...pending];
  @override
  Future<List<Map<String, dynamic>>> fetchMemberReviewHistory({
    int offset = 0,
  }) async => [...history];
  @override
  Future<AdminCapability?> fetchAdminCapability() async => null;
  @override
  Future<UnitMember> approveMember(String memberId) async {
    approvals++;
    pending = [];
    history = [
      {
        'id': 'r1',
        'real_name': applicant.realName,
        'review_status': 'approved',
        'reviewer_name': '管理员甲',
        'reviewed_at': 1700000001000,
      },
    ];
    return applicant;
  }

  @override
  Future<UnitMember> rejectMember(String memberId, {String? reason}) async {
    rejections++;
    pending = [];
    return applicant;
  }

  @override
  Future<void> logout() async {}
}

class ReviewController extends AppController {
  @override
  Future<void> refreshConfig() async {}
  @override
  void startSync() {}
  @override
  Future<void> sync() async {}
  @override
  Future<void> loadRoster() async {}
  @override
  Future<void> syncSettings() async {}
}

Future<ReviewController> controller(ReviewApi api) async {
  final c = ReviewController()..api = api;
  await c.init();
  await c.refreshPendingMembersCount();
  // Drain a coalesced refresh scheduled by initialization.
  await c.refreshPendingMembersCount();
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global'),
          (_) async => null,
        );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
    SharedPreferences.setMockInitialValues({
      'real_name': '管理员甲',
      'unit_id': 'unit-a',
      'unit_name': '测试单位',
      'session_token': 'token',
      'session_expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      'user_role': 'member',
    });
  });

  test('本地普通成员角色以服务端审批能力为准，撤销权限清空所有审批数据', () async {
    final api = ReviewApi();
    final c = await controller(api);
    addTearDown(c.dispose);
    expect(c.canReviewMembers, isTrue);
    expect(c.pendingMemberCount, 1);
    api.allowed = false;
    await c.refreshPendingMembersCount();
    expect(c.canReviewMembers, isFalse);
    expect(c.pendingMemberCount, 0);
    expect(c.pendingMembers, isEmpty);
    expect(c.memberReviewHistory, isEmpty);
  });
  test('加载失败保留错误，重试恢复；注销后旧请求不能恢复待办', () async {
    final api = ReviewApi();
    final c = await controller(api);
    addTearDown(c.dispose);
    api.fail = true;
    await c.refreshPendingMembersCount();
    expect(c.memberReviewError, contains('网络失败'));
    api.fail = false;
    await c.refreshPendingMembersCount();
    expect(c.memberReviewError, isNull);
    final gate = Completer<bool>();
    api.gate = gate;
    final old = c.refreshPendingMembersCount();
    await c.leaveUnit();
    gate.complete(true);
    await old;
    expect(c.canReviewMembers, isFalse);
    expect(c.pendingMembers, isEmpty);
    expect(c.pendingMemberCount, 0);
  });
  testWidgets('审批页展示申请说明，同意后移出待办并显示处理记录，支持大字体', (tester) async {
    final api = ReviewApi();
    final c = await controller(api);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: MemberReviewPage(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试申请人'), findsOneWidget);
    expect(find.text('已在语音名单'), findsOneWidget);
    expect(find.text('申请单位：测试单位'), findsOneWidget);
    expect(find.text('申请说明：调入'), findsOneWidget);
    await tester.tap(find.text('同意入队'));
    await tester.pumpAndSettle();
    expect(api.approvals, 1);
    expect(find.text('暂无待审批申请'), findsOneWidget);
    await tester.tap(find.text('已处理'));
    await tester.pumpAndSettle();
    expect(find.text('测试申请人 · 已同意'), findsOneWidget);
    expect(find.textContaining('处理人：管理员甲'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump();
  });
  testWidgets('驳回需确认，取消不写入；查询失败显示重试而非空列表', (tester) async {
    final api = ReviewApi();
    final c = await controller(api);
    await tester.pumpWidget(MaterialApp(home: MemberReviewPage(controller: c)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驳回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.rejections, 0);
    api.fail = true;
    await c.refreshPendingMembersCount();
    await tester.pumpAndSettle();
    expect(find.textContaining('审批信息加载失败'), findsOneWidget);
    expect(find.text('暂无待审批申请'), findsNothing);
    api.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('审批信息加载失败'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump();
  });
}
