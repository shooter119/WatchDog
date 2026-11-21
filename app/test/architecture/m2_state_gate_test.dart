import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const int _maxAppModuleLines = 500;

const Set<String> _requiredM2Stores = <String>{
  'core/sync/sync_store.dart',
  'features/auth/state/session_store.dart',
  'features/incident/state/incident_store.dart',
  'features/roster/state/roster_store.dart',
  'features/settings/state/update_store.dart',
};

const Set<String> _featureStateForbiddenDirs = <String>{
  'models',
  'api',
  'pages',
  'theme',
  'state',
  'app',
};

const Set<String> _shellCleanFiles = <String>{
  'app/shell/command_app_shell.dart',
  'app/shell/command_home_assembly.dart',
  'app/shell/command_home_incident_actions.dart',
  'app/shell/field_tools_gateways.dart',
  'app/shell/field_tools_router.dart',
  'app/shell/onboarding_assembly.dart',
  'app/shell/profile_hub_assembly.dart',
  'app/shell/profile_hub_gateways.dart',
  'app/shell/shell_voice_bridge.dart',
  'app/shell/guest_banner_bar.dart',
  'app/shell/shell_nav_bar.dart',
  'app/shell/shell_monitor_adapter.dart',
  'app/shell/shell_copilot_adapter.dart',
  'app/shell/shell_voice_coordinator.dart',
};

const Set<String> _shellCleanForbiddenDirs = <String>{
  'theme',
  'pages',
  'widgets',
};

class _Directive {
  const _Directive({required this.kind, required this.uri, required this.line});

  final String kind;
  final String uri;
  final int line;
}

String _stripCommentsOnly(String source) {
  final out = StringBuffer();
  var i = 0;
  final len = source.length;
  while (i < len) {
    final c = source[i];
    final next = i + 1 < len ? source[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < len && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      out.write('  ');
      i += 2;
      var depth = 1;
      while (i < len && depth > 0) {
        if (source[i] == '/' && i + 1 < len && source[i + 1] == '*') {
          depth++;
          out.write('  ');
          i += 2;
        } else if (source[i] == '*' && i + 1 < len && source[i + 1] == '/') {
          depth--;
          out.write('  ');
          i += 2;
        } else {
          out.write(source[i] == '\n' ? '\n' : ' ');
          i++;
        }
      }
      continue;
    }
    if (c == "'" || c == '"') {
      final isRaw =
          i > 0 &&
          source[i - 1] == 'r' &&
          (i == 1 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(source[i - 2]));
      final isTriple =
          i + 2 < len && source[i + 1] == c && source[i + 2] == c;
      final endQuote = isTriple ? '$c$c$c' : c;
      out.write(endQuote);
      i += endQuote.length;
      while (i < len) {
        if (!isRaw && source[i] == r'\' && i + 1 < len) {
          out.write(source.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (source.startsWith(endQuote, i)) {
          out.write(endQuote);
          i += endQuote.length;
          break;
        }
        out.write(source[i]);
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

final RegExp _directiveRe = RegExp(
  r'''(?:^|\s)(import|export|part\s+of|part)\s+['"]([^'"]+)['"][^;]*;''',
  multiLine: true,
);

List<_Directive> _parseDirectives(String source) {
  final stripped = _stripCommentsOnly(source);
  final result = <_Directive>[];
  for (final m in _directiveRe.allMatches(stripped)) {
    final kind = m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
    final uri = m.group(2)!;
    final line = '\n'.allMatches(stripped.substring(0, m.start)).length + 1;
    result.add(_Directive(kind: kind, uri: uri, line: line));
  }
  return result;
}

String? _resolveLibRelativePath(String fromRelFromLib, String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:watchdog/')) {
    final target = uri.substring('package:watchdog/'.length);
    final base = Uri.parse('https://lib.local/root/lib/');
    final resolved = base.resolve(target).path;
    return resolved.startsWith('/root/lib/')
        ? resolved.substring('/root/lib/'.length)
        : resolved;
  }
  if (uri.startsWith('package:')) return null;
  final base = Uri.parse('https://lib.local/root/lib/$fromRelFromLib');
  final resolved = base.resolve(uri).path;
  return resolved.startsWith('/root/lib/')
      ? resolved.substring('/root/lib/'.length)
      : resolved;
}

List<String> _findCycles(Map<String, Set<String>> graph) {
  const unvisited = 0;
  const visiting = 1;
  const visited = 2;
  final color = <String, int>{};
  final stack = <String>[];
  final cycles = <String>[];

  void dfs(String node) {
    color[node] = visiting;
    stack.add(node);
    final neighbors = (graph[node] ?? const <String>{}).toList()..sort();
    for (final next in neighbors) {
      if (!graph.containsKey(next)) continue;
      final state = color[next] ?? unvisited;
      if (state == visiting) {
        final startIdx = stack.indexOf(next);
        cycles.add([...stack.sublist(startIdx), next].join(' -> '));
      } else if (state == unvisited) {
        dfs(next);
      }
    }
    stack.removeLast();
    color[node] = visited;
  }

  final nodes = graph.keys.toList()..sort();
  for (final node in nodes) {
    if ((color[node] ?? unvisited) == unvisited) {
      dfs(node);
    }
  }
  return cycles;
}

Directory _resolveLibDir() {
  final direct = Directory('lib');
  if (direct.existsSync()) return direct;
  final nested = Directory('app/lib');
  if (nested.existsSync()) return nested;
  fail('无法定位 app/lib 目录（当前工作目录: ${Directory.current.path}）');
}

List<File> _listDartFiles(Directory dir) {
  if (!dir.existsSync()) return <File>[];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

String _relFromLib(Directory libDir, File file) {
  final normalizedLib = libDir.absolute.path.replaceAll(r'\', '/');
  final normalizedFile = file.absolute.path.replaceAll(r'\', '/');
  final prefix = normalizedLib.endsWith('/') ? normalizedLib : '$normalizedLib/';
  return normalizedFile.substring(prefix.length);
}

String? _featureOfStatePath(String rel) {
  final match = RegExp(r'^features/([^/]+)/state/').firstMatch(rel);
  return match?.group(1);
}

bool _isFeatureStatePath(String rel) => _featureOfStatePath(rel) != null;

bool _isStorePath(String rel) =>
    rel == 'core/sync/sync_store.dart' ||
    (_isFeatureStatePath(rel) && rel.endsWith('_store.dart'));

void main() {
  final libDir = _resolveLibDir();

  group('M2 状态隔离与外壳架构门禁', () {
    test('(a) Store 间 0 互调（*_store.dart + core/sync/sync_store.dart）且禁止跨 Feature state/ 依赖', () {
      final featureStateFiles = _listDartFiles(
        Directory('${libDir.path}/features'),
      ).where((f) => _isFeatureStatePath(_relFromLib(libDir, f))).toList();

      final storeFiles = <File>[
        File('${libDir.path}/core/sync/sync_store.dart'),
        ...featureStateFiles.where((f) => _isStorePath(_relFromLib(libDir, f))),
      ];
      final discoveredRels = storeFiles
          .map((f) => _relFromLib(libDir, f))
          .toSet();
      for (final requiredStore in _requiredM2Stores) {
        expect(
          discoveredRels,
          contains(requiredStore),
          reason: '缺少 M2 必需 Store 文件: lib/$requiredStore',
        );
      }

      final violations = <String>[];
      for (final file in storeFiles) {
        final rel = _relFromLib(libDir, file);
        expect(file.existsSync(), isTrue, reason: '缺失文件: lib/$rel');
        for (final d in _parseDirectives(file.readAsStringSync())) {
          if (d.kind == 'part of') continue;
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null || target == rel) continue;
          if (_isStorePath(target)) {
            violations.add(
              'lib/$rel:${d.line} 禁止 Store 间直接互调 -> lib/$target（跨 Store 事务必须归口 app/orchestrators/）',
            );
          }
        }
      }

      for (final file in featureStateFiles) {
        final rel = _relFromLib(libDir, file);
        final srcFeature = _featureOfStatePath(rel)!;
        for (final d in _parseDirectives(file.readAsStringSync())) {
          if (d.kind == 'part of') continue;
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null || target == rel) continue;
          final dstFeature = _featureOfStatePath(target);
          if (dstFeature != null && dstFeature != srcFeature) {
            violations.add(
              'lib/$rel:${d.line} 禁止跨 Feature state/ 依赖 -> lib/$target',
            );
          } else if (target == 'core/sync/sync_store.dart') {
            violations.add(
              'lib/$rel:${d.line} 禁止 features/*/state/ 依赖 core/sync/sync_store.dart',
            );
          }
        }
      }

      expect(violations, isEmpty, reason: '存在 Store 间互调或跨 Feature state 违例:\n${violations.join('\n')}');
    });

    test('(b) features/*/state/ 零依赖 models/、api/、pages/、theme/、state/、app/', () {
      final stateFiles = _listDartFiles(Directory('${libDir.path}/features'))
          .where((f) => _isFeatureStatePath(_relFromLib(libDir, f)))
          .toList();
      expect(stateFiles, isNotEmpty);

      final violations = <String>[];
      for (final file in stateFiles) {
        final rel = _relFromLib(libDir, file);
        for (final d in _parseDirectives(file.readAsStringSync())) {
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null) continue;
          final firstSeg = target.split('/').first;
          if (_featureStateForbiddenDirs.contains(firstSeg) ||
              target == 'main.dart') {
            violations.add(
              'lib/$rel:${d.line} features/*/state 禁止依赖 lib/$target',
            );
          }
        }
      }

      expect(violations, isEmpty, reason: '存在 Store 层反向依赖违例:\n${violations.join('\n')}');
    });

    test('(c) app/lib/app/ 下所有 Dart 文件行数 <= 500 行', () {
      final appFiles = _listDartFiles(Directory('${libDir.path}/app'));
      expect(appFiles, isNotEmpty);

      final violations = <String>[];
      for (final file in appFiles) {
        final rel = _relFromLib(libDir, file);
        final lines = file.readAsLinesSync().length;
        if (lines > _maxAppModuleLines) {
          violations.add('lib/$rel 行数 $lines 超出上限 $_maxAppModuleLines');
        }
      }

      expect(violations, isEmpty, reason: '存在 app/ 行数超标文件:\n${violations.join('\n')}');
    });

    test('(d) 新外壳洁净文件零旧 theme/、pages/、widgets/ 依赖且 app/ 全域零 pages/ 依赖', () {
      final violations = <String>[];
      for (final rel in _shellCleanFiles) {
        final file = File('${libDir.path}/$rel');
        expect(file.existsSync(), isTrue, reason: '缺失新外壳文件: lib/$rel');
        for (final d in _parseDirectives(file.readAsStringSync())) {
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null) continue;
          final firstSeg = target.split('/').first;
          if (_shellCleanForbiddenDirs.contains(firstSeg)) {
            violations.add(
              'lib/$rel:${d.line} 新外壳核心文件禁止依赖旧层 lib/$target',
            );
          }
        }
      }
      for (final file in _listDartFiles(Directory('${libDir.path}/app'))) {
        final rel = _relFromLib(libDir, file);
        for (final d in _parseDirectives(file.readAsStringSync())) {
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target != null && target.split('/').first == 'pages') {
            violations.add('lib/$rel:${d.line} 新外壳禁止引用旧页面 lib/$target');
          }
        }
      }

      expect(violations, isEmpty, reason: '存在新外壳旧层依赖违例:\n${violations.join('\n')}');
    });

    test('(e) 全图 0 环（app/ + core/ + features/ 及桥接层 state/app_controller.dart）', () {
      final scopedFiles = <File>[
        ..._listDartFiles(Directory('${libDir.path}/app')),
        ..._listDartFiles(Directory('${libDir.path}/core')),
        ..._listDartFiles(Directory('${libDir.path}/features')),
      ];
      expect(scopedFiles, isNotEmpty);

      Map<String, Set<String>> buildGraph(List<File> files) {
        final allowedNodes = files.map((f) => _relFromLib(libDir, f)).toSet();
        final graph = <String, Set<String>>{};
        for (final file in files) {
          final rel = _relFromLib(libDir, file);
          graph.putIfAbsent(rel, () => <String>{});
          for (final d in _parseDirectives(file.readAsStringSync())) {
            if (d.kind == 'part of') continue;
            final target = _resolveLibRelativePath(rel, d.uri);
            if (target != null && allowedNodes.contains(target)) {
              graph[rel]!.add(target);
            }
          }
        }
        return graph;
      }

      final baseCycles = _findCycles(buildGraph(scopedFiles));
      expect(
        baseCycles,
        isEmpty,
        reason: 'app/ + core/ + features/ 发现循环依赖:\n${baseCycles.join('\n')}',
      );

      final withBridge = <File>[
        ...scopedFiles,
        File('${libDir.path}/state/app_controller.dart'),
      ];
      final bridgeCycles = _findCycles(buildGraph(withBridge));
      expect(
        bridgeCycles,
        isEmpty,
        reason: '纳入 state/app_controller.dart 后发现循环依赖:\n${bridgeCycles.join('\n')}',
      );
    });
  });
}
