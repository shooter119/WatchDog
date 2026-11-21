import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/watermark_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('拍摄方向配置', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('旧配置和非法值回退横屏，竖屏可完整持久化', () async {
      SharedPreferences.setMockInitialValues({
        'watermark_settings_v1': jsonEncode({'unitTitle': '旧设置'}),
      });
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.landscape,
      );

      SharedPreferences.setMockInitialValues({
        'watermark_settings_v1': jsonEncode({'captureOrientation': 'sideways'}),
      });
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.landscape,
      );

      await WatermarkSettings.save(
        WatermarkSettings.defaults.copyWith(
          captureOrientation: CameraCaptureOrientation.portrait,
        ),
      );
      expect(
        (await WatermarkSettings.load()).captureOrientation,
        CameraCaptureOrientation.portrait,
      );
    });
  });
}
