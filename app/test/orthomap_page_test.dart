import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/api/api_client.dart';

void main() {
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
