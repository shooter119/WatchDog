import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../services/app_data_epoch.dart';
import '../services/diagnostic_log_service.dart';
import '../services/system_pip.dart';
import '../services/theme_controller.dart';

/// 应用根组件构造回调。
typedef AppWidgetBuilder = Widget Function();

/// 应用启动挂载函数签名（默认 [runApp]，测试可替换为桩函数）。
typedef AppRunner = void Function(Widget app);

/// 应用统一启动引导器。
///
/// 完整继承原 `main.dart` 的串行启动与异常兜底不变量：
/// 1. `WidgetsFlutterBinding.ensureInitialized()` 与 `runApp` 严格处于同一 Zone，
///    避免 Flutter Zone mismatch 告警与插件 Zone 上下文不一致；
/// 2. 异步初始化 `SystemPip.initialize()` 与 `DiagnosticLogService.instance.init()`，
///    并串联挂载 `FlutterError.onError`、`PlatformDispatcher.instance.onError` 与
///    Zone 异常兜底，保证诊断落盘失败永不阻断框架默认错误处理；
/// 3. 串行执行 `ensureAppDataEpoch()` -> `ThemeController.instance.load()` ->
///    `runApp(appBuilder())`，任一前置步骤异常均只降级并记录诊断日志，绝不卡死首帧。
abstract final class AppBootstrap {
  /// 在受保护的错误捕获 Zone 中完成全局初始化并启动应用。
  static void run({
    required AppWidgetBuilder appBuilder,
    DiagnosticLogService? diagnostics,
    VoidCallback? ensureBinding,
    Future<void> Function()? initPip,
    Future<void> Function()? ensureEpoch,
    Future<void> Function()? loadTheme,
    AppRunner? appRunner,
  }) {
    final diag = diagnostics ?? DiagnosticLogService.instance;
    // ensureInitialized 与 runApp 必须处于同一个 Zone，否则 Flutter 会产生
    // Zone mismatch 告警，并可能让插件的 Zone 配置行为不一致。
    runZonedGuarded<void>(
      () {
        (ensureBinding ?? WidgetsFlutterBinding.ensureInitialized)();
        unawaited((initPip ?? SystemPip.initialize)());
        unawaited(diag.init());

        // Flutter framework 异常通常就是开发者看到的红屏；保留 Flutter 默认输出，
        // 同时异步写入诊断日志。日志失败不能阻断 Flutter 的默认错误处理。
        final previousFlutterError = FlutterError.onError;
        FlutterError.onError = (FlutterErrorDetails details) {
          try {
            diag.recordFlutterError(details);
          } catch (_) {}
          if (previousFlutterError != null) {
            previousFlutterError(details);
          } else {
            FlutterError.presentError(details);
          }
        };

        // 捕获未被 Widget 层处理的异步异常；返回 false 让 Flutter 保留默认行为。
        final previousPlatformError = PlatformDispatcher.instance.onError;
        PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
          _safeRecordUncaught(diag, error, stack, source: 'platform_error');
          return previousPlatformError?.call(error, stack) ?? false;
        };

        // 新协议首次启动必须先停止旧保活、清理旧会话/离线队列/模型缓存，
        // 再加载主题与创建控制器，避免旧状态在新 WebSocket 会话建立前短暂泄漏。
        unawaited(
          runStartupSequence(
            appBuilder: appBuilder,
            diagnostics: diag,
            ensureEpoch: ensureEpoch,
            loadTheme: loadTheme,
            appRunner: appRunner,
          ),
        );
      },
      (Object error, StackTrace stack) {
        // 兜住 runApp/Zone 内未处理的同步和异步异常。
        _safeRecordUncaught(diag, error, stack, source: 'zone_error');
      },
    );
  }

  /// 串行启动链：数据纪元清理 -> 主题偏好加载 -> `runApp`。
  ///
  /// 三步必须串行：主题在 `runApp` 之前读取，首帧即呈现正确配色，不会闪白；
  /// 任何一步失败仅降级记录诊断日志，绝不将用户卡在黑屏。
  static Future<void> runStartupSequence({
    required AppWidgetBuilder appBuilder,
    DiagnosticLogService? diagnostics,
    Future<void> Function()? ensureEpoch,
    Future<void> Function()? loadTheme,
    AppRunner? appRunner,
  }) async {
    final diag = diagnostics ?? DiagnosticLogService.instance;
    try {
      await (ensureEpoch ?? ensureAppDataEpoch)();
    } catch (error, stack) {
      // 清理失败不阻断启动；控制器仍会要求重新认证。
      _safeRecordUncaught(diag, error, stack, source: 'data_epoch_reset');
    }

    try {
      await (loadTheme ?? ThemeController.instance.load)();
    } catch (error, stack) {
      // 主题读取失败降级默认配色，不能阻断首帧挂载。
      _safeRecordUncaught(diag, error, stack, source: 'theme_load');
    }

    (appRunner ?? runApp)(appBuilder());
  }

  static void _safeRecordUncaught(
    DiagnosticLogService diagnostics,
    Object error,
    StackTrace stack, {
    required String source,
  }) {
    try {
      diagnostics.recordUncaught(error, stack, source: source);
    } catch (_) {}
  }
}
