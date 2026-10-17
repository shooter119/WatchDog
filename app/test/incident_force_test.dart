import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/models/models.dart';

void main() {
  test('旧数据数量已知，新数据支持每项待补充与真实零', () {
    final legacy = IncidentForce.fromJson({
      'vehicle_count': 0,
      'personnel_count': 7,
    });
    expect(legacy.quantityLabel, '0车7人');
    final unknown = IncidentForce.fromJson({
      'vehicle_count': 0,
      'vehicle_count_known': false,
      'personnel_count': 0,
      'personnel_count_known': 0,
    });
    expect(unknown.quantityLabel, '车辆待补充 人数待补充');
    expect(unknown.vehicleCountKnown, isFalse);
    expect(unknown.personnelCountKnown, isFalse);
  });
  test('警情汇总保留已知数量和待补充队伍数', () {
    final incident = Incident.fromJson({
      'vehicle_count': 2,
      'unknown_personnel_station_count': 1,
    });
    expect(incident.vehicleCount, 2);
    expect(incident.unknownPersonnelStationCount, 1);
  });
}
