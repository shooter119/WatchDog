import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/core/network/api_config.dart';
import 'package:watchdog/core/network/api_http_transport.dart';
import 'package:watchdog/design_system/design_system.dart';
import 'package:watchdog/features/map/data/map_repository.dart';
import 'package:watchdog/features/map/ui/orthomap_page.dart';

OrthomapGateway _makeGateway({
  required List<Map<String, dynamic>> maps,
  bool authenticated = true,
  bool throwOnFetch = false,
  ChangeNotifier? authListenable,
  bool Function()? isAuthenticatedFn,
}) {
  return OrthomapGateway(
    fetchMaps: () async {
      if (throwOnFetch) throw Exception('网络错误');
      return maps;
    },
    mapTileUrl: (id, z, x, y) =>
        'https://example.test/api/maps/$id/tiles/$z/$x/$y.jpg?unit=unit-a',
    mapTileHeaders: () => const {'Authorization': 'Bearer private-token'},
    isAuthenticated: isAuthenticatedFn ?? () => authenticated,
    sessionTokenHash: () => 'private-token'.hashCode,
    authListenable: authListenable,
  );
}

void main() {
  testWidgets('单位无影像时显示空态', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: OrthomapPage(gateway: _makeGateway(maps: const [])),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本单位暂无地图，请联系管理员导入影像'), findsOneWidget);
  });

  testWidgets('拉取失败时展示错误占位与重试按钮', (tester) async {
    var shouldFail = true;
    final gateway = OrthomapGateway(
      fetchMaps: () async {
        if (shouldFail) throw Exception('boom');
        return const [];
      },
      mapTileUrl: (id, z, x, y) => 'https://example.test/$id/$z/$x/$y.jpg',
      mapTileHeaders: () => const {},
      isAuthenticated: () => true,
      sessionTokenHash: () => 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: OrthomapPage(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('地图暂时无法加载，请检查网络或重新认证'), findsOneWidget);

    shouldFail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('本单位暂无地图，请联系管理员导入影像'), findsOneWidget);
  });

  testWidgets('演示标识、地图视图、恢复全图与认证失效即时拦截', (tester) async {
    var authed = true;
    final authNotifier = ChangeNotifier();
    addTearDown(authNotifier.dispose);

    final gateway = _makeGateway(
      maps: const [
        {
          'id': 'demo',
          'name': '演示影像',
          'demo': true,
          'width': 2048,
          'height': 1536,
          'maxZoom': 3,
          'tileSize': 256,
        },
      ],
      authListenable: authNotifier,
      isAuthenticatedFn: () => authed,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildCommandTheme(Brightness.light),
        home: OrthomapPage(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('非真实现场'), findsWidgets);

    await tester.tap(find.text('演示影像'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.textContaining('不可用于定位'), findsWidgets);

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final moved = viewer.transformationController!.value.clone()
      ..setEntry(0, 3, 123);
    viewer.transformationController!.value = moved;
    await tester.pump();
    await tester.tap(find.byTooltip('恢复全图'));
    await tester.pump();
    expect(viewer.transformationController!.value.entry(0, 3), isNot(123));

    // 模拟认证失效立即锁屏
    authed = false;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    authNotifier.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('认证已失效，请返回后重新认证'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('360dp @ 130% 字号昼白/暗曜零溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCommandTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: OrthomapPage(
            gateway: _makeGateway(
              maps: const [
                {
                  'id': 'demo',
                  'name': '演示园区高清正射影像超长名称测试',
                  'demo': true,
                  'width': 2048,
                  'height': 1536,
                  'maxZoom': 3,
                },
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  test('MapRepository 瓦片认证只在头中传递', () {
    final transportA = ApiHttpTransport(
      ApiConfig(
        baseUrl: 'https://example.test',
        incidentId: '',
        unitId: 'unit-a',
        sessionToken: 'private-token',
      ),
    );
    addTearDown(transportA.dispose);
    final repoA = MapRepository(transportA);

    expect(
      repoA.mapTileUrl('demo', 0, 0, 0),
      'https://example.test/api/maps/demo/tiles/0/0/0.jpg?unit=unit-a',
    );
    expect(repoA.mapTileHeaders()['Authorization'], 'Bearer private-token');

    final transportB = ApiHttpTransport(
      ApiConfig(
        baseUrl: 'https://example.test',
        incidentId: '',
        unitId: 'unit-b',
      ),
    );
    addTearDown(transportB.dispose);
    final repoB = MapRepository(transportB);

    expect(
      repoA.mapTileUrl('demo', 0, 0, 0),
      isNot(repoB.mapTileUrl('demo', 0, 0, 0)),
    );
  });
}
