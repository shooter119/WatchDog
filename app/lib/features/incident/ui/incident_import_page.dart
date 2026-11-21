import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../design_system/design_system.dart';
import '../../../services/storage_service.dart';
import '../data/models/incident.dart';
import '../state/incident_import_store.dart';
import 'incident_import_confirm_view.dart';
import 'incident_import_force_sheet.dart';
import 'incident_import_input_view.dart';

/// Design System v3.0 警情导入页面（3 阶段：输入采集 -> 解析轮询 -> 结构化核对确认）。
class IncidentImportPage extends StatefulWidget {
  const IncidentImportPage({
    super.key,
    required this.gateway,
    required this.incident,
    this.chooseSourceOnOpen = false,
    this.store,
    this.pollInterval = const Duration(seconds: 2),
    this.imagePicker,
    this.imagePreparer,
  });

  final IncidentImportGateway gateway;
  final Incident incident;
  final bool chooseSourceOnOpen;
  final IncidentImportStore? store;
  final Duration pollInterval;
  final ImagePicker? imagePicker;
  final ImagePreparer? imagePreparer;

  @override
  State<IncidentImportPage> createState() => _IncidentImportPageState();
}

class _IncidentImportPageState extends State<IncidentImportPage> {
  late final IncidentImportStore _store;
  late final bool _ownsStore;
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();

  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final TextEditingController _titleController = TextEditingController();
  final Map<String, TextEditingController> _fieldControllers = <String, TextEditingController>{};
  final Map<String, TextEditingController> _extraControllers = <String, TextEditingController>{};
  final TextEditingController _contactsController = TextEditingController();
  int _syncedDraftRevision = -1, _syncedInputRevision = -1;

  @override
  void initState() {
    super.initState();
    _ownsStore = widget.store == null;
    _store = widget.store ??
        IncidentImportStore(
          gateway: widget.gateway,
          incident: widget.incident,
          pollInterval: widget.pollInterval,
          imagePreparer: widget.imagePreparer,
        );
    for (final k in incidentImportFieldLabels.keys) {
      _fieldControllers[k] = TextEditingController();
    }
    for (final k in incidentImportExtraLabels.keys) {
      _extraControllers[k] = TextEditingController();
    }
    _store.addListener(_onStoreChanged);
    _syncControllersFromStore();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    await _store.initialize(
      recoverLostCameraFiles: Platform.isAndroid
          ? () async {
              final files = (await _picker.retrieveLostData()).files;
              return files == null || files.isEmpty
                  ? const <ImportImageFile>[]
                  : files.map(_toImportFile).toList();
            }
          : null,
    );
    if (mounted && widget.chooseSourceOnOpen && _store.images.isEmpty) {
      await _chooseSource();
    }
  }

  ImportImageFile _toImportFile(XFile file) => ImportImageFile(
    path: file.path,
    readLength: file.length,
    readBytes: file.readAsBytes,
  );

  void _onStoreChanged() {
    _syncControllersFromStore();
    if (mounted) setState(() {});
  }

  void _syncControllersFromStore() {
    if (_syncedInputRevision != _store.inputTextRevision) {
      _syncedInputRevision = _store.inputTextRevision;
      if (_textController.text != _store.inputText) _textController.text = _store.inputText;
    }
    if (_syncedDraftRevision != _store.draftRevision) {
      _syncedDraftRevision = _store.draftRevision;
      _titleController.text = _store.title;
      for (final e in _fieldControllers.entries) {
        e.value.text = _store.fieldValues[e.key] ?? '';
      }
      for (final e in _extraControllers.entries) {
        e.value.text = _store.extraValues[e.key] ?? '';
      }
      _contactsController.text = _store.contactsText;
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    if (_ownsStore) _store.dispose();
    _textController.dispose();
    _textFocusNode.dispose();
    _titleController.dispose();
    _contactsController.dispose();
    for (final c in <TextEditingController>[
      ..._fieldControllers.values,
      ..._extraControllers.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseSource() async {
    final mode = await showCommandSheet<IncidentImportEntryMode>(
      context: context,
      title: '选择导入方式',
      subtitle: '支持拍照识别、相册多图或直接粘贴接处警文字',
      builder: (BuildContext ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _sourceTile(ctx, Icons.camera_alt_outlined, '拍照', IncidentImportEntryMode.camera),
          _sourceTile(ctx, Icons.photo_library_outlined, '从手机相册选择', IncidentImportEntryMode.gallery),
          _sourceTile(ctx, Icons.description_outlined, '文字导入', IncidentImportEntryMode.text),
        ],
      ),
    );
    if (!mounted || mode == null) return;
    switch (mode) {
      case IncidentImportEntryMode.camera:
        await _pickImages(ImageSource.camera);
      case IncidentImportEntryMode.gallery:
        await _pickImages(ImageSource.gallery);
      case IncidentImportEntryMode.text:
        _textFocusNode.requestFocus();
    }
  }

  Widget _sourceTile(
    BuildContext context,
    IconData icon,
    String title,
    IncidentImportEntryMode mode,
  ) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: DsSizes.primaryAction),
    child: ListTile(
      leading: Icon(icon, color: context.ds.colors.brandText),
      title: Text(
        title,
        style: context.ds.typography.body.copyWith(
          color: context.ds.colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: context.ds.colors.textTertiary),
      onTap: () => Navigator.of(context).pop(mode),
    ),
  );

  Future<void> _pickImages(ImageSource source) async {
    if (_store.busy) return;
    if (_store.images.length >= 9) { _store.reportError('每批最多9张图片'); return; }
    try {
      await _store.saveDraftSnapshot();
      final files = source == ImageSource.camera
          ? [
              if (await _picker.pickImage(source: source, maxWidth: 4000, maxHeight: 6000, imageQuality: 95)
                  case final XFile f)
                f,
            ]
          : await _picker.pickMultiImage(imageQuality: 95);
      if (mounted && files.isNotEmpty) {
        await _store.appendImageFiles(files.map(_toImportFile).toList(), fromCamera: source == ImageSource.camera);
      }
    } catch (error) { _store.reportError('无法打开相机或相册：$error。可以重试或检查系统权限。'); }
  }

  Future<void> _previewBytes(String title, Uint8List bytes) => showDialog<void>(
    context: context,
    builder: (_) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: InteractiveViewer(
          minScale: 0.5,
          maxScale: 8,
          child: Center(child: Image.memory(bytes)),
        ),
      ),
    ),
  );

  Future<void> _previewTaskImage(int page) async {
    final bytes = await _store.fetchTaskImage(page);
    if (mounted && bytes != null) await _previewBytes('第$page页原图', bytes);
  }

  Future<void> _editForce(int index) async {
    if (index < 0 || index >= _store.forces.length) return;
    final result = await showIncidentImportForceSheet(
      context,
      force: Map<String, dynamic>.from(_store.forces[index]),
      existingForces: _store.existingForces,
      stationOptions: _store.stationOptions,
    );
    if (result != null && mounted) _store.updateForce(index, result);
  }

  Future<void> _confirmCancelTask() async {
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: '确认取消导入',
      builder: (BuildContext ctx) => Text(
        '取消后当前识别进度与草稿将被放弃，后续需重新提交分析。确认取消吗？',
        style: ctx.ds.typography.body.copyWith(color: ctx.ds.colors.textSecondary),
      ),
      actionsBuilder: (BuildContext ctx) => <Widget>[
        CommandButton(
          label: '继续保留',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        CommandButton(
          key: const Key('import-confirm-cancel-action-btn'),
          label: '确认取消',
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    );
    if (confirmed == true && mounted) await _store.cancelTask();
  }

  Future<void> _handleApply() async {
    if (await _store.applyImport() && mounted) Navigator.of(context).pop(true);
  }

  Widget _buildPollingView(BuildContext context) {
    final colors = context.ds.colors;
    final typo = context.ds.typography;
    final disableAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final status = _store.task?['status'];
    const labels = <String, String>{
      'queued': '等待分析',
      'processing': '正在分析',
      'succeeded': '识别完成',
      'failed': '识别失败，可重试',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SurfaceCard(
          key: const Key('import-progress-card'),
          level: DsSurfaceLevel.outlined,
          padding: const EdgeInsets.all(DsSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '分析目标：${widget.incident.displayName}',
                style: typo.body.copyWith(fontWeight: FontWeight.w700, color: colors.textPrimary),
              ),
              const SizedBox(height: DsSpacing.md),
              if (status == 'queued' || status == 'processing') ...<Widget>[
                LinearProgressIndicator(
                  value: disableAnim ? 0.5 : null,
                  color: colors.brand,
                  backgroundColor: colors.surfaceMuted,
                ),
                const SizedBox(height: DsSpacing.sm),
              ],
              for (final p in _store.pages)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    p['status'] == 'succeeded'
                        ? Icons.check_circle_outline_rounded
                        : p['status'] == 'failed'
                        ? Icons.error_outline_rounded
                        : Icons.hourglass_empty_rounded,
                    color: p['status'] == 'failed'
                        ? colors.alarmText
                        : p['status'] == 'succeeded'
                        ? colors.safeText
                        : colors.textSecondary,
                  ),
                  title: Text(
                    '第${p['index']}页',
                    style: typo.bodyTabular.copyWith(fontWeight: FontWeight.w700, color: colors.textPrimary),
                  ),
                  subtitle: Text(
                    labels[p['status']] ?? p['status'].toString(),
                    style: typo.caption.copyWith(
                      color: p['status'] == 'failed' ? colors.alarmText : colors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.md),
        if (_store.hasFailedPages) ...<Widget>[
          CommandButton(
            key: const Key('import-retry-failed-pages-btn'),
            label: '重试失败页',
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.standard,
            expanded: true,
            enabled: !_store.busy,
            onPressed: _store.retryFailedPages,
          ),
          const SizedBox(height: DsSpacing.sm),
        ],
        CommandButton(
          key: const Key('import-refresh-progress-btn'),
          label: '刷新进度',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.standard,
          expanded: true,
          enabled: !_store.busy,
          onPressed: _store.pollNow,
        ),
        const SizedBox(height: DsSpacing.sm),
        CommandButton(
          key: const Key('import-cancel-polling-btn'),
          label: '取消本次导入',
          variant: CommandButtonVariant.ghost,
          size: CommandButtonSize.standard,
          expanded: true,
          enabled: !_store.busy,
          onPressed: _confirmCancelTask,
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          '可返回现场继续工作，稍后从导入入口恢复任务。',
          textAlign: TextAlign.center,
          style: typo.caption.copyWith(color: colors.textTertiary),
        ),
      ],
    );
  }

  Widget? _buildBottomBar() {
    if (_store.stage != IncidentImportStage.confirm || _store.pendingApply != null) return null;
    final colors = context.ds.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(DsSpacing.lg, DsSpacing.sm, DsSpacing.lg, DsSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              CommandButton(
                key: const Key('import-apply-btn'),
                label: _store.busy ? '正在提交…' : '确认并更新警情',
                variant: CommandButtonVariant.primary,
                size: CommandButtonSize.large,
                expanded: true,
                enabled: _store.canApply,
                isLoading: _store.busy,
                onPressed: _handleApply,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, String error) {
    final colors = context.ds.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: SurfaceCard(
        key: const Key('import-error-banner'),
        level: DsSurfaceLevel.flat,
        backgroundColor: colors.statusColors(DsStatus.alarm).pillBg,
        borderColor: colors.alarmFill.withValues(alpha: 0.35),
        padding: const EdgeInsets.all(DsSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline_rounded, size: 18, color: colors.alarmText),
                const SizedBox(width: DsSpacing.sm),
                Expanded(
                  child: Text(
                    error,
                    style: context.ds.typography.caption.copyWith(
                      color: colors.alarmText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (error.contains('权限')) ...<Widget>[
              const SizedBox(height: DsSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: CommandButton(
                  label: '打开系统设置',
                  variant: CommandButtonVariant.ghost,
                  onPressed: StorageService.openAppSettings,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _store.error;
    return PopScope(
      canPop: !_store.busy,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop && !_store.applied) _store.cancelPollTimer();
      },
      child: Scaffold(
        backgroundColor: context.ds.colors.canvas,
        appBar: AppBar(title: Text(_store.ready ? '确认导入信息' : '导入警情信息')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(DsSpacing.lg, DsSpacing.md, DsSpacing.lg, DsSpacing.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (error != null) _buildErrorBanner(context, error),
                switch (_store.stage) {
                  IncidentImportStage.input => IncidentImportInputView(
                    store: _store,
                    textController: _textController,
                    textFocusNode: _textFocusNode,
                    onPickCamera: () => _pickImages(ImageSource.camera),
                    onPickGallery: () => _pickImages(ImageSource.gallery),
                    onPreviewImage: (int i) => _previewBytes('第${i + 1}张图片', _store.images[i]),
                  ),
                  IncidentImportStage.polling => _buildPollingView(context),
                  IncidentImportStage.confirm => IncidentImportConfirmView(
                    store: _store,
                    titleController: _titleController,
                    fieldControllers: _fieldControllers,
                    extraControllers: _extraControllers,
                    contactsController: _contactsController,
                    onEditForce: _editForce,
                    onPreviewTaskImage: _previewTaskImage,
                    onRequestCancel: _confirmCancelTask,
                    onApply: _handleApply,
                  ),
                },
              ],
            ),
          ),
        ),
        bottomNavigationBar: _buildBottomBar(),
      ),
    );
  }
}
