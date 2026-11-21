import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../../services/camera_bridge.dart';
import '../../../services/local_asr_service.dart';
import '../../../services/local_media_store.dart';
import '../../../services/media_capture_service.dart';
import '../../../services/media_share_service.dart';
import 'media_gateway.dart';

/// 导出/分享操作返回结果。
@immutable
class MediaExportResult {
  const MediaExportResult.completed(this.outcome) : errorMessage = null;
  const MediaExportResult.failed(this.errorMessage) : outcome = null;

  final MediaReviewOutcome? outcome;
  final String? errorMessage;

  bool get succeeded => outcome != null;
}

/// 现场记录核对页状态管理：
/// - 400ms 口述草稿防抖落盘与退出兜底冲刷
/// - 视频离线/联网 ASR 派生、进度跟踪、重试与取消竞态隔离
/// - 严格防串警情写入守卫（实时读取当前警情，忽略媒体上的历史 incidentId）
/// - 原图/母版 + 水印版成对相册导出与分享重试幂等
class MediaReviewStore extends ChangeNotifier {
  MediaReviewStore({
    required this.gateway,
    required LocalMedia initialMedia,
    bool initialDeriving = false,
  }) : _media = initialMedia,
       _lastText = initialMedia.transcript,
       _savedDraft = initialMedia.transcript,
       _submitted = initialMedia.observationId.isNotEmpty,
       _deriving = initialDeriving,
       transcriptController = TextEditingController(
         text: initialMedia.transcript,
       ) {
    transcriptController.addListener(_onTranscriptChanged);
    if (_deriving) {
      unawaited(runDerive());
    }
  }

  static const Duration draftDebounce = Duration(milliseconds: 400);

  final MediaGateway gateway;
  final TextEditingController transcriptController;

  LocalMedia _media;
  Timer? _draftTimer;
  String _lastText;
  String _savedDraft;
  bool _busy = false;
  bool _deriving;
  bool _submitted;
  bool _pairSaved = false;
  String _stage = '';
  String? _deriveError;
  int _deriveRun = 0;
  bool _disposed = false;

  LocalMedia get media => _media;
  bool get busy => _busy;
  bool get deriving => _deriving;
  bool get submitted => _submitted;
  bool get pairSaved => _pairSaved;
  String get stage => _stage;
  String? get deriveError => _deriveError;

  MediaIncidentRef? get currentIncident => gateway.readCurrentIncident();
  bool get hasIncident => (currentIncident?.id ?? '').isNotEmpty;
  String get incidentName => currentIncident?.displayName ?? '';
  bool get hasText => transcriptController.text.trim().isNotEmpty;
  bool get actionsEnabled => !_busy && !_deriving;

  String get timeText {
    final dt = DateTime.fromMillisecondsSinceEpoch(_media.capturedAt);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String get durationText {
    if (!_media.isVideo) return '照片';
    final seconds = (_media.durationMs / 1000).round();
    return '视频 ${seconds}s';
  }

  String? get firstExistingFramePath {
    for (final frame in _media.frames) {
      if (File(frame).existsSync()) return frame;
    }
    return null;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _onTranscriptChanged() {
    final text = transcriptController.text;
    if (text == _lastText) return;
    _lastText = text;
    _draftTimer?.cancel();
    if (text != _savedDraft) {
      _draftTimer = Timer(draftDebounce, () {
        unawaited(persistDraft());
      });
    }
    _emit();
  }

  Future<void> persistDraft() async {
    final text = transcriptController.text;
    if (text == _savedDraft) return;
    try {
      await LocalMediaStore.instance.updateDerived(
        id: _media.id,
        transcript: text,
      );
      _savedDraft = text;
    } catch (_) {
      // 本机存储暂不可用时保留内存内容，下次编辑或写入前再次尝试。
    }
  }

  Future<void> flushDraft() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    await persistDraft();
  }

  Future<void> runDerive() async {
    final run = ++_deriveRun;
    String? error;
    LocalMedia result;
    try {
      result = await runMediaDerive(
        _media,
        gateway: gateway,
        onProgress: (nextStage) {
          if (_disposed || run != _deriveRun) return;
          _stage = nextStage;
          _emit();
        },
        onError: (message) => error = message,
        isCancelled: () => _disposed || run != _deriveRun,
      );
    } catch (e) {
      error = '识别失败：$e';
      result = _media;
    }
    if (_disposed || run != _deriveRun) return;
    _media = result;
    _deriving = false;
    _stage = '';
    _deriveError = error;
    _emit();
    if (transcriptController.text.trim().isEmpty &&
        result.transcript.isNotEmpty) {
      transcriptController.text = result.transcript;
    }
  }

  void retryDerive() {
    if (_deriving) return;
    _deriving = true;
    _deriveError = null;
    _stage = '';
    _emit();
    unawaited(runDerive());
  }

  void cancelDerive() {
    _deriveRun++;
    _deriving = false;
    _stage = '';
    _deriveError = null;
    _emit();
  }

  void dismissDeriveError() {
    _deriveError = null;
    _emit();
  }

  /// 确认后写入当前警情；在调用服务端接口前再次校验实时警情 ID，防止串警情写入。
  Future<String?> submitObservation(String text) async {
    if (_submitted || _busy) return null;
    final incidentId = gateway.readCurrentIncident()?.id ?? '';
    if (incidentId.isEmpty) {
      return '还没有关联警情，先加入或新建警情才能写入';
    }
    final submitter = gateway.createIncidentObservation;
    if (submitter == null || !gateway.canSubmitObservation) {
      _busy = true;
      _emit();
      await flushDraft();
      if (_disposed) return null;
      _busy = false;
      _emit();
      return '未连接服务器，口述文字已保存在本机草稿，联网后可再写入';
    }
    _busy = true;
    _emit();
    try {
      await submitter(
        incidentId: incidentId,
        transcript: text,
        sourceType: _media.kind,
        capturedAt: _media.capturedAt,
        mediaRef: _media.id,
      );
      await LocalMediaStore.instance.updateDerived(
        id: _media.id,
        transcript: text,
        observationId: _media.id,
      );
      _savedDraft = text;
      if (_disposed) return null;
      _submitted = true;
      _busy = false;
      _emit();
      final latestIncidentId = gateway.readCurrentIncident()?.id ?? '';
      if (latestIncidentId.isNotEmpty) {
        final refresher = gateway.refreshIncidentData;
        if (refresher != null) {
          unawaited(refresher(latestIncidentId).catchError((_) {}));
        }
      }
      return '已写入警情，可继续仅保存或保存并分享';
    } catch (error) {
      if (_disposed) return null;
      await flushDraft();
      if (_disposed) return null;
      _busy = false;
      _emit();
      return '写入失败：$error；文字已保存在本机草稿';
    }
  }

  Future<void> _autoSubmitIfNeeded() async {
    if (_submitted || !hasIncident || !hasText) return;
    final submitter = gateway.createIncidentObservation;
    if (submitter == null || !gateway.canSubmitObservation) return;
    final incidentId = gateway.readCurrentIncident()?.id ?? '';
    if (incidentId.isEmpty) return;
    final text = transcriptController.text.trim();
    if (text.isEmpty) return;
    try {
      await submitter(
        incidentId: incidentId,
        transcript: text,
        sourceType: _media.kind,
        capturedAt: _media.capturedAt,
        mediaRef: _media.id,
      );
      await LocalMediaStore.instance.updateDerived(
        id: _media.id,
        transcript: text,
        observationId: _media.id,
      );
      _savedDraft = text;
      _submitted = true;
      final latestIncidentId = gateway.readCurrentIncident()?.id ?? '';
      if (latestIncidentId.isNotEmpty) {
        final refresher = gateway.refreshIncidentData;
        if (refresher != null) {
          unawaited(refresher(latestIncidentId).catchError((_) {}));
        }
      }
    } catch (_) {
      // 自动写入失败不阻断相册导出，文本仍保留在本地草稿中。
    }
  }

  Future<bool> _savePair() async {
    if (_pairSaved) return true;
    final sourcePath = _media.sourcePath;
    final saved = sourcePath.isNotEmpty
        ? await CameraBridge.savePairToGallery(
                watermarkedPath: _media.path,
                sourcePath: sourcePath,
              ) !=
              null
        : await CameraBridge.saveToGallery(_media.path) != null;
    if (!_disposed) {
      _pairSaved = saved;
      _emit();
    }
    return saved;
  }

  Future<MediaExportResult?> saveOnly() async {
    if (_busy || _deriving) return null;
    final paired = _media.sourcePath.isNotEmpty;
    _busy = true;
    _emit();
    await flushDraft();
    await _autoSubmitIfNeeded();
    final saved = await _savePair();
    if (!saved) {
      if (!_disposed) {
        _busy = false;
        _emit();
      }
      return const MediaExportResult.failed('两份相册文件保存失败，已回滚，核对页仍保留');
    }
    return MediaExportResult.completed(
      paired
          ? MediaReviewOutcome.saved
          : MediaReviewOutcome.savedWatermarkedOnly,
    );
  }

  Future<MediaExportResult?> saveAndShare() async {
    if (_busy || _deriving) return null;
    final paired = _media.sourcePath.isNotEmpty;
    _busy = true;
    _emit();
    await flushDraft();
    await _autoSubmitIfNeeded();
    final saved = await _savePair();
    if (!saved) {
      if (!_disposed) {
        _busy = false;
        _emit();
      }
      return const MediaExportResult.failed('两份相册文件保存失败，已回滚，未打开分享');
    }
    try {
      await MediaShareService.shareWatermarked(_media.path);
    } catch (_) {
      if (!_disposed) {
        _busy = false;
        _emit();
      }
      return const MediaExportResult.failed('两份已保存到相册，系统分享不可用，可重试');
    }
    return MediaExportResult.completed(
      paired
          ? MediaReviewOutcome.shared
          : MediaReviewOutcome.sharedWatermarkedOnly,
    );
  }

  Future<void> cleanupLocalCopy() =>
      MediaCaptureService.removeLocalCopy(_media);

  /// 删除指定分段的误识别文字，返回删除前原文以便提供撤销。
  String? removeSegment(LocalAsrSegment segment) {
    final before = transcriptController.text;
    final next = before.replaceFirst(segment.text, '').trim();
    if (next == before) return null;
    transcriptController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    return before;
  }

  void restoreTranscript(String previous) {
    if (_disposed) return;
    transcriptController.value = TextEditingValue(
      text: previous,
      selection: TextSelection.collapsed(offset: previous.length),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _draftTimer?.cancel();
    if (transcriptController.text != _savedDraft) {
      unawaited(persistDraft());
    }
    transcriptController.removeListener(_onTranscriptChanged);
    transcriptController.dispose();
    super.dispose();
  }
}
