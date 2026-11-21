import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/models/admin_login.dart';
import 'package:watchdog/models/hazmat.dart';
import 'package:watchdog/models/key_sites.dart';
import 'package:watchdog/models/models.dart';
import 'package:watchdog/models/video_resources.dart';

class _PolymorphicAsrApiClient extends ApiClient {
  _PolymorphicAsrApiClient({
    required super.baseUrl,
    required super.incidentId,
    required this.customUris,
  });

  final List<Uri> customUris;
  int realtimeAsrUrisCalls = 0;

  @override
  List<Uri> realtimeAsrUris() {
    realtimeAsrUrisCalls++;
    return customUris;
  }
}

class _PolymorphicCancelApiClient extends ApiClient {
  _PolymorphicCancelApiClient({
    required super.baseUrl,
    required super.incidentId,
  });

  int cancelCalls = 0;
  bool superCancelInvoked = false;

  @override
  void cancelChatRequest() {
    cancelCalls++;
    super.cancelChatRequest();
    superCancelInvoked = true;
  }
}

class _MixinOverrideApiClient extends ApiClient {
  _MixinOverrideApiClient()
    : super(
        baseUrl: 'https://api.example.test',
        incidentId: 'inc-1',
        unitId: 'unit-1',
        actorName: '张三',
      );

  @override
  Future<List<Entry>> fetchEntries({bool activeOnly = false}) async =>
      const <Entry>[];

  @override
  Future<List<Note>> fetchNotes() async => const <Note>[];

  @override
  String mapTileUrl(String id, int z, int x, int y) =>
      'override:${super.mapTileUrl(id, z, x, y)}';
}

void main() {
  group('ApiClient 门面多态与兼容性回归', () {
    test('子类覆写 realtimeAsrUris() 时 realtimeAsrUri() 走多态分发返回子类首项', () {
      final expected = Uri.parse('wss://custom-asr.example.test/api/asr/stream');
      final fallback = Uri.parse('wss://backup-asr.example.test/api/asr/stream');
      final client = _PolymorphicAsrApiClient(
        baseUrl: 'https://api.example.test',
        incidentId: 'inc-1',
        customUris: <Uri>[expected, fallback],
      );
      addTearDown(client.dispose);

      expect(client.realtimeAsrUri(), expected);
      expect(client.realtimeAsrUrisCalls, 1);
    });

    test('子类覆写 cancelChatRequest() 时 dispose() 触发子类覆写并可调用 super', () {
      final client = _PolymorphicCancelApiClient(
        baseUrl: 'https://api.example.test',
        incidentId: 'inc-1',
      );

      client.dispose();

      expect(client.cancelCalls, 1);
      expect(client.superCancelInvoked, isTrue);
    });

    test('三组私有 Mixin 方法均支持子类 @override 与 super.* 调用', () async {
      final client = _MixinOverrideApiClient();
      addTearDown(client.dispose);

      expect(await client.fetchEntries(), isEmpty);
      expect(await client.fetchNotes(), isEmpty);
      expect(
        client.mapTileUrl('m1', 12, 3, 4),
        'override:https://api.example.test/api/maps/m1/tiles/12/3/4.jpg?unit=unit-1',
      );
    });

    test('公开字段、forIncident/forAssistant、cacheScope 与附带导出符号完整可用', () {
      ApiException? captured;
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        incidentId: 'inc-1',
        apiToken: 'tok',
        deviceId: 'dev-1',
        actorName: '张三',
        unitId: 'unit-1',
        unitCode: '1001',
        sessionToken: 'sess-1',
        onAuthenticationFailure: (err) => captured = err,
      );
      addTearDown(client.dispose);

      expect(client.baseUrl, 'https://api.example.test');
      expect(client.incidentId, 'inc-1');
      expect(client.apiToken, 'tok');
      expect(client.deviceId, 'dev-1');
      expect(client.actorName, '张三');
      expect(client.unitId, 'unit-1');
      expect(client.unitCode, '1001');
      expect(client.sessionToken, 'sess-1');
      expect(client.cacheScope, 'https://api.example.test|unit-1|张三');

      final other = client.forIncident('inc-2');
      addTearDown(other.dispose);
      expect(other.incidentId, 'inc-2');
      expect(other.unitId, 'unit-1');
      other.onAuthenticationFailure?.call(
        ApiException('expired', code: 'SESSION_EXPIRED'),
      );
      expect(captured?.code, 'SESSION_EXPIRED');

      final assistant = client.forAssistant();
      addTearDown(assistant.dispose);
      expect(assistant.incidentId, '');
      expect(assistant.sessionToken, 'sess-1');

      expect(
        ApiClient.isAuthenticationFailure(
          ApiException('expired', code: 'SESSION_EXPIRED'),
        ),
        isTrue,
      );
      expect(ApiClient.isAuthenticationFailure(StateError('other')), isFalse);

      // 校验 6 个附带类与旧模型转发出口类型均可用
      expect(const SseEvent.done().done, isTrue);
      expect(SseLineParser(), isA<SseLineParser>());
      expect(
        const UnitMember(
          id: 'u1',
          unitId: 'unit-1',
          realName: '张三',
          role: 'member',
          status: 'active',
          reviewStatus: 'approved',
        ).realName,
        '张三',
      );
      expect(
        EntryConflictException(
          'conflict',
          Entry(
            id: 'e1',
            name: '张三',
            pressureMpa: 28,
            durationMin: 30,
            entryAt: 1000,
            exitAt: 1801000,
            source: 'voice',
          ),
        ).message,
        'conflict',
      );
      expect(
        IncidentCreateConflictException(
          'exists',
          Incident(
            id: 'inc-1',
            number: 'INC-001',
            title: '示例警情',
            status: 'active',
            createdAt: 1000,
            lastActivityAt: 1000,
          ),
        ).existing.id,
        'inc-1',
      );
      expect(AdminLoginCode.parse('invalid'), isNull);
      expect(
        const HazmatSyncResult(
          items: [],
          deletedIds: [],
          serverTime: 100,
        ).serverTime,
        100,
      );
      expect(
        const IncidentKeySiteLink(
          siteId: 'ks1',
          name: '示例建筑',
          address: '示例路 1 号',
          version: 1,
          linkedBy: 'u1',
          linkedByName: '张三',
          linkedAt: 1000,
        ).siteId,
        'ks1',
      );
      expect(
        const VideoResource(
          id: 'v1',
          name: '示例画面',
          streamUrl: 'https://example.test/v1',
        ).id,
        'v1',
      );
    });
  });
}
