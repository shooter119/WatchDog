import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const int _maxModuleLines = 500;
const int _maxModelsBarrelLines = 60;

const Set<String> _coreForbiddenDirs = <String>{
  'features',
  'models',
  'api',
  'pages',
  'state',
};

const Set<String> _featureDataForbiddenDirs = <String>{
  'models',
  'api',
  'pages',
  'state',
};

/// 唯一允许的跨 Feature 依赖白名单：`key_sites` 仓储单向读取 `incident` 模型。
const Map<String, Set<String>> _allowedCrossFeatureEdges = <String, Set<String>>{
  'features/key_sites/data/key_sites_repository.dart': <String>{
    'features/incident/data/models/incident.dart',
  },
};

/// 唯一允许的 `features/*/data` -> `models/` 转发白名单（受后端字节校验约束）。
const Map<String, Set<String>> _allowedLegacyModelForwards =
    <String, Set<String>>{
      'features/key_sites/data/models/key_site_schema.dart': <String>{
        'models/key_site_schema.dart',
      },
    };

const Set<String> _expectedModelsClasses = <String>{
  'Entry',
  'Incident',
  'ExternalDispatchedForce',
  'ExternalIncident',
  'IncidentForce',
  'Station',
  'IncidentEvent',
  'NoteCategory',
  'Note',
  'Firefighter',
  'Hotword',
  'ParsePerson',
  'VoiceIntent',
  'ParseResult',
  'ChatMessage',
  'VisionAnalysis',
  'CalcConfig',
  'AmapLocation',
  'WeatherInfo',
  'RouteEndpointInfo',
  'RouteOriginInfo',
  'RouteWeatherLive',
  'RouteWeatherForecast',
  'TrafficSummary',
  'CongestedSegment',
  'RouteStepInfo',
  'DrivingRoutePlan',
  'RouteDestinationCandidate',
  'RouteTrafficInfo',
  'SceneMapBootstrap',
};

const Map<String, Set<String>> _expectedOtherLegacyBarrels =
    <String, Set<String>>{
      'models/admin_login.dart': <String>{'AdminCapability', 'AdminLoginCode'},
      'models/hazmat.dart': <String>{
        'HazmatItem',
        'HazmatSyncResult',
        'HazmatAiResult',
      },
      'models/key_sites.dart': <String>{
        'KeySiteSummary',
        'KeySiteSource',
        'KeySiteEntry',
        'KeySiteVersion',
        'IncidentKeySiteLink',
      },
      'models/video_resources.dart': <String>{'VideoResource'},
      'models/water_source.dart': <String>{
        'WaterSourceCategory',
        'WaterSourceStatus',
        'WaterIntakeMethod',
        'WaterSource',
        'WaterSourceSummary',
        'WaterSourceListResult',
      },
    };

const Set<String> _expectedApiAuxClasses = <String>{
  'ApiException',
  'IncidentCreateConflictException',
  'SseEvent',
  'SseLineParser',
  'EntryConflictException',
  'UnitMember',
};

const Set<String> _expectedApiPublicFields = <String>{
  'baseUrl',
  'incidentId',
  'apiToken',
  'deviceId',
  'actorName',
  'unitId',
  'unitCode',
  'sessionToken',
  'onAuthenticationFailure',
};

const Set<String> _expectedApiPublicMethods = <String>{
  // ApiClient 门面自身 (7)
  'forIncident',
  'forAssistant',
  'cacheScope',
  'realtimeAsrUri',
  'cancelChatRequest',
  'dispose',
  'isAuthenticationFailure',
  // SyncRepository (7)
  'realtimeSyncUri',
  'realtimeSyncHeaders',
  'fetchSyncBootstrap',
  'fetchSyncCheckpoint',
  'fetchSyncEvents',
  'submitReviewedOperation',
  'uploadOfflineOperations',
  // LogRepository (1)
  'sendLogs',
  // AuthRepository (17)
  'fetchAdminCapability',
  'confirmAdminLogin',
  'fetchAuthIdentity',
  'fetchLoginDevices',
  'revokeLoginDevice',
  'verifyUnit',
  'applyUnitMembership',
  'fetchUnitMembers',
  'fetchMemberReviewCapability',
  'fetchMemberReviewHistory',
  'fetchPendingMembers',
  'approveMember',
  'rejectMember',
  'addUnitMember',
  'updateUnitMember',
  'refreshSession',
  'logout',
  // MonitorRepository (5)
  'fetchEntries',
  'createEntry',
  'updateEntry',
  'markExited',
  'fetchConfig',
  // SettingsRepository (4)
  'fetchUserSettings',
  'pushUserSettings',
  'fetchProfile',
  'saveProfile',
  // IncidentRepository (14)
  'createIncidentObservation',
  'fetchIncidents',
  'createIncident',
  'fetchExternalIncidents',
  'reorganizeExternalIncidents',
  'claimExternalIncident',
  'fetchIncident',
  'updateIncidentTitle',
  'archiveIncident',
  'fetchIncidentForces',
  'mergeIncidentForces',
  'saveIncidentForce',
  'deleteIncidentForce',
  'fetchTimeline',
  // IncidentImportRepository (9)
  'fetchIncidentDetails',
  'updateIncidentDetails',
  'createIncidentImport',
  'fetchImportImage',
  'fetchIncidentImport',
  'retryIncidentImport',
  'cancelIncidentImport',
  'applyIncidentImport',
  'fetchIncidentImports',
  // NotesRepository (4)
  'fetchNotes',
  'createNote',
  'updateNote',
  'deleteNote',
  // VoiceRepository (5; realtimeAsrUri 已计入门面自身)
  'realtimeAsrUris',
  'realtimeAsrHeaders',
  'transcribe',
  'transcribeMedia',
  'parse',
  // CopilotRepository (5)
  'fetchChatMessages',
  'sendChatMessage',
  'sendChatMessageStream',
  'analyzeVision',
  'clearChatMessages',
  // RosterRepository (12)
  'fetchFirefighters',
  'addFirefighter',
  'removeFirefighter',
  'fetchHotwords',
  'addHotword',
  'removeHotword',
  'fetchUnitStations',
  'unitStationAccess',
  'addUnitStation',
  'updateUnitStation',
  'fetchStations',
  'createStation',
  // MapRepository (5)
  'fetchMaps',
  'mapTileUrl',
  'mapTileHeaders',
  'fetchRouteTraffic',
  'fetchSceneMapBootstrap',
  // MediaRepository (1)
  'fetchWeather',
  // VideoRepository (4)
  'videoResourceAccess',
  'fetchVideoResources',
  'addVideoResource',
  'updateVideoResource',
  // KeySitesRepository (8)
  'keySiteAccess',
  'keySiteFilters',
  'fetchKeySites',
  'fetchRecentKeySites',
  'fetchKeySite',
  'fetchIncidentKeySite',
  'changeIncidentKeySite',
  'fetchKeySiteImage',
  // HazmatRepository (2)
  'syncHazmats',
  'generateHazmatAiCard',
  // WaterSourcesRepository (5)
  'fetchWaterSources',
  'createWaterSource',
  'updateWaterSource',
  'deleteWaterSource',
  'restoreWaterSource',
};

class _Directive {
  const _Directive({
    required this.kind,
    required this.uri,
    required this.line,
    this.showSymbols,
  });

  final String kind; // import | export | part | part of
  final String uri;
  final int line;
  final Set<String>? showSymbols;
}

/// 剥离 Dart 注释，并将单/双/三引号字符串内容替换为占位空格（保留换行符），
/// 便于精确提取指令与顶层声明而不受注释或字符串干扰。
String _stripCommentsAndStrings(String source) {
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
      out.write(' ' * endQuote.length);
      i += endQuote.length;
      while (i < len) {
        if (!isRaw && source[i] == r'\') {
          out.write('  ');
          i += 2;
          continue;
        }
        if (source.startsWith(endQuote, i)) {
          out.write(' ' * endQuote.length);
          i += endQuote.length;
          break;
        }
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 剥离 Dart 注释但保留字符串字面量，供提取 `import`/`export`/`part` URI 使用。
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
  r'''(?:^|\s)(import|export|part\s+of|part)\s+['"]([^'"]+)['"]([^;]*);''',
  multiLine: true,
);

final RegExp _libraryPartOfRe = RegExp(
  r'''(?:^|\s)part\s+of\s+(?!['"])([A-Za-z_][A-Za-z0-9_.]*)\s*;''',
  multiLine: true,
);

List<_Directive> _parseDirectives(String source) {
  final stripped = _stripCommentsOnly(source);
  final result = <_Directive>[];
  for (final m in _directiveRe.allMatches(stripped)) {
    final rawKind = m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
    final uri = m.group(2)!;
    final tail = m.group(3) ?? '';
    final line = '\n'.allMatches(stripped.substring(0, m.start)).length + 1;
    Set<String>? showSymbols;
    final showMatch = RegExp(r'\bshow\s+([A-Za-z0-9_,\s]+)').firstMatch(tail);
    if (showMatch != null) {
      showSymbols = showMatch
          .group(1)!
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
    }
    result.add(
      _Directive(kind: rawKind, uri: uri, line: line, showSymbols: showSymbols),
    );
  }
  return result;
}

/// 将相对或 `package:watchdog/` URI 解析为相对 `lib/` 的规范路径（外部包或 `dart:` 返回 null）。
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

/// 三色 DFS 环路检测，返回检测到的所有环路描述。
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

String? _featureOf(String relFromLib) {
  if (!relFromLib.startsWith('features/')) return null;
  final parts = relFromLib.split('/');
  return parts.length >= 2 ? parts[1] : null;
}

Set<String> _extractTopLevelClasses(String source) {
  final clean = _stripCommentsAndStrings(source);
  final classes = <String>{};
  final re = RegExp(
    r'^(?:abstract\s+|base\s+|final\s+|interface\s+|sealed\s+|mixin\s+)*'
    r'(?:class|enum|typedef)\s+([A-Za-z][A-Za-z0-9_]*)\b',
    multiLine: true,
  );
  for (final m in re.allMatches(clean)) {
    classes.add(m.group(1)!);
  }
  return classes;
}

Set<String> _collectExportedClasses(
  Directory libDir,
  String entryRelPath, {
  Set<String>? visited,
}) {
  final seen = visited ?? <String>{};
  if (!seen.add(entryRelPath)) return <String>{};
  final file = File('${libDir.path}/$entryRelPath');
  expect(file.existsSync(), isTrue, reason: '缺失文件: lib/$entryRelPath');
  final src = file.readAsStringSync();
  final symbols = _extractTopLevelClasses(src);
  for (final d in _parseDirectives(src)) {
    if (d.kind != 'export') continue;
    final target = _resolveLibRelativePath(entryRelPath, d.uri);
    if (target == null) continue;
    final exported = _collectExportedClasses(libDir, target, visited: seen);
    if (d.showSymbols != null) {
      symbols.addAll(exported.intersection(d.showSymbols!));
    } else {
      symbols.addAll(exported);
    }
  }
  return symbols;
}

({Set<String> fields, Set<String> methods}) _extractClassAndMixinMembers(
  String source,
) {
  final clean = _stripCommentsAndStrings(source);
  final fields = <String>{};
  final methods = <String>{};
  final headerRe = RegExp(
    r'\b(?:abstract\s+)?(?:class|mixin)\s+([A-Za-z_]\w*)[^{]*\{',
  );
  for (final m in headerRe.allMatches(clean)) {
    final className = m.group(1)!;
    var pos = m.end;
    var depth = 1;
    var paren = 0;
    var inArrow = false;
    var stmtStart = pos;
    final members = <(String, String)>[];

    while (pos < clean.length && depth > 0) {
      final ch = clean[pos];
      if (ch == '(') {
        paren++;
        pos++;
      } else if (ch == ')') {
        paren--;
        pos++;
      } else if (ch == '=' &&
          pos + 1 < clean.length &&
          clean[pos + 1] == '>' &&
          depth == 1 &&
          paren == 0) {
        inArrow = true;
        pos += 2;
      } else if (ch == '{' && paren == 0) {
        if (depth == 1 && !inArrow) {
          members.add(('block', source.substring(stmtStart, pos).trim()));
        }
        depth++;
        pos++;
      } else if (ch == '}' && paren == 0) {
        depth--;
        pos++;
        if (depth == 1 && !inArrow) {
          stmtStart = pos;
        }
      } else if (ch == ';' && depth == 1 && paren == 0) {
        members.add(('semi', source.substring(stmtStart, pos).trim()));
        inArrow = false;
        pos++;
        stmtStart = pos;
      } else {
        pos++;
      }
    }

    for (final (kind, raw) in members) {
      final cleanRaw = _stripCommentsOnly(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleanRaw.isEmpty) continue;
      if (RegExp('^$className\\s*\\(').hasMatch(cleanRaw) ||
          RegExp('^const\\s+$className\\s*\\(').hasMatch(cleanRaw)) {
        continue;
      }
      if (kind == 'semi' && !cleanRaw.contains('=>')) {
        final beforeEq = cleanRaw.split('=').first.trim();
        final fm = RegExp(r'([A-Za-z_]\w*)$').firstMatch(beforeEq);
        if (fm != null && !fm.group(1)!.startsWith('_')) {
          fields.add(fm.group(1)!);
        }
        continue;
      }
      final sig = cleanRaw.contains('=>')
          ? cleanRaw.split('=>').first.trim()
          : cleanRaw.replaceFirst(RegExp(r'\s+async\*?\s*$'), '').trim();
      final getterMatch = RegExp(r'\bget\s+([A-Za-z_]\w*)$').firstMatch(sig);
      if (getterMatch != null) {
        final name = getterMatch.group(1)!;
        if (!name.startsWith('_')) methods.add(name);
        continue;
      }
      final endParen = sig.lastIndexOf(')');
      if (endParen == -1) continue;
      var p = 0;
      var startParen = endParen;
      while (startParen >= 0) {
        if (sig[startParen] == ')') {
          p++;
        } else if (sig[startParen] == '(') {
          p--;
          if (p == 0) break;
        }
        startParen--;
      }
      final prefix = sig.substring(0, startParen).trim();
      final mm = RegExp(r'([A-Za-z_]\w*)$').firstMatch(prefix);
      if (mm != null && !mm.group(1)!.startsWith('_')) {
        methods.add(mm.group(1)!);
      }
    }
  }
  return (fields: fields, methods: methods);
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
  final files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String _relFromLib(Directory libDir, File file) {
  final normalizedLib = libDir.absolute.path.replaceAll(r'\', '/');
  final normalizedFile = file.absolute.path.replaceAll(r'\', '/');
  final prefix = normalizedLib.endsWith('/') ? normalizedLib : '$normalizedLib/';
  return normalizedFile.substring(prefix.length);
}

void main() {
  final libDir = _resolveLibDir();

  group('M1 架构门禁', () {
    test('1. 文件级依赖无环（core/ 与 features/ 三色 DFS 0 环）', () {
      final files = <File>[
        ..._listDartFiles(Directory('${libDir.path}/core')),
        ..._listDartFiles(Directory('${libDir.path}/features')),
      ];
      expect(files, isNotEmpty);

      final graph = <String, Set<String>>{};
      for (final file in files) {
        final rel = _relFromLib(libDir, file);
        graph.putIfAbsent(rel, () => <String>{});
        final directives = _parseDirectives(file.readAsStringSync());
        for (final d in directives) {
          if (d.kind == 'part of') continue;
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null) continue;
          if (target.startsWith('core/') || target.startsWith('features/')) {
            graph[rel]!.add(target);
          }
        }
      }

      final cycles = _findCycles(graph);
      expect(cycles, isEmpty, reason: '发现文件级循环依赖:\n${cycles.join('\n')}');
    });

    test('2. Feature 目录级依赖无环且跨 Feature 依赖仅限白名单', () {
      final featureFiles = _listDartFiles(Directory('${libDir.path}/features'));
      expect(featureFiles, isNotEmpty);

      final featureGraph = <String, Set<String>>{};
      final illegalCrossFeature = <String>[];

      for (final file in featureFiles) {
        final rel = _relFromLib(libDir, file);
        final srcFeature = _featureOf(rel)!;
        featureGraph.putIfAbsent(srcFeature, () => <String>{});

        for (final d in _parseDirectives(file.readAsStringSync())) {
          if (d.kind == 'part of') continue;
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null) continue;
          final dstFeature = _featureOf(target);
          if (dstFeature == null || dstFeature == srcFeature) continue;

          featureGraph[srcFeature]!.add(dstFeature);
          final allowedTargets =
              _allowedCrossFeatureEdges[rel] ?? const <String>{};
          if (!allowedTargets.contains(target)) {
            illegalCrossFeature.add(
              'lib/$rel:${d.line} 禁止未授权的跨 Feature 依赖 -> lib/$target',
            );
          }
        }
      }

      final cycles = _findCycles(featureGraph);
      expect(cycles, isEmpty, reason: '发现 Feature 级循环依赖:\n${cycles.join('\n')}');
      expect(
        illegalCrossFeature,
        isEmpty,
        reason: '存在未在白名单内的跨 Feature 依赖:\n${illegalCrossFeature.join('\n')}',
      );
    });

    test('3. 分层隔离门禁（core/ 零向上依赖、feature/data 不逆向依赖旧层、模型层 0 跨 Feature）', () {
      final violations = <String>[];

      // 3a. core/ 不得依赖 features/、models/、api/、pages/、state/、main.dart
      for (final file in _listDartFiles(Directory('${libDir.path}/core'))) {
        final rel = _relFromLib(libDir, file);
        final src = file.readAsStringSync();
        if (_libraryPartOfRe.hasMatch(_stripCommentsOnly(src))) {
          violations.add('lib/$rel 禁止使用库名形式 part of');
        }
        for (final d in _parseDirectives(src)) {
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null) continue;
          final firstSeg = target.split('/').first;
          if (_coreForbiddenDirs.contains(firstSeg) || target == 'main.dart') {
            violations.add('lib/$rel:${d.line} core 层禁止依赖 lib/$target');
          }
        }
      }

      // 3b. features/*/data/ 隔离与 models/ 零跨 Feature
      for (final file in _listDartFiles(Directory('${libDir.path}/features'))) {
        final rel = _relFromLib(libDir, file);
        final src = file.readAsStringSync();
        if (_libraryPartOfRe.hasMatch(_stripCommentsOnly(src))) {
          violations.add('lib/$rel 禁止使用库名形式 part of');
        }
        final srcFeature = _featureOf(rel)!;
        final isFeatureModel = RegExp(
          r'^features/[^/]+/data/models/',
        ).hasMatch(rel);

        for (final d in _parseDirectives(src)) {
          final target = _resolveLibRelativePath(rel, d.uri);
          if (target == null) continue;
          final firstSeg = target.split('/').first;
          final allowedForwards =
              _allowedLegacyModelForwards[rel] ?? const <String>{};
          if ((_featureDataForbiddenDirs.contains(firstSeg) ||
                  target == 'main.dart') &&
              !allowedForwards.contains(target)) {
            violations.add('lib/$rel:${d.line} feature/data 禁止反向依赖 lib/$target');
          }
          if (isFeatureModel) {
            final dstFeature = _featureOf(target);
            if (dstFeature != null && dstFeature != srcFeature) {
              violations.add(
                'lib/$rel:${d.line} feature 模型层禁止跨 Feature 依赖 lib/$target',
              );
            }
          }
        }
      }

      // 3c. api/*.dart 禁止库名形式 part of
      for (final file in _listDartFiles(Directory('${libDir.path}/api'))) {
        final rel = _relFromLib(libDir, file);
        if (_libraryPartOfRe.hasMatch(
          _stripCommentsOnly(file.readAsStringSync()),
        )) {
          violations.add('lib/$rel 禁止使用库名形式 part of');
        }
      }

      expect(violations, isEmpty, reason: '存在分层隔离违例:\n${violations.join('\n')}');
    });

    test('4. 单文件行数预算（core/、features/*/data/、api/*.dart <= 500 行；models.dart <= 60 行）', () {
      final violations = <String>[];
      final boundedFiles = <File>[
        ..._listDartFiles(Directory('${libDir.path}/core')),
        ..._listDartFiles(Directory('${libDir.path}/features')),
        ..._listDartFiles(Directory('${libDir.path}/api')),
      ];
      expect(boundedFiles, isNotEmpty);

      for (final file in boundedFiles) {
        final rel = _relFromLib(libDir, file);
        final lineCount = file.readAsLinesSync().length;
        if (lineCount > _maxModuleLines) {
          violations.add('lib/$rel 行数 $lineCount 超出上限 $_maxModuleLines');
        }
      }

      final modelsBarrel = File('${libDir.path}/models/models.dart');
      final modelsLines = modelsBarrel.readAsLinesSync().length;
      if (modelsLines > _maxModelsBarrelLines) {
        violations.add(
          'lib/models/models.dart 行数 $modelsLines 超出上限 $_maxModelsBarrelLines',
        );
      }

      expect(violations, isEmpty, reason: '存在行数超标文件:\n${violations.join('\n')}');
    });

    test('5. 门面与转发出口符号完整性校验（30 模型 + 17 其他模型 + 6 附带类 + 115 方法 + 9 字段 + schema 首行）', () {
      // 5a. models/models.dart 严格导出 30 个历史顶层类（不多不少）
      final exportedModels = _collectExportedClasses(libDir, 'models/models.dart');
      expect(
        exportedModels,
        equals(_expectedModelsClasses),
        reason:
            'models/models.dart 导出符号偏差: 缺失=${_expectedModelsClasses.difference(exportedModels)}, '
            '多余=${exportedModels.difference(_expectedModelsClasses)}',
      );

      // 5b. 其余 4 个旧模型转发出口精确对齐
      for (final entry in _expectedOtherLegacyBarrels.entries) {
        final exported = _collectExportedClasses(libDir, entry.key);
        expect(
          exported,
          equals(entry.value),
          reason: '${entry.key} 导出符号偏差: 实际=$exported 期望=${entry.value}',
        );
      }

      // 5c. api/api_client.dart 导出全部 6 个附带类（且不泄露多余公共类）
      final apiExportedAll = _collectExportedClasses(libDir, 'api/api_client.dart');
      final apiAuxExported = apiExportedAll.difference(const <String>{'ApiClient'});
      expect(
        apiAuxExported,
        equals(_expectedApiAuxClasses),
        reason:
            'api_client.dart 导出附带类偏差: 缺失=${_expectedApiAuxClasses.difference(apiAuxExported)}, '
            '多余=${apiAuxExported.difference(_expectedApiAuxClasses)}',
      );

      // 5d. 聚合 api_client.dart 与 3 个 part 文件校验 9 个公开字段与 110 个公开方法/getter
      final apiFiles = <String>[
        'api/api_client.dart',
        'api/api_client_ops_facade.dart',
        'api/api_client_command_facade.dart',
        'api/api_client_tools_facade.dart',
      ];
      final declaredFields = <String>{};
      final declaredMethods = <String>{};
      for (final rel in apiFiles) {
        final file = File('${libDir.path}/$rel');
        expect(file.existsSync(), isTrue, reason: '缺失门面文件: lib/$rel');
        final parsed = _extractClassAndMixinMembers(file.readAsStringSync());
        declaredFields.addAll(parsed.fields);
        declaredMethods.addAll(parsed.methods);
      }

      expect(
        declaredFields,
        equals(_expectedApiPublicFields),
        reason:
            'ApiClient 公开字段偏差: 缺失=${_expectedApiPublicFields.difference(declaredFields)}, '
            '多余=${declaredFields.difference(_expectedApiPublicFields)}',
      );
      expect(
        declaredMethods,
        equals(_expectedApiPublicMethods),
        reason:
            'ApiClient 公开方法偏差: 缺失=${_expectedApiPublicMethods.difference(declaredMethods)}, '
            '多余=${declaredMethods.difference(_expectedApiPublicMethods)}',
      );
      expect(declaredMethods.length, 115);

      // 5e. models/key_site_schema.dart 首行保持生成标记注释
      final schemaFile = File('${libDir.path}/models/key_site_schema.dart');
      expect(schemaFile.existsSync(), isTrue);
      final firstLine = schemaFile.readAsLinesSync().first;
      expect(
        firstLine,
        '// Generated by scripts/generate-key-site-schema.mjs; edit the canonical JSON.',
      );
    });

    test('自检：三色 DFS 能准确检出环路且不误报无环图', () {
      expect(
        _findCycles(<String, Set<String>>{
          'a': <String>{'b'},
          'b': <String>{'c'},
          'c': <String>{},
        }),
        isEmpty,
      );
      final detected = _findCycles(<String, Set<String>>{
        'a': <String>{'b'},
        'b': <String>{'c'},
        'c': <String>{'a'},
      });
      expect(detected, isNotEmpty);
      expect(detected.first, contains('a -> b -> c -> a'));
    });
  });
}
