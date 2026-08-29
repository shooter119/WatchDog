import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchdog/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('watchdog/storage');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('可读取平台返回的可用空间', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'availableBytes');
          return 256 * 1024 * 1024;
        });

    expect(await StorageService.availableBytes(), 256 * 1024 * 1024);
  });

  test('平台空间能力不可用时返回 null，不阻断业务', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw MissingPluginException();
        });

    expect(await StorageService.availableBytes(), isNull);
  });

  test('可请求打开系统存储设置', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openStorageSettings');
          return true;
        });

    expect(await StorageService.openStorageSettings(), isTrue);
  });

}
