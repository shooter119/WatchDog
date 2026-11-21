import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/network/network.dart';
import '../../../services/incident_image_draft.dart';
import '../../../services/incident_import_images.dart';
import '../data/incident_import_repository.dart';
import '../data/incident_repository.dart';
import '../data/models/incident.dart';
import '../data/models/incident_force.dart';

const String kGuestDrillIncidentId = 'guest-drill-incident';
const Map<String, String> incidentImportFieldLabels = <String, String>{
  'event_summary': '事件摘要', 'original_category': '原始分类', 'level': '等级',
  'specific_type': '具体类型', 'received_at': '接警时间', 'location': '事发地点',
  'administrative_area': '行政区', 'dispatch_summary': '出动力量',
  'place_type': '场所类型', 'situation': '现场情况', 'trapped': '人员被困',
  'injured': '人员受伤', 'hazardous_materials': '危险物质',
};
const Map<String, String> incidentImportExtraLabels = <String, String>{
  'risks': '风险信息', 'to_confirm': '待核实事项', 'vehicles': '车辆明细',
  'equipment': '通信装备', 'channels': '频道',
};

enum IncidentImportEntryMode { camera, gallery, text }
enum IncidentImportStage { input, polling, confirm }

/// 名录候选项（解耦 `features/roster/`，杜绝跨 Feature 依赖）。
@immutable
class ImportStationOption {
  const ImportStationOption({required this.id, required this.name, this.isUnitStation = false});
  final String id, name;
  final bool isUnitStation;
}

/// 待导入本地图片句柄（隔离 `image_picker` 的 `XFile`）。
class ImportImageFile {
  const ImportImageFile({required this.path, required this.readLength, required this.readBytes});
  final String path;
  final Future<int> Function() readLength;
  final Future<Uint8List> Function() readBytes;
}

typedef ImagePreparer = Future<Uint8List> Function(Map<String, dynamic> input);

/// 警情导入远端能力网关（生产可通过 `fromRepositories` 构造，测试可直接 `implements`）。
class IncidentImportGateway {
  const IncidentImportGateway.fromRepositories({
    required IncidentImportRepository importRepository,
    required IncidentRepository incidentRepository,
    required String incidentId,
    this.cacheScope = '',
    Future<List<ImportStationOption>> Function()? stationOptionsFetcher,
  }) : _importRepo = importRepository,
       _incidentRepo = incidentRepository,
       _incidentId = incidentId,
       _stationOptionsFetcher = stationOptionsFetcher;

  final IncidentImportRepository _importRepo;
  final IncidentRepository _incidentRepo;
  final String _incidentId, cacheScope;
  final Future<List<ImportStationOption>> Function()? _stationOptionsFetcher;

  Future<List<Map<String, dynamic>>> fetchIncidentImports() => _importRepo.fetchIncidentImports();
  Future<Map<String, dynamic>> createIncidentImport({String? text, List<Uint8List> images = const []}) => _importRepo.createIncidentImport(text: text, images: images);
  Future<Map<String, dynamic>> fetchIncidentImport(String taskId) => _importRepo.fetchIncidentImport(taskId);
  Future<Uint8List> fetchImportImage(String taskId, int page) => _importRepo.fetchImportImage(taskId, page);
  Future<Map<String, dynamic>> retryIncidentImport(String taskId, List<int> pages) => _importRepo.retryIncidentImport(taskId, pages);
  Future<Map<String, dynamic>> cancelIncidentImport(String taskId) => _importRepo.cancelIncidentImport(taskId);
  Future<Map<String, dynamic>> applyIncidentImport(String taskId, Map<String, dynamic> body, String opId) => _importRepo.applyIncidentImport(taskId, body, opId);
  Future<Map<String, dynamic>> fetchIncidentDetails() => _importRepo.fetchIncidentDetails();
  Future<Incident> fetchIncident(String incidentId) => _incidentRepo.fetchIncident(incidentId);
  Future<List<IncidentForce>> fetchIncidentForces() => _incidentRepo.fetchIncidentForces(forIncidentId: _incidentId);
  Future<List<ImportStationOption>> fetchStationOptions() => _stationOptionsFetcher?.call() ?? Future<List<ImportStationOption>>.value(const []);
}

/// 警情导入 3 阶段状态机：输入采集 -> 异步解析轮询 -> 结构化核对确认与出动力量编辑。
class IncidentImportStore extends ChangeNotifier {
  IncidentImportStore({
    required this.gateway,
    required Incident incident,
    this.pollInterval = const Duration(seconds: 2),
    ImagePreparer? imagePreparer,
  }) : _currentIncident = incident,
       _imagePreparer = imagePreparer ?? _defaultPrepareImage {
    for (final k in incidentImportFieldLabels.keys) { _fieldValues[k] = ''; }
    for (final k in incidentImportExtraLabels.keys) { _extraValues[k] = ''; }
  }

  static Future<Uint8List> _defaultPrepareImage(Map<String, dynamic> input) =>
      compute(prepareIncidentImage, input);

  final IncidentImportGateway gateway;
  final Duration pollInterval;
  final ImagePreparer _imagePreparer;

  Incident _currentIncident;
  final List<Uint8List> _images = <Uint8List>[];
  final Set<String> _temporaryPaths = <String>{};
  String _inputText = '', _title = '', _contactsText = '';
  int _inputTextRevision = 0, _draftRevision = 0;

  Map<String, dynamic>? _task, _resumeTask, _pendingApply;
  Map<String, dynamic> _currentDetails = const {}, _draftDetails = const {};
  List<Map<String, dynamic>> _forces = <Map<String, dynamic>>[];
  List<IncidentForce> _existingForces = const [];
  List<ImportStationOption> _stationOptions = const [];
  final Map<String, String> _fieldValues = {}, _extraValues = {};

  String? _error, _applyOpId;
  bool _busy = false, _polling = false, _ready = false, _replaceTitle = false;
  bool _acceptIncomplete = false, _reviewed = false, _applied = false, _disposed = false;
  int? _selectedPage;
  Timer? _timer;

  Incident get currentIncident => _currentIncident;
  bool get isGuestIncident => _currentIncident.id == kGuestDrillIncidentId;
  List<Uint8List> get images => List<Uint8List>.unmodifiable(_images);
  String get inputText => _inputText;
  int get inputTextRevision => _inputTextRevision;
  Map<String, dynamic>? get task => _task;
  Map<String, dynamic>? get resumeTask => _resumeTask;
  Map<String, dynamic> get currentDetails => _currentDetails;
  Map<String, dynamic> get draftDetails => _draftDetails;
  List<Map<String, dynamic>> get forces => _forces;
  List<IncidentForce> get existingForces => _existingForces;
  List<ImportStationOption> get stationOptions => _stationOptions;
  String get title => _title;
  Map<String, String> get fieldValues => Map<String, String>.unmodifiable(_fieldValues);
  Map<String, String> get extraValues => Map<String, String>.unmodifiable(_extraValues);
  String get contactsText => _contactsText;
  int get draftRevision => _draftRevision;
  String? get error => _error;
  bool get busy => _busy;
  bool get ready => _ready;
  bool get replaceTitle => _replaceTitle;
  bool get acceptIncomplete => _acceptIncomplete;
  bool get reviewed => _reviewed;
  bool get applied => _applied;
  int? get selectedPage => _selectedPage;
  Map<String, dynamic>? get pendingApply => _pendingApply;

  IncidentImportStage get stage => _task == null
      ? IncidentImportStage.input
      : _ready ? IncidentImportStage.confirm : IncidentImportStage.polling;

  List<dynamic> get pages => (_task?['pages'] as List?) ?? const [];
  List<dynamic> get conflicts => ((_task?['draft'] as Map?)?['conflicts'] as List?) ?? const [];
  bool get multipleIncidents => ((_task?['draft'] as Map?)?['details'] as Map?)?['multiple_incidents'] == true;
  bool get hasFailedPages => pages.any((dynamic p) => p['status'] == 'failed');

  bool get canApply =>
      !_busy &&
      !(multipleIncidents && _selectedPage == null) &&
      !(conflicts.isNotEmpty && !_reviewed) &&
      !(_task?['status'] == 'partial' && !_acceptIncomplete);

  void setInputText(String v) => _inputText = v;
  void setTitle(String v) => _title = v;
  void setExtraValue(String k, String v) => _extraValues[k] = v;
  void setContactsText(String v) => _contactsText = v;
  void setFieldValue(String k, String v) { _fieldValues[k] = v; if (_ready) _notify(); }
  void setReplaceTitle(bool v) { _replaceTitle = v; _notify(); }
  void setAcceptIncomplete(bool v) { _acceptIncomplete = v; _notify(); }
  void setReviewed(bool v) { _reviewed = v; _notify(); }

  void toggleForceSelected(int i, bool selected) { if (i >= 0 && i < _forces.length) { _forces[i]['selected'] = selected; _notify(); } }
  void updateForce(int i, Map<String, dynamic> updated) { if (i >= 0 && i < _forces.length) { _forces[i] = updated; _notify(); } }

  void reportError(Object error) {
    if (_disposed) return;
    var message = error.toString();
    if (error is ApiException) {
      message = (error.statusCode == 404 || error.code == 'IMPORT_NOT_FOUND')
          ? '当前警情在云端不存在或已归档，无法导入'
          : (error.statusCode == 401 || error.code == 'IMPORT_AUTH_REQUIRED')
          ? '请先完成单位认证后再使用警情导入'
          : error.message;
    }
    _error = message;
    _notify();
  }

  Future<T?> _runBusy<T>(Future<T> Function() action, {void Function(Object)? onError}) async {
    if (_busy || _disposed) return null;
    _busy = true; _error = null; _notify();
    try { return await action(); }
    catch (error) { if (onError != null) { onError(error); } else { reportError(error); } return null; }
    finally { if (!_disposed) { _busy = false; _notify(); } }
  }

  Future<void> initialize({Future<List<ImportImageFile>> Function()? recoverLostCameraFiles}) async {
    if (isGuestIncident) {
      reportError('当前处于游客模式，智能分析需连接单位云端服务。请先转为正式队员加入单位。');
      return;
    }
    try {
      final saved = await IncidentImageDraft.load(gateway.cacheScope, _currentIncident.id);
      if (_disposed) return;
      if (saved.isNotEmpty) { _images.addAll(saved); _notify(); }
      if (recoverLostCameraFiles != null) {
        final lost = await recoverLostCameraFiles();
        if (!_disposed && lost.isNotEmpty) await appendImageFiles(lost, fromCamera: true);
      }
      final tasks = await gateway.fetchIncidentImports();
      if (_disposed) return;
      final pending = tasks.where(
        (t) => const ['queued', 'processing', 'ready', 'partial', 'failed'].contains(t['status']),
      );
      if (pending.isNotEmpty) { _resumeTask = pending.first; _notify(); }
    } catch (_) {}
  }

  Future<void> saveDraftSnapshot() =>
      IncidentImageDraft.save(gateway.cacheScope, _currentIncident.id, _images);

  Future<void> appendImageFiles(List<ImportImageFile> files, {bool fromCamera = false}) async {
    if (files.isEmpty) return;
    await _runBusy(() async {
      if (_images.length + files.length > 9) throw const FormatException('每批最多9张图片，请减少选择');
      for (final file in files) {
        if (fromCamera && file.path.isNotEmpty) _temporaryPaths.add(file.path);
        if (await file.readLength() > 60 * 1024 * 1024) throw const FormatException('原始图片过大，请裁切后导入');
        final bytes = await file.readBytes();
        if (bytes.length > 60 * 1024 * 1024) throw const FormatException('原始图片过大，请裁切后导入');
        final prepared = await _imagePreparer(<String, dynamic>{'bytes': bytes});
        if (_disposed) return;
        final total = _images.fold<int>(0, (n, b) => n + b.length) + prepared.length;
        if (total > 25 * 1024 * 1024) throw const FormatException('整批图片不能超过25MB');
        _images.add(prepared);
        _notify();
        await saveDraftSnapshot();
      }
    });
  }

  Future<void> rotateImage(int index) async {
    if (index < 0 || index >= _images.length) return;
    await _runBusy(() async {
      final bytes = await _imagePreparer(<String, dynamic>{'bytes': _images[index], 'turns': 1});
      if (_disposed) return;
      _images[index] = bytes;
      _notify();
      await saveDraftSnapshot();
    });
  }

  void removeImage(int index) {
    if (_busy || _disposed || index < 0 || index >= _images.length) return;
    _images.removeAt(index);
    _notify();
    unawaited(saveDraftSnapshot().catchError((_) {}));
  }

  void reorderImages(int oldIndex, int newIndex) {
    if (_busy || _disposed) return;
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (oldIndex < 0 || oldIndex >= _images.length || target < 0 || target >= _images.length) return;
    _images.insert(target, _images.removeAt(oldIndex));
    _notify();
    unawaited(saveDraftSnapshot().catchError((_) {}));
  }

  void resumeUnfinishedTask() {
    if (_busy || _resumeTask == null || _disposed) return;
    _task = _resumeTask; _ready = false; _error = null; _notify();
    unawaited(pollNow());
  }

  Future<void> startImport() async {
    if (isGuestIncident) { reportError('当前处于游客模式，智能分析需调用单位云端 AI 服务。请先转为正式队员加入单位。'); return; }
    if (_images.isEmpty && _inputText.trim().isEmpty) { reportError('请先输入文字或选择图片'); return; }
    await _runBusy(() async {
      final task = await gateway.createIncidentImport(text: _images.isEmpty ? _inputText.trim() : null, images: _images);
      if (_disposed) return;
      _task = task; _ready = false; _resumeTask = null; _notify();
      _schedulePoll();
    });
  }

  void _schedulePoll() { _timer?.cancel(); if (!_disposed) _timer = Timer(pollInterval, pollNow); }
  void cancelPollTimer() { _timer?.cancel(); _timer = null; }

  Future<void> pollNow() async {
    if (_polling || _disposed || _task == null) return;
    _polling = true;
    try {
      final task = await gateway.fetchIncidentImport(_task!['id'].toString());
      if (_disposed) return;
      _task = task; _notify();
      final status = task['status'];
      if (status == 'ready' || status == 'partial') { await loadDraft(); }
      else if (status == 'queued' || status == 'processing') { _schedulePoll(); }
    } catch (error) { reportError(error); } finally { _polling = false; }
  }

  Future<void> loadDraft() async {
    final task = _task;
    if (task == null || _disposed) return;
    try {
      final current = await gateway.fetchIncidentDetails();
      final incident = await gateway.fetchIncident(_currentIncident.id);
      final forces = await gateway.fetchIncidentForces();
      final options = await gateway.fetchStationOptions();
      if (_disposed || _task?['id'] != task['id']) return;
      _currentDetails = current; _currentIncident = incident;
      _existingForces = forces; _stationOptions = options;
      _replaceTitle = (incident.title ?? '').trim().isEmpty;
      _applyOpId = null; _pendingApply = null; _selectedPage = null;
      _fillDraft(Map<String, dynamic>.from(task['draft'] as Map? ?? const {}));
      _ready = true; _error = null; _notify();
    } catch (error) { reportError(error); }
  }

  void selectMultiIncidentPage(int pageIndex) {
    final page = pages.firstWhere(
      (dynamic p) => (p['index'] as num?)?.toInt() == pageIndex,
      orElse: () => null,
    );
    if (page == null) return;
    final res = Map<String, dynamic>.from(page['result'] as Map? ?? const {});
    _selectedPage = pageIndex;
    _fillDraft(<String, dynamic>{'details': res, 'forces': res['forces']});
    _notify();
  }

  void _fillDraft(Map<String, dynamic> draft) {
    _draftDetails = Map<String, dynamic>.from(draft['details'] as Map? ?? const {});
    _title = _draftDetails['suggested_title']?.toString() ?? '';
    for (final k in incidentImportFieldLabels.keys) { _fieldValues[k] = _draftDetails[k]?.toString() ?? ''; }
    for (final k in incidentImportExtraLabels.keys) {
      _extraValues[k] = ((_draftDetails[k] as List?) ?? const []).join('\n');
    }
    _contactsText = ((_draftDetails['contacts'] as List?) ?? const [])
        .whereType<Map>()
        .map((c) => '${c['role']}|${c['name']}|${c['phone']}')
        .join('\n');
    _forces = ((draft['forces'] as List?) ?? const [])
        .whereType<Map>()
        .map((f) => <String, dynamic>{...Map<String, dynamic>.from(f), 'selected': true})
        .toList();
    _acceptIncomplete = false;
    _reviewed = false;
    _draftRevision++;
  }

  Future<void> retryFailedPages() async {
    if (_task == null) return;
    final failed = pages
        .where((dynamic p) => p['status'] == 'failed')
        .map((dynamic p) => (p['index'] as num).toInt())
        .toList();
    await _runBusy(() async {
      final task = await gateway.retryIncidentImport(_task!['id'].toString(), failed);
      if (_disposed) return;
      _task = task;
      _ready = false;
      _notify();
      _schedulePoll();
    });
  }

  Future<bool> cancelTask() async {
    if (_task == null) return false;
    final ok = await _runBusy<bool>(() async {
      await gateway.cancelIncidentImport(_task!['id'].toString());
      cancelPollTimer();
      if (_disposed) return false;
      _task = null;
      _ready = false;
      _pendingApply = null;
      _applyOpId = null;
      _selectedPage = null;
      return true;
    });
    return ok == true;
  }

  Future<void> refillRawTextAndCancel() async {
    final raw = pages.map((dynamic p) => p['result']?['raw_text'] ?? p['text'] ?? '').join('\n');
    if (!await cancelTask() || _disposed) return;
    _images.clear();
    _inputText = raw;
    _inputTextRevision++;
    _notify();
  }

  Future<Uint8List?> fetchTaskImage(int page) async {
    if (_task == null || _disposed) return null;
    try { return await gateway.fetchImportImage(_task!['id'].toString(), page); }
    catch (error) { reportError(error); return null; }
  }

  Map<String, dynamic> _buildDetailsInput() {
    final data = <String, dynamic>{};
    final old = Map<String, dynamic>.from(_currentDetails['data'] as Map? ?? const {});
    for (final e in _fieldValues.entries) { if (e.value.trim().isNotEmpty) data[e.key] = e.value.trim(); }
    for (final e in _extraValues.entries) {
      final lines = e.value.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (lines.isNotEmpty) {
        data[e.key] = <dynamic>[...<dynamic>{...((old[e.key] as List?) ?? const []), ...lines}];
      }
    }
    if (_contactsText.trim().isNotEmpty) {
      data['contacts'] = _contactsText.split('\n').where((s) => s.trim().isNotEmpty).map((line) {
        final parts = line.split('|');
        if (parts.length != 3) throw const FormatException('岗位人员请按“岗位|姓名|电话”逐行填写');
        return <String, String>{'role': parts[0].trim(), 'name': parts[1].trim(), 'phone': parts[2].trim()};
      }).toList();
    }
    if (_draftDetails['specific_type_inferred'] == true) data['specific_type_inferred'] = true;
    return data;
  }

  Future<bool> applyImport() async {
    if (_task == null) return false;
    final ok = await _runBusy<bool>(
      () async {
        final selected = _forces.where((f) => f['selected'] == true).map((f) => <String, dynamic>{
          ...f,
          'vehicle_count': f['vehicle_count'] ?? 0,
          'personnel_count': f['personnel_count'] ?? 0,
          'vehicle_count_known': f['vehicle_count'] != null,
          'personnel_count_known': f['personnel_count'] != null,
        }).toList();
        final body = _pendingApply ?? <String, dynamic>{
          'expected_incident_version': _currentIncident.version,
          'expected_details_version': _currentDetails['version'] ?? 0,
          'replace_title': _replaceTitle,
          'title': _title.trim(),
          'details': _buildDetailsInput(),
          'forces': selected,
          'accept_incomplete': _acceptIncomplete,
          'conflicts_reviewed': _reviewed,
          if (_selectedPage != null) 'selected_page': _selectedPage,
        };
        _pendingApply = body;
        _applyOpId ??= 'incident-import-${DateTime.now().microsecondsSinceEpoch}';
        await gateway.applyIncidentImport(_task!['id'].toString(), body, _applyOpId!);
        if (_disposed) return false;
        _applied = true;
        cancelPollTimer();
        return true;
      },
      onError: (Object error) {
        if (error is ApiException && error.statusCode == 409) {
          _pendingApply = null; _applyOpId = null;
          reportError('$error。请点“刷新差异”后重新核对。');
        } else if (error is FormatException ||
            (error is ApiException && (error.statusCode ?? 500) >= 400 && (error.statusCode ?? 500) < 500)) {
          _pendingApply = null; _applyOpId = null;
          reportError(error);
        } else {
          reportError('$error。若已提交但未收到结果，可点击原按钮重试；重试不会重复登记。');
        }
      },
    );
    return ok == true;
  }

  void _notify() { if (!_disposed) notifyListeners(); }

  @override
  void dispose() {
    _disposed = true;
    cancelPollTimer();
    unawaited(IncidentImageDraft.clear(gateway.cacheScope, _currentIncident.id).catchError((_) {}));
    for (final path in _temporaryPaths) {
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    super.dispose();
  }
}
