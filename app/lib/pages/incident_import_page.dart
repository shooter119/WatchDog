import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/storage_service.dart';
import '../api/api_client.dart';
import '../models/models.dart';
import '../services/incident_import_images.dart';
import '../services/incident_image_draft.dart';
import '../theme/app_widgets.dart';

const incidentFieldLabels = <String, String>{
  'original_category': '原始分类',
  'level': '等级',
  'specific_type': '具体类型',
  'received_at': '接警时间',
  'location': '事发地点',
  'administrative_area': '行政区',
  'place_type': '场所类型',
  'situation': '现场情况',
  'trapped': '人员被困',
  'injured': '人员受伤',
  'hazardous_materials': '危险物质',
};

class IncidentImportPage extends StatefulWidget {
  final ApiClient api;
  final Incident incident;
  final bool fromImages;
  const IncidentImportPage({
    super.key,
    required this.api,
    required this.incident,
    this.fromImages = false,
  });
  @override
  State<IncidentImportPage> createState() => _IncidentImportPageState();
}

class _IncidentImportPageState extends State<IncidentImportPage> {
  late final ApiClient _api = widget.api.forIncident(widget.incident.id);
  final _text = TextEditingController();
  final _title = TextEditingController();
  final _fields = <String, TextEditingController>{};
  final _extra = <String, TextEditingController>{};
  final _contacts = TextEditingController();
  final _images = <Uint8List>[];
  final _temporaryPaths = <String>{};
  final _picker = ImagePicker();
  Map<String, dynamic>? _task;
  Map<String, dynamic>? _resume;
  Map<String, dynamic> _currentDetails = {};
  Map<String, dynamic> _draftDetails = {};
  List<Map<String, dynamic>> _forces = [];
  List<IncidentForce> _existingForces = [];
  List<Map<String, dynamic>> _unitStations = [];
  List<Station> _systemStations = [];
  late Incident _currentIncident = widget.incident;
  String? _error;
  bool _busy = false, _polling = false, _ready = false, _replaceTitle = false;
  bool _acceptIncomplete = false, _reviewed = false, _applied = false;
  int? _selectedPage;
  String? _applyOpId;
  Map<String, dynamic>? _pendingApply;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    for (final key in incidentFieldLabels.keys) {
      _fields[key] = TextEditingController()
        ..addListener(() {
          if (mounted && _ready) setState(() {});
        });
    }
    for (final key in [
      'risks',
      'to_confirm',
      'vehicles',
      'equipment',
      'channels',
    ]) {
      _extra[key] = TextEditingController();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    try {
      final saved = await IncidentImageDraft.load(
        _api.cacheScope,
        widget.incident.id,
      );
      if (!mounted) return;
      if (saved.isNotEmpty) setState(() => _images.addAll(saved));
      if (Platform.isAndroid) {
        final lost = await _picker.retrieveLostData();
        if (lost.files?.isNotEmpty == true) {
          await _appendFiles(lost.files!, camera: true);
        }
      }
      final tasks = await _api.fetchIncidentImports();
      if (!mounted) return;
      final pending = tasks.where(
        (t) => [
          'queued',
          'processing',
          'ready',
          'partial',
          'failed',
        ].contains(t['status']),
      );
      if (pending.isNotEmpty) setState(() => _resume = pending.first);
    } catch (_) {
      /* New installations or a temporarily unavailable service can still collect input. */
    }
    if (mounted && widget.fromImages && _images.isEmpty) await _chooseSource();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(
      IncidentImageDraft.clear(
        _api.cacheScope,
        widget.incident.id,
      ).catchError((_) {}),
    );
    _api.dispose();
    _text.dispose();
    _title.dispose();
    _contacts.dispose();
    for (final c in [..._fields.values, ..._extra.values]) {
      c.dispose();
    }
    for (final file in _temporaryPaths) {
      unawaited(File(file).delete().catchError((_) => File(file)));
    }
    super.dispose();
  }

  void _fail(Object error) {
    if (mounted) setState(() => _error = error.toString());
  }

  Future<void> _chooseSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照导入'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source != null && mounted) await _pick(source);
  }

  Future<void> _pick(ImageSource source) async {
    if (_busy) return;
    if (_images.length >= 9) {
      _fail('每批最多9张图片');
      return;
    }
    try {
      await IncidentImageDraft.save(
        _api.cacheScope,
        widget.incident.id,
        _images,
      );
      List<XFile> files;
      if (source == ImageSource.camera) {
        final file = await _picker.pickImage(
          source: source,
          maxWidth: 4000,
          maxHeight: 6000,
          imageQuality: 95,
        );
        files = file == null ? [] : [file];
      } else {
        files = await _picker.pickMultiImage(imageQuality: 95);
      }
      if (mounted) {
        await _appendFiles(files, camera: source == ImageSource.camera);
      }
    } catch (error) {
      _fail('无法打开相机或相册：$error。可以重试或检查系统权限。');
    }
  }

  Future<void> _appendFiles(List<XFile> files, {bool camera = false}) async {
    if (files.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_images.length + files.length > 9) {
        throw const FormatException('每批最多9张图片，请减少选择');
      }
      for (final file in files) {
        if (camera) _temporaryPaths.add(file.path);
        if (await file.length() > 60 * 1024 * 1024) {
          throw const FormatException('原始图片过大，请裁切后导入');
        }
        final bytes = await file.readAsBytes();
        if (bytes.length > 60 * 1024 * 1024) {
          throw const FormatException('原始图片过大，请裁切后导入');
        }
        final prepared = await compute(prepareIncidentImage, {'bytes': bytes});
        if (!mounted) return;
        if (_images.fold<int>(0, (n, b) => n + b.length) + prepared.length >
            25 * 1024 * 1024) {
          throw const FormatException('整批图片不能超过25MB');
        }
        setState(() => _images.add(prepared));
        await IncidentImageDraft.save(
          _api.cacheScope,
          widget.incident.id,
          _images,
        );
      }
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rotate(int index) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await compute(prepareIncidentImage, {
        'bytes': _images[index],
        'turns': 1,
      });
      if (mounted) {
        setState(() => _images[index] = bytes);
        await IncidentImageDraft.save(
          _api.cacheScope,
          widget.incident.id,
          _images,
        );
      }
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview(int index) => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(title: Text('第${index + 1}张图片')),
        body: InteractiveViewer(
          minScale: 0.5,
          maxScale: 8,
          child: Center(child: Image.memory(_images[index])),
        ),
      ),
    ),
  );
  Future<void> _previewTaskImage(int page) async {
    try {
      final bytes = await _api.fetchImportImage(_task!['id'].toString(), page);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(title: Text('第$page页原图')),
            body: InteractiveViewer(
              minScale: .5,
              maxScale: 8,
              child: Center(child: Image.memory(bytes)),
            ),
          ),
        ),
      );
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    if (_images.isEmpty && _text.text.trim().isEmpty) {
      _fail('请先输入文字或选择图片');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final task = await _api.createIncidentImport(
        text: _images.isEmpty ? _text.text.trim() : null,
        images: _images,
      );
      if (!mounted) return;
      setState(() {
        _task = task;
        _ready = false;
        _resume = null;
      });
      _schedulePoll();
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _schedulePoll() {
    _timer?.cancel();
    if (mounted) _timer = Timer(const Duration(seconds: 2), _poll);
  }

  Future<void> _poll() async {
    if (_polling || !mounted || _task == null) return;
    _polling = true;
    try {
      final task = await _api.fetchIncidentImport(_task!['id'].toString());
      if (!mounted) return;
      setState(() => _task = task);
      if (['ready', 'partial'].contains(task['status'])) {
        await _loadDraft();
      } else if (['queued', 'processing'].contains(task['status'])) {
        _schedulePoll();
      }
    } catch (error) {
      _fail(error);
    } finally {
      _polling = false;
    }
  }

  Future<void> _loadDraft() async {
    final task = _task!;
    try {
      final current = await _api.fetchIncidentDetails();
      final incident = await _api.fetchIncident(widget.incident.id);
      final forces = await _api.fetchIncidentForces();
      final unitStations = await _api.fetchUnitStations();
      final systemStations = await _api.fetchStations();
      if (!mounted || _task?['id'] != task['id']) return;
      _currentDetails = current;
      _currentIncident = incident;
      _existingForces = forces;
      _unitStations = unitStations;
      _systemStations = systemStations;
      _replaceTitle = (incident.title ?? '').trim().isEmpty;
      _applyOpId = null;
      _pendingApply = null;
      _fillDraft(Map<String, dynamic>.from(task['draft'] as Map));
      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (error) {
      _fail(error);
    }
  }

  void _fillDraft(Map<String, dynamic> draft) {
    _draftDetails = Map<String, dynamic>.from(draft['details'] as Map? ?? {});
    _title.text = _draftDetails['suggested_title']?.toString() ?? '';
    for (final item in _fields.entries) {
      item.value.text = _draftDetails[item.key]?.toString() ?? '';
    }
    for (final item in _extra.entries) {
      item.value.text = ((_draftDetails[item.key] as List?) ?? []).join('\n');
    }
    _contacts.text = ((_draftDetails['contacts'] as List?) ?? [])
        .map((c) => '${c['role']}|${c['name']}|${c['phone']}')
        .join('\n');
    _forces = ((draft['forces'] as List?) ?? [])
        .map((f) => {...Map<String, dynamic>.from(f as Map), 'selected': true})
        .toList();
    _acceptIncomplete = false;
    _reviewed = false;
  }

  Future<void> _retry() async {
    if (_busy) return;
    final pages = (_task?['pages'] as List? ?? [])
        .where((p) => p['status'] == 'failed')
        .map((p) => (p['index'] as num).toInt())
        .toList();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final task = await _api.retryIncidentImport(
        _task!['id'].toString(),
        pages,
      );
      if (mounted) {
        setState(() {
          _task = task;
          _ready = false;
        });
        _schedulePoll();
      }
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelTask() async {
    if (_busy || _task == null) return;
    setState(() => _busy = true);
    try {
      await _api.cancelIncidentImport(_task!['id'].toString());
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _task = null;
          _ready = false;
          _error = null;
          _pendingApply = null;
          _applyOpId = null;
        });
      }
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _detailsInput() {
    final data = <String, dynamic>{};
    final old = Map<String, dynamic>.from(
      _currentDetails['data'] as Map? ?? {},
    );
    for (final item in _fields.entries) {
      if (item.value.text.trim().isNotEmpty) {
        data[item.key] = item.value.text.trim();
      }
    }
    for (final item in _extra.entries) {
      final lines = item.value.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (lines.isNotEmpty) {
        data[item.key] = [
          ...{...((old[item.key] as List?) ?? []), ...lines},
        ];
      }
    }
    if (_contacts.text.trim().isNotEmpty) {
      data['contacts'] = _contacts.text
          .split('\n')
          .where((s) => s.trim().isNotEmpty)
          .map((line) {
            final parts = line.split('|');
            if (parts.length != 3) {
              throw const FormatException('岗位人员请按“岗位|姓名|电话”逐行填写');
            }
            return {
              'role': parts[0].trim(),
              'name': parts[1].trim(),
              'phone': parts[2].trim(),
            };
          })
          .toList();
    }
    if (_draftDetails['specific_type_inferred'] == true) {
      data['specific_type_inferred'] = true;
    }
    return data;
  }

  Future<void> _apply() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final selected = _forces
          .where((f) => f['selected'] == true)
          .map(
            (f) => {
              ...f,
              'vehicle_count': f['vehicle_count'] ?? 0,
              'personnel_count': f['personnel_count'] ?? 0,
              'vehicle_count_known': f['vehicle_count'] != null,
              'personnel_count_known': f['personnel_count'] != null,
            },
          )
          .toList();
      final body =
          _pendingApply ??
          {
            'expected_incident_version': _currentIncident.version,
            'expected_details_version': _currentDetails['version'] ?? 0,
            'replace_title': _replaceTitle,
            'title': _title.text.trim(),
            'details': _detailsInput(),
            'forces': selected,
            'accept_incomplete': _acceptIncomplete,
            'conflicts_reviewed': _reviewed,
            if (_selectedPage != null) 'selected_page': _selectedPage,
          };
      _pendingApply = body;
      _applyOpId ??= 'incident-import-${DateTime.now().microsecondsSinceEpoch}';
      await _api.applyIncidentImport(
        _task!['id'].toString(),
        body,
        _applyOpId!,
      );
      _applied = true;
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (error is ApiException && error.statusCode == 409) {
        _pendingApply = null;
        _applyOpId = null;
        _fail('$error。请点“刷新差异”后重新核对。');
      } else if (error is ApiException &&
          (error.statusCode ?? 500) >= 400 &&
          (error.statusCode ?? 500) < 500) {
        _pendingApply = null;
        _applyOpId = null;
        _fail(error);
      } else {
        _fail('$error。若已提交但未收到结果，可点击原按钮重试；重试不会重复登记。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editForce(int index) async {
    final force = Map<String, dynamic>.from(_forces[index]);
    final name = TextEditingController(
      text: force['station_name']?.toString() ?? '',
    );
    final vehicles = TextEditingController(
      text: force['vehicle_count']?.toString() ?? '',
    );
    final people = TextEditingController(
      text: force['personnel_count']?.toString() ?? '',
    );
    bool saveCommon = force['save_common'] == true;
    final candidates = <Map<String, dynamic>>[
      for (final f in _existingForces)
        {
          'key': 'force:${f.id}',
          'name': f.stationName,
          'target_force_id': f.id,
          'expected_version': f.version,
          'station_id': f.stationId,
        },
      for (final s in _unitStations)
        {
          'key': 'unit:${s['id']}',
          'name': s['name'],
          'unit_station_id': s['id'],
        },
      for (final s in _systemStations)
        {'key': 'system:${s.id}', 'name': s.name, 'station_id': s.id},
    ];
    String? choice;
    if (force['target_force_id'] != null) {
      choice = 'force:${force['target_force_id']}';
    } else if (force['unit_station_id'] != null) {
      choice = 'unit:${force['unit_station_id']}';
    } else if (force['station_id'] != null) {
      choice = 'system:${force['station_id']}';
    }
    if (!candidates.any((c) => c['key'] == choice)) choice = null;
    String? validation;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('核对出动力量'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: choice ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '匹配已有队伍'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('作为新队伍登记')),
                      for (final c in candidates)
                        DropdownMenuItem(
                          value: c['key'] as String,
                          child: Text(
                            '${c['name']} · ${(c['key'] as String).startsWith('force:') ? '已登记' : '名录'}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setDialog(() {
                      choice = value == '' ? null : value;
                      if (choice != null) {
                        name.text = candidates
                            .firstWhere((c) => c['key'] == choice)['name']
                            .toString();
                      }
                    }),
                  ),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '队伍名称'),
                    onChanged: (_) => setDialog(() => choice = null),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: vehicles,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '车辆数',
                            hintText: '留空待补充',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: people,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '人数',
                            hintText: '留空待补充',
                          ),
                        ),
                      ),
                    ],
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('保存到本单位常用队伍'),
                    value: saveCommon,
                    onChanged: (v) => setDialog(() => saveCommon = v == true),
                  ),
                  if (validation != null)
                    Text(
                      validation!,
                      style: const TextStyle(color: AppColors.alarm),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final v = int.tryParse(vehicles.text.trim()),
                    p = int.tryParse(people.text.trim());
                if (name.text.trim().isEmpty ||
                    (vehicles.text.trim().isNotEmpty &&
                        (v == null || v < 0 || v > 999)) ||
                    (people.text.trim().isNotEmpty &&
                        (p == null || p < 0 || p > 999))) {
                  setDialog(() => validation = '请填写队伍名称和0至999的整数，未知数量留空');
                  return;
                }
                final candidate = choice == null
                    ? <String, dynamic>{}
                    : candidates.firstWhere((c) => c['key'] == choice);
                Navigator.pop(context, {
                  ...force,
                  'station_name': name.text.trim(),
                  'vehicle_count': v,
                  'personnel_count': p,
                  'save_common': saveCommon,
                  'target_force_id': candidate['target_force_id'],
                  'expected_version': candidate['expected_version'],
                  'unit_station_id': candidate['unit_station_id'],
                  'station_id': candidate['station_id'],
                  'matched_name': candidate['name'],
                });
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    // Dialog fields may still be used by their closing animation.
    Future.delayed(const Duration(milliseconds: 300), () {
      name.dispose();
      vehicles.dispose();
      people.dispose();
    });
    if (result != null && mounted) setState(() => _forces[index] = result);
  }

  Widget _section(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
  List<dynamic> get _pages => _task?['pages'] as List? ?? [];
  Widget _input() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_resume != null)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history),
          title: const Text('继续未完成的导入'),
          subtitle: Text(
            '状态：${const {'queued': '等待分析', 'processing': '正在分析', 'ready': '待核对', 'partial': '部分完成', 'failed': '分析失败，可重试'}[_resume!['status']] ?? '待处理'}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy
              ? null
              : () {
                  setState(() => _task = _resume);
                  _poll();
                },
        ),
      const Text(
        '导入资料将由当前配置的云端AI处理。请核对识别结果后再应用。',
        style: TextStyle(color: AppColors.textSecondary, height: 1.5),
      ),
      const SizedBox(height: 12),
      if (_images.isEmpty)
        TextField(
          controller: _text,
          minLines: 8,
          maxLines: 16,
          maxLength: 20000,
          decoration: const InputDecoration(
            labelText: '警情文字',
            hintText: '粘贴接处警通报或警情信息',
          ),
        ),
      if (_images.isNotEmpty) ...[
        Text(
          '已选${_images.length}/9张 · 长按拖动排序',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        SizedBox(
          height: 310,
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _images.length,
            onReorder: (oldIndex, newIndex) {
              if (_busy) return;
              setState(() {
                if (newIndex > oldIndex) newIndex--;
                final image = _images.removeAt(oldIndex);
                _images.insert(newIndex, image);
              });
            },
            itemBuilder: (context, index) =>
                ReorderableDelayedDragStartListener(
                  key: ObjectKey(_images[index]),
                  index: index,
                  child: ListTile(
                    leading: GestureDetector(
                      onTap: () => _preview(index),
                      child: Image.memory(
                        _images[index],
                        width: 52,
                        height: 58,
                        fit: BoxFit.cover,
                        cacheWidth: 120,
                      ),
                    ),
                    title: Text('第${index + 1}张'),
                    subtitle: Text(
                      '${(_images[index].length / 1024).round()} KB',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '旋转',
                          onPressed: _busy ? null : () => _rotate(index),
                          icon: const Icon(Icons.rotate_right),
                        ),
                        IconButton(
                          tooltip: '移除',
                          onPressed: _busy
                              ? null
                              : () => setState(() => _images.removeAt(index)),
                          icon: const Icon(Icons.close),
                        ),
                        const Icon(
                          Icons.drag_handle,
                          color: AppColors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
          ),
        ),
      ],
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: _busy ? null : () => _pick(ImageSource.camera),
            icon: const Icon(Icons.camera_alt_outlined, size: 18),
            label: const Text('拍照'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : () => _pick(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_outlined, size: 18),
            label: const Text('相册'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy ? null : _start,
        child: Text(_busy ? '正在处理…' : '开始分析'),
      ),
    ],
  );
  Widget _progress() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '分析目标：${widget.incident.displayName}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      if (['queued', 'processing'].contains(_task?['status']))
        const LinearProgressIndicator(),
      for (final p in _pages)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            p['status'] == 'succeeded'
                ? Icons.check_circle_outline
                : p['status'] == 'failed'
                ? Icons.error_outline
                : Icons.hourglass_empty,
            color: p['status'] == 'failed'
                ? AppColors.alarm
                : AppColors.textSecondary,
          ),
          title: Text('第${p['index']}页'),
          subtitle: Text(
            {
                  'queued': '等待分析',
                  'processing': '正在分析',
                  'succeeded': '识别完成',
                  'failed': '识别失败，可重试',
                }[p['status']] ??
                p['status'].toString(),
          ),
        ),
      if (_pages.any((p) => p['status'] == 'failed'))
        TextButton(
          onPressed: _busy ? null : _retry,
          child: const Text('重试失败页'),
        ),
      TextButton(onPressed: _busy ? null : _poll, child: const Text('刷新进度')),
      TextButton(
        onPressed: _busy ? null : _cancelTask,
        child: const Text('取消本次导入'),
      ),
      const Text(
        '可返回现场继续工作，稍后从导入入口恢复任务。',
        style: TextStyle(color: AppColors.textTertiary),
      ),
    ],
  );
  Widget _confirmation() {
    if (_pendingApply != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('上次提交结果尚未确认。为避免重复或提交不同内容，先重试原提交，或取消本次导入。'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _apply,
            child: const Text('重试原提交（防重复）'),
          ),
          TextButton(
            onPressed: _busy ? null : _cancelTask,
            child: const Text('取消本次导入'),
          ),
        ],
      );
    }

    final conflicts = (_task?['draft'] as Map?)?['conflicts'] as List? ?? [];
    final multiple =
        (_task?['draft'] as Map?)?['details']?['multiple_incidents'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '更新目标：${_currentIncident.displayName}',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        if (multiple)
          _section('识别到多起警情，请选择一页继续', [
            DropdownButtonFormField<int>(
              initialValue: _selectedPage,
              isExpanded: true,
              items: [
                for (final p in _pages.where((p) => p['status'] == 'succeeded'))
                  DropdownMenuItem(
                    value: (p['index'] as num).toInt(),
                    child: Text(
                      '第${p['index']}页 · ${p['result']?['suggested_title'] ?? ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                final p = _pages.firstWhere((p) => p['index'] == value);
                final result = Map<String, dynamic>.from(p['result'] as Map);
                setState(() {
                  _selectedPage = value;
                  _fillDraft({'details': result, 'forces': result['forces']});
                });
              },
            ),
          ]),
        _section('建议警情名称', [
          TextField(
            controller: _title,
            maxLength: 80,
            decoration: const InputDecoration(hintText: '地点＋事件类型'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('应用此名称'),
            subtitle: Text('当前：${_currentIncident.displayName}'),
            value: _replaceTitle,
            onChanged: (v) => setState(() => _replaceTitle = v == true),
          ),
        ]),
        _section('警情资料', [
          Text(
            '${_fields['original_category']!.text} · ${_fields['specific_type']!.text}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            _fields['location']!.text.isEmpty
                ? '地点待补充'
                : _fields['location']!.text,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('核对或修改详细资料', style: TextStyle(fontSize: 13)),
            children: [
              for (final item in _fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextField(
                    controller: item.value,
                    minLines: 1,
                    maxLines: item.key == 'situation' ? 4 : 2,
                    decoration: InputDecoration(
                      labelText: incidentFieldLabels[item.key],
                      hintText: item.key == 'received_at'
                          ? '2026-10-17T18:01:00+08:00'
                          : '未提供，保留原值',
                      helperText:
                          (_currentDetails['data'] as Map?)?[item.key]
                                  ?.toString()
                                  .isNotEmpty ==
                              true
                          ? '现有：${_currentDetails['data'][item.key]}'
                          : null,
                    ),
                  ),
                ),
              if (_draftDetails['specific_type_inferred'] == true)
                const Text(
                  '具体类型由描述推断，请核对。',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
            ],
          ),
        ]),
        _section('识别到的出动力量', [
          for (var i = 0; i < _forces.length; i++)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _forces[i]['selected'] == true,
              onChanged: (v) =>
                  setState(() => _forces[i]['selected'] = v == true),
              title: Text(_forces[i]['station_name'].toString()),
              subtitle: Text(
                '${_forces[i]['vehicle_count'] == null ? '车辆待补充' : '${_forces[i]['vehicle_count']}车'} · ${_forces[i]['personnel_count'] == null ? '人数待补充' : '${_forces[i]['personnel_count']}人'}\n${_forces[i]['target_force_id'] != null
                    ? '匹配已登记队伍，将更新所选数量'
                    : _forces[i]['matched_name'] != null
                    ? '匹配：${_forces[i]['matched_name']}'
                    : '未匹配，可直接登记新队伍'}',
              ),
              secondary: IconButton(
                tooltip: '编辑与匹配',
                onPressed: () => _editForce(i),
                icon: const Icon(Icons.edit_outlined, size: 19),
              ),
            ),
          const Text(
            '通报出动／调派不代表到场，不计入个人进场记录。',
            style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
          ),
        ]),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('岗位人员、风险与通信装备'),
          children: [
            TextField(
              controller: _contacts,
              minLines: 2,
              maxLines: 8,
              decoration: const InputDecoration(labelText: '岗位人员（每行：岗位|姓名|电话）'),
            ),
            for (final entry in _extra.entries)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextField(
                  controller: entry.value,
                  minLines: 1,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: {
                      'risks': '风险信息',
                      'to_confirm': '待核实事项',
                      'vehicles': '车辆明细',
                      'equipment': '通信装备',
                      'channels': '频道',
                    }[entry.key],
                    helperText: '每行一项；将与现有内容合并',
                  ),
                ),
              ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('原始通报与提取文字'),
          children: [
            if (_task?['source'] == 'images')
              Wrap(
                children: [
                  for (final p in _pages)
                    TextButton.icon(
                      onPressed: () =>
                          _previewTaskImage((p['index'] as num).toInt()),
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text('第${p['index']}页原图'),
                    ),
                ],
              ),
            for (final p in _pages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  '第${p['index']}页\n${p['result']?['raw_text'] ?? p['text'] ?? '未识别'}',
                ),
              ),
            TextButton(
              onPressed: () async {
                final raw = _pages
                    .map((p) => p['result']?['raw_text'] ?? p['text'] ?? '')
                    .join('\n');
                await _cancelTask();
                if (mounted && _task == null) {
                  setState(() {
                    _images.clear();
                    _text.text = raw;
                  });
                }
              },
              child: const Text('修改提取文字后重新分析'),
            ),
          ],
        ),
        if (conflicts.isNotEmpty)
          _section('识别存在差异，请核对', [
            for (final c in conflicts)
              Text(
                '第${c['page']}页 · ${incidentFieldLabels[c['field']] ?? c['field']}：${c['value']}',
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('已核对差异并修正上方资料'),
              value: _reviewed,
              onChanged: (v) => setState(() => _reviewed = v == true),
            ),
          ]),
        if (_task?['status'] == 'partial')
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('部分图片未识别，确认使用当前不完整资料'),
            value: _acceptIncomplete,
            onChanged: (v) => setState(() => _acceptIncomplete = v == true),
          ),
        if (_pages.any((p) => p['status'] == 'failed'))
          TextButton(
            onPressed: _busy ? null : _retry,
            child: const Text('重试失败页'),
          ),
        TextButton(
          onPressed: _busy ? null : _loadDraft,
          child: const Text('刷新差异（重新载入识别草稿）'),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed:
              _busy ||
                  (multiple && _selectedPage == null) ||
                  (conflicts.isNotEmpty && !_reviewed) ||
                  (_task?['status'] == 'partial' && !_acceptIncomplete)
              ? null
              : _apply,
          child: Text(
            _busy
                ? '正在提交…'
                : _pendingApply != null
                ? '重试提交（防重复）'
                : '确认并更新警情',
          ),
        ),
        TextButton(
          onPressed: _busy ? null : _cancelTask,
          child: const Text('取消导入'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    onPopInvokedWithResult: (didPop, result) {
      if (didPop && !_applied) _timer?.cancel();
    },
    child: Scaffold(
      appBar: AppBar(title: Text(_ready ? '确认导入信息' : '导入警情信息')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: AppColors.alarm),
                    ),
                    if (_error!.contains('权限'))
                      TextButton(
                        onPressed: StorageService.openAppSettings,
                        child: const Text('打开系统设置'),
                      ),
                  ],
                ),
              ),
            if (_task == null)
              _input()
            else if (_ready)
              _confirmation()
            else
              _progress(),
          ],
        ),
      ),
    ),
  );
}
