import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';
import 'package:watchdog/pages/orthomap_page.dart';
import 'package:watchdog/state/app_controller.dart';

class _MapApi extends ApiClient {
  final List<Map<String, dynamic>> maps;
  _MapApi(this.maps) : super(baseUrl: 'https://example.test', incidentId: '');
  @override
  Future<List<Map<String, dynamic>>> fetchMaps() async => maps;
}

void main() {
  testWidgets('单位无影像时显示空态', (tester) async {
    final controller = AppController()..api = _MapApi([]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: OrthomapPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('本单位暂无地图，请联系管理员导入影像'), findsOneWidget);
  });

  testWidgets('演示标识、地图视图和恢复全图入口', (tester) async {
    final controller = AppController()
      ..api = _MapApi([
        {
          'id': 'demo',
          'name': '演示影像',
          'demo': true,
          'width': 2048,
          'height': 1536,
          'maxZoom': 3,
          'tileSize': 256,
        },
      ]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: OrthomapPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('非真实现场'), findsOneWidget);
    await tester.tap(find.text('演示影像'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.textContaining('不可用于定位'), findsOneWidget);
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
    expect(tester.takeException(), isNull);
  });

  test('瓦片认证只在头中传递', () {
    final api = ApiClient(
      baseUrl: 'https://example.test',
      incidentId: '',
      unitId: 'unit-a',
      sessionToken: 'private-token',
    );
    addTearDown(api.dispose);
    expect(
      api.mapTileUrl('demo', 0, 0, 0),
      'https://example.test/api/maps/demo/tiles/0/0/0.jpg?unit=unit-a',
    );
    expect(api.mapTileHeaders()['Authorization'], 'Bearer private-token');
    final other = ApiClient(
      baseUrl: 'https://example.test',
      incidentId: '',
      unitId: 'unit-b',
    );
    addTearDown(other.dispose);
    expect(
      api.mapTileUrl('demo', 0, 0, 0),
      isNot(other.mapTileUrl('demo', 0, 0, 0)),
    );
  });
}
