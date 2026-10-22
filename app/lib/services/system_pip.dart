import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemPip {
  static const MethodChannel _channel = MethodChannel('watchdog/pip');

  /// PiP 是否正在进行；原生 pipChanged 事件更新
  static final ValueNotifier<bool> isActive = ValueNotifier<bool>(false);

  static bool _supported = false;
  static bool _initialized = false;

  static bool get supported => _supported;

  @visibleForTesting
  static bool debugBypassPlatformCheck = false;

  static bool get _canUseChannel =>
      Platform.isAndroid || debugBypassPlatformCheck;

  static Future<void> initialize() async {
    if (!_canUseChannel) {
      _supported = false;
      return;
    }
    if (_initialized) return;
    _channel.setMethodCallHandler(_handleMethodCall);
    _initialized = true;
    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      _supported = result ?? false;
    } on MissingPluginException {
      _supported = false;
    } on PlatformException {
      _supported = false;
    } catch (_) {
      _supported = false;
    }
  }

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'pipChanged') {
      final args = call.arguments;
      final active = args is Map && args['active'] == true;
      isActive.value = active;
    }
    return null;
  }

  static Future<bool> setAutoEnter({
    required bool enabled,
    int aspectW = 16,
    int aspectH = 9,
  }) async {
    if (!_canUseChannel || !_supported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('setAutoEnter', {
        'enabled': enabled,
        'aspectW': aspectW,
        'aspectH': aspectH,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> enter({
    int aspectW = 16,
    int aspectH = 9,
  }) async {
    if (!_canUseChannel || !_supported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('enter', {
        'aspectW': aspectW,
        'aspectH': aspectH,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> exit() async {
    if (!_canUseChannel || !_supported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('exit');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _initialized = false;
    _supported = false;
    isActive.value = false;
    debugBypassPlatformCheck = false;
  }
}
