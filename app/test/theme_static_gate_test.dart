import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _resolveLibDir() {
  final direct = Directory('lib');
  if (direct.existsSync()) return direct;
  final nested = Directory('app/lib');
  if (nested.existsSync()) return nested;
  fail('无法定位 app/lib 目录（当前工作目录: ${Directory.current.path}）');
}

String _relFromLib(Directory libDir, File file) {
  final normalizedLib = libDir.absolute.path.replaceAll(r'\', '/');
  final normalizedFile = file.absolute.path.replaceAll(r'\', '/');
  final prefix = normalizedLib.endsWith('/') ? normalizedLib : '$normalizedLib/';
  return normalizedFile.substring(prefix.length);
}

String? _resolveLibTarget(String fromRelFromLib, String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:watchdog/')) {
    final target = uri.substring('package:watchdog/'.length);
    final resolved = Uri.parse('https://lib.local/root/lib/').resolve(target).path;
    return resolved.startsWith('/root/lib/')
        ? resolved.substring('/root/lib/'.length)
        : resolved;
  }
  if (uri.startsWith('package:')) return null;
  final resolved = Uri.parse('https://lib.local/root/lib/$fromRelFromLib')
      .resolve(uri)
      .path;
  return resolved.startsWith('/root/lib/')
      ? resolved.substring('/root/lib/'.length)
      : resolved;
}

/// 静态门禁：
/// 1. 彻底清退旧版 `lib/theme/`、`lib/pages/`、`lib/widgets/` 目录与全部历史主题符号；
/// 2. 禁止在非 `design_system/` 代码中把 `context.ds` 或 `DsColors` 固化到 `static final`/`static const` 字段；
/// 3. 禁止在 `lib/` 中绕过 `AppLogger` 直接调用原始 `debugPrint(`。
void main() {
  final libDir = _resolveLibDir();

  test('旧版 lib/theme/、lib/pages/、lib/widgets/ 目录已彻底清退', () {
    for (final legacyDir in const <String>['theme', 'pages', 'widgets']) {
      expect(
        Directory('${libDir.path}/$legacyDir').existsSync(),
        isFalse,
        reason: '旧目录 lib/$legacyDir 必须已删除',
      );
    }
  });

  test('lib 中零引用旧主题符号与旧层路径，且禁止将 context.ds / DsColors 固化为静态字段', () {
    final offenders = <String>[];
    final legacySymbolPattern = RegExp(
      r'\b(AppColors|AppPalette|AppTextStyles|AppSpacing|AppRadius|AppFonts)\b',
    );
    final directivePattern = RegExp(
      r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
    );
    final staticDsCachePattern = RegExp(
      r'static\s+(?:final|const|late\s+final)[^;\n]*(?:context\.ds|DsColors\.)',
    );
    final rawDebugPrintPattern = RegExp(r'\bdebugPrint\s*\(');
    const forbiddenRootDirs = <String>{'theme', 'pages', 'widgets'};

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = _relFromLib(libDir, entity);
      final isDesignSystem = rel.startsWith('design_system/');
      final isAppLogger = rel == 'core/diagnostics/app_logger.dart';
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final code = line.trimLeft();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        if (legacySymbolPattern.hasMatch(line)) {
          offenders.add('lib/$rel:${i + 1} 残留旧主题符号: $code');
        }
        final directiveMatch = directivePattern.firstMatch(line);
        if (directiveMatch != null) {
          final target = _resolveLibTarget(rel, directiveMatch.group(1)!);
          if (target != null &&
              forbiddenRootDirs.contains(target.split('/').first)) {
            offenders.add('lib/$rel:${i + 1} 引用已退役旧层路径: lib/$target');
          }
        }
        if (!isDesignSystem && staticDsCachePattern.hasMatch(line)) {
          offenders.add('lib/$rel:${i + 1} 禁止静态字段缓存主题色: $code');
        }
        if (!isAppLogger && rawDebugPrintPattern.hasMatch(line)) {
          offenders.add('lib/$rel:${i + 1} 禁止直接调用 debugPrint，必须走 AppLogger');
        }
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
