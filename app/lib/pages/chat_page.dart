import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../models/models.dart';
import '../services/chat_history.dart';
import 'incident_details_page.dart';
import '../services/audio_service.dart';
import '../services/op_log_service.dart';
import '../services/realtime_asr_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import '../theme/assistant_avatar.dart';

/// 智能体问答页「辅助」：默认常驻底部五栏导航，页内自带轻量级语音/文字/拍照输入条，AI 解答火场困难。
/// 辅助页语音转写结果只作为本页提问发送，不参与火场语音意图路由。
class ChatPage extends StatefulWidget {
  final AppController controller;
  final ValueChanged<bool>? onRecordingChanged;
  final ValueChanged<bool>? onProcessingChanged;
  final ValueChanged<bool>? onSendingChanged; // 问答请求中（兼容外部监听）
  final AudioService? audioService; // 测试注入
  final Duration requestTimeout;

  const ChatPage({
    super.key,
    required this.controller,
    this.onRecordingChanged,
    this.onProcessingChanged,
    this.onSendingChanged,
    this.audioService,
    this.requestTimeout = const Duration(seconds: 45),
  });

  @override
  State<ChatPage> createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> {
  late final AudioService _audio = widget.audioService ?? AudioService();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  List<ChatMessage> _messages = [];
  // 本机历史异步读取不应阻塞辅助页首屏；未读完时先展示欢迎态。
  String _scope = '';
  bool _loading = false;
  bool _sending = false;
  bool _visionBusy = false;
  bool _recording = false;
  bool _processing = false;
  bool _textMode = false; // 默认「按住说话」语音条态，点击左侧图标切文字输入态
  String? _transcript;
  RealtimeAsrService? _realtime;
  String? _error;
  String? _opId;
  int _requestGeneration = 0;
  // 历史读取是异步的；页面可能先收到用户输入或清空操作。
  // 代际号让晚到的读取结果只能合并仍然有效的页面状态，不能回写旧快照。
  int _historyGeneration = 0;
  bool _historyCleared = false;
  bool _clearing = false;
  bool _recordingRequested = false;
  int _recordingGeneration = 0;
  bool _recordingStarting = false;
  static const _maxRecordingDuration = Duration(seconds: 60);
  static const _recordingWarningDuration = Duration(seconds: 50);
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;
  int _recordingSeconds = 0;

  @override
  void initState() {
    super.initState();
    _scope = widget.controller.assistantScope;
    widget.controller.addListener(_onScopeChanged);
    _loadHistory();
  }

  void _onScopeChanged() {
    final scope = widget.controller.assistantScope;
    if (scope == _scope || !mounted) return;
    _scope = scope;
    _requestGeneration++;
    _historyGeneration++;
    _historyCleared = false;
    setState(() {
      _messages = [];
      _error = null;
      _sending = false;
      _visionBusy = false;
    });
    widget.onSendingChanged?.call(false);
    _loadHistory();
  }

  Future<void> _showLegacyHistory() async {
    final history = await ChatHistory.load();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('历史通用对话'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              history.isEmpty
                  ? '没有旧版通用对话记录'
                  : history
                        .map(
                          (m) =>
                              '${m.role == 'user' ? '提问' : '回复'}：${m.content}',
                        )
                        .join('\n\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScopeChanged);
    _recordingRequested = false;
    _recordingGeneration++;
    _recordingStarting = false;
    _stopRecordingTimer();
    _endOp('page_disposed');
    widget.controller.cancelAssistantRequest();
    unawaited(_realtime?.dispose() ?? Future<void>.value());
    _inputController.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _audio.dispose();
    super.dispose();
  }

  /// 外部切换页面或点击底栏其他入口时收起输入法。
  void dismissKeyboard() {
    if (_inputFocus.hasFocus) {
      _inputFocus.unfocus();
    }
  }

  void _toggleInputMode(bool textMode) {
    setState(() => _textMode = textMode);
    if (textMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _textMode) {
          _inputFocus.requestFocus();
        }
      });
    } else {
      _inputFocus.unfocus();
    }
  }

  void _submitTextInput() {
    final clean = _inputController.text.trim();
    if (clean.isEmpty || _sending || _clearing) return;
    _inputController.clear();
    unawaited(submitQuestion(clean));
  }

  Future<void> _loadHistory() async {
    final loadGeneration = _historyGeneration;
    final loadScope = _scope;
    try {
      final history = await widget.controller.fetchChatHistory();
      if (!mounted || loadScope != _scope) return;
      final cleanedHistory = history
          .where(
            (message) =>
                message.role != 'assistant' ||
                message.content.trim().isNotEmpty,
          )
          .toList(growable: false);
      setState(() {
        if (_historyCleared) {
          // 清空已经成功：这次读取拿到的是清空前的旧快照，必须丢弃。
        } else if (loadGeneration == _historyGeneration) {
          // 没有发生页面侧写操作，可以直接采用本机历史。
          _messages = cleanedHistory;
        } else {
          // 发送先于历史返回：保留当前用户消息/流式占位，并把旧历史
          // 放在它们之前，避免异步读取覆盖页面刚产生的状态。
          final currentIds = _messages.map((message) => message.id).toSet();
          _messages = [
            ...cleanedHistory.where(
              (message) => !currentIds.contains(message.id),
            ),
            ..._messages,
          ];
        }
        _loading = false;
        if (!_historyCleared) _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载问答记录失败：$e';
      });
    }
  }

  /// 发送提问（文字输入或语音识别为提问时调用）
  Future<void> submitQuestion(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || _sending || _clearing) return;
    final history = _messages
        .where((message) => message.content.trim().isNotEmpty)
        .toList(growable: false);
    _historyGeneration++;
    final opId =
        'op-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFF).toRadixString(16)}';
    final requestGeneration = ++_requestGeneration;
    final placeholderId = 'stream-$opId';
    OpLogService.instance.record(
      opId,
      'chat_submit',
      '提交问题',
      data: {'text': clean},
      sync: false,
    );
    setState(() {
      _messages = [
        ..._messages,
        ChatMessage(
          id: 'local-$opId',
          role: 'user',
          content: clean,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
        // 流式问答占位：首个 token 到达后立即替换为增量内容
        ChatMessage(
          id: placeholderId,
          role: 'assistant',
          content: '',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
      _sending = true;
      _error = null;
      _transcript = null;
    });
    widget.onSendingChanged?.call(true);
    _scrollToBottom();
    try {
      final reply = await widget.controller
          .askAssistantStream(
            clean,
            opId: opId,
            history: history,
            onChunk: (delta) {
              if (!mounted || requestGeneration != _requestGeneration) return;
              final index = _messages.indexWhere((m) => m.id == placeholderId);
              if (index < 0) return;
              final current = _messages[index];
              setState(() {
                _messages[index] = ChatMessage(
                  id: current.id,
                  role: current.role,
                  content: '${current.content}$delta',
                  createdAt: current.createdAt,
                );
              });
              _scrollToBottom();
            },
          )
          .timeout(
            widget.requestTimeout,
            onTimeout: () {
              widget.controller.cancelAssistantRequest();
              throw TimeoutException('辅助问答响应超时，请检查网络后重试');
            },
          );
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() {
        final index = _messages.indexWhere((m) => m.id == placeholderId);
        if (index >= 0) {
          final current = _messages[index];
          _messages[index] = ChatMessage(
            id: current.id,
            role: current.role,
            content: reply,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
        _sending = false;
      });
      widget.onSendingChanged?.call(false);
      _scrollToBottom();
    } catch (e) {
      widget.controller.cancelAssistantRequest();
      // 使已被取消的底层流即使晚到，也不能重新填充“思考中”占位。
      if (requestGeneration == _requestGeneration) _requestGeneration++;
      if (!mounted) return;
      setState(() {
        // 请求失败：丢弃空占位，避免假"思考中"卡住
        _messages = _messages
            .where((message) => message.id != placeholderId)
            .toList();
        _sending = false;
        _error = '辅助回复失败：$e';
      });
      widget.onSendingChanged?.call(false);
      OpLogService.instance.record(
        opId,
        'chat_err',
        '回复失败: $e',
        level: 'error',
        sync: false,
      );
    }
  }

  Future<void> _pickVisionImage() async {
    if (_sending || _visionBusy || _clearing) return;
    final generation = _requestGeneration;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
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
    if (source == null || !mounted || generation != _requestGeneration) return;
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null || !mounted || generation != _requestGeneration) return;
    final original = await picked.readAsBytes();
    if (!mounted || generation != _requestGeneration) return;
    final decoded = img.decodeImage(original);
    if (decoded == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法读取图片，请重新选择')));
      return;
    }
    final resized = decoded.width > 1600
        ? img.copyResize(decoded, width: 1600)
        : decoded;
    final bytes = Uint8List.fromList(img.encodeJpg(resized, quality: 82));
    if (bytes.length > 8 * 1024 * 1024) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('图片过大，请重新拍摄')));
      return;
    }
    if (!mounted || generation != _requestGeneration) return;
    final question = await _askVisionQuestion();
    if (question == null || !mounted || generation != _requestGeneration) {
      return;
    }
    setState(() => _visionBusy = true);
    try {
      final analysis = await widget.controller.analyzeVision(
        bytes,
        mimeType: 'image/jpeg',
        message: question,
        opId: 'vision-${DateTime.now().millisecondsSinceEpoch}',
      );
      if (!mounted || generation != _requestGeneration) return;
      final reply = _formatVisionAnalysis(analysis);
      setState(() {
        _messages = [
          ..._messages,
          ChatMessage(
            id: 'vision-${DateTime.now().millisecondsSinceEpoch}',
            role: 'user',
            content: '图片分析：$question',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
          ChatMessage(
            id: 'vision-result-${DateTime.now().millisecondsSinceEpoch}',
            role: 'assistant',
            content: reply,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      });
      _scrollToBottom();
    } catch (e) {
      if (mounted && generation == _requestGeneration) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('图片分析失败：$e')));
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _visionBusy = false);
      }
    }
  }

  Future<String?> _askVisionQuestion() async {
    final controller = TextEditingController(text: '请分析这张图片中与消防救援相关的内容。');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认图片分析'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '可补充关注重点'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  String _formatVisionAnalysis(VisionAnalysis a) {
    String section(String title, List<String> values) => values.isEmpty
        ? '$title\n暂无明确内容'
        : '$title\n${values.map((v) => '• $v').join('\n')}';
    final relevance = switch (a.relevance) {
      'related' => '相关',
      'unrelated' => '无关',
      'unsafe_to_judge' => '图片质量不足',
      _ => '关联性不明确',
    };
    return '**图片相关性：$relevance**\n\n${section('### 已确认事实', a.facts)}\n\n${section('### 可能风险', a.risks)}\n\n${section('### 待确认事项', a.toConfirm)}\n\n${section('### 建议措施', a.suggestions)}\n\n> ${a.disclaimer}';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _copyMessage(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
    );
  }

  /// 就地语音提问（底部语音按钮在问答页长按时调用）
  void _startRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingStartedAt = DateTime.now();
    _recordingSeconds = 0;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !_recording) {
        _stopRecordingTimer();
        return;
      }
      final wallClockSeconds = _recordingStartedAt == null
          ? 0
          : DateTime.now().difference(_recordingStartedAt!).inSeconds;
      final seconds = min(
        max(timer.tick, wallClockSeconds),
        _maxRecordingDuration.inSeconds,
      );
      if (seconds != _recordingSeconds) {
        setState(() => _recordingSeconds = seconds);
      }
      if (seconds >= _maxRecordingDuration.inSeconds) {
        _stopRecordingTimer();
        unawaited(finishRecording());
      }
    });
  }

  void _stopRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingStartedAt = null;
  }

  Future<void> beginRecording() async {
    if (_recording ||
        _processing ||
        _sending ||
        _recordingRequested ||
        _recordingStarting) {
      return;
    }
    final generation = ++_recordingGeneration;
    _recordingRequested = true;
    _recordingStarting = true;
    _opId =
        'op-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFF).toRadixString(16)}';
    OpLogService.instance.record(_opId!, 'record_start', '开始录音', sync: false);
    if (mounted) setState(() => _transcript = null);
    late final bool ok;
    try {
      ok = await _audio.hasPermission();
    } catch (e) {
      _recordingRequested = false;
      _recordingStarting = false;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('麦克风权限检查失败：$e')));
      }
      _endOp('permission_error');
      return;
    }
    if (!_recordingRequested ||
        generation != _recordingGeneration ||
        !mounted) {
      _recordingStarting = false;
      _endOp('cancelled');
      return;
    }
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('需要麦克风权限'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      OpLogService.instance.record(
        _opId!,
        'record_perm_denied',
        '缺少麦克风权限',
        level: 'warn',
        sync: false,
      );
      _endOp('perm_denied');
      return;
    }
    try {
      final realtimeEnabled =
          widget.audioService == null &&
          widget.controller.asrCloudEnabled &&
          widget.controller.api != null;
      if (realtimeEnabled) {
        _realtime = RealtimeAsrService(
          api: widget.controller.api!,
          onText: (text, {required finalText}) {
            if (!mounted || (!_recording && !_recordingRequested)) return;
            setState(() => _transcript = text);
          },
        );
        try {
          await _realtime!.start(opId: _opId);
        } catch (error) {
          await _realtime!.cancel();
          await _realtime!.dispose();
          _realtime = null;
          OpLogService.instance.record(
            _opId!,
            'stream_connect_err',
            '实时识别连接失败，改用兼容录音模式: $error',
            level: 'warn',
            sync: false,
          );
          await _audio.start();
        }
      } else {
        await _audio.start();
      }
      if (!_recordingRequested ||
          generation != _recordingGeneration ||
          !mounted) {
        if (_audio.isRecording) await _audio.stop();
        _recordingStarting = false;
        _endOp('cancelled');
        return;
      }
      setState(() {
        _recording = true;
        _recordingSeconds = 0;
      });
      _recordingStarting = false;
      _startRecordingTimer();
      widget.onRecordingChanged?.call(true);
    } catch (e) {
      _recordingStarting = false;
      OpLogService.instance.record(
        _opId!,
        'record_start_err',
        '录音启动失败: $e',
        level: 'error',
        sync: false,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('录音启动失败：$e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      _endOp('record_error');
    }
  }

  /// 结束录音 → 转写 → 直接作为本页提问发送
  Future<void> finishRecording() async {
    if (!_recording) {
      _recordingRequested = false;
      _recordingGeneration++;
      _stopRecordingTimer();
      return;
    }
    _recordingRequested = false;
    _recordingGeneration++;
    _stopRecordingTimer();
    setState(() {
      _recording = false;
      _processing = true;
      _recordingSeconds = 0;
    });
    widget.onRecordingChanged?.call(false);
    widget.onProcessingChanged?.call(true);
    final opId = _opId ?? '';
    try {
      late final Uint8List bytes;
      String? realtimeText;
      final realtime = _realtime;
      if (realtime != null) {
        try {
          final result = await realtime.stop();
          bytes = result.wavBytes;
          realtimeText = result.text;
        } on RealtimeAsrException catch (error) {
          bytes = error.result.wavBytes;
          realtimeText = null;
          OpLogService.instance.record(
            opId,
            'transcribe_fallback',
            '实时识别失败，切换批量云端识别',
            level: 'warn',
            sync: false,
          );
        } finally {
          await realtime.dispose();
          _realtime = null;
        }
      } else {
        bytes = await _audio.stop();
      }
      String text;
      try {
        text = realtimeText?.trim().isNotEmpty == true
            ? realtimeText!.trim()
            : await widget.controller.transcribeAudio(bytes, opId: opId);
        if (mounted) setState(() => _transcript = text);
        OpLogService.instance.record(
          opId,
          'transcribe_ok',
          '转写成功',
          data: {'text': text},
          sync: false,
        );
      } catch (e) {
        OpLogService.instance.record(
          opId,
          'transcribe_err',
          '转写失败: $e',
          level: 'error',
          sync: false,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('识别失败：$e'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        _endOp('transcribe_error');
        return;
      }
      if (text.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('未识别到语音，请再说一次'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        OpLogService.instance.record(
          opId,
          'transcribe_empty',
          '未识别到语音',
          level: 'warn',
          sync: false,
        );
        _endOp('no_speech');
        return;
      }
      if (!mounted) {
        _endOp('page_disposed');
        return;
      }
      _endOp('chat');
      unawaited(submitQuestion(text));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('录音结束失败：$e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      _endOp('error');
    } finally {
      if (mounted) setState(() => _processing = false);
      widget.onProcessingChanged?.call(false);
    }
  }

  void _endOp(String outcome) {
    final opId = _opId;
    _opId = null;
    if (opId == null) return;
    OpLogService.instance.record(
      opId,
      'op_end',
      '本次操作结束',
      data: {'outcome': outcome},
      sync: false,
    );
  }

  Future<void> _confirmClear() async {
    if (_sending || _clearing) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空问答记录'),
        content: const Text('将删除本场景下与「辅助」的全部对话历史，确定清空？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted || _sending || _clearing) return;
    _historyGeneration++;
    setState(() => _clearing = true);
    try {
      await widget.controller.clearChatHistory();
      if (!mounted) return;
      setState(() {
        _historyCleared = true;
        _messages = [];
        _clearing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _clearing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('清空失败：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildHeader(context),
          if (widget.controller.currentIncident?.info.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.s4,
                right: AppSpacing.s4,
                bottom: AppSpacing.s2,
              ),
              child: Material(
                color: AppColors.surfaceSubtle,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  side: BorderSide(color: AppColors.border, width: 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const Key('chat-incident-context-pill'),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  onTap: () {
                    final api = widget.controller.api;
                    final incident = widget.controller.currentIncident;
                    if (api != null && incident != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => IncidentDetailsPage(
                            api: api,
                            incident: incident,
                            controller: widget.controller,
                          ),
                        ),
                      );
                    }
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s4,
                        vertical: AppSpacing.s2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: AppColors.actionPrimary,
                          ),
                          const SizedBox(width: AppSpacing.s2),
                          Flexible(
                            child: Text(
                              '已结合当前警情资料 · 查看背景',
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.actionPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.s1),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: AppColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_recording) _buildRecordingHint(),
          Expanded(child: _buildBody()),
          _buildInputBar(context),
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context) {
    final busy = _sending || _visionBusy || _clearing;
    return Container(
      key: const Key('chat-input-bar'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            key: const Key('chat-mode-toggle'),
            onPressed: _recording || _processing
                ? null
                : () => _toggleInputMode(!_textMode),
            tooltip: _textMode ? '切换为语音提问' : '切换为文字输入',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(
              _textMode ? Icons.mic_none_rounded : Icons.keyboard_alt_outlined,
              size: 24,
            ),
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.s1),
          Expanded(
            child: _textMode
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 108),
                    child: TextField(
                      key: const Key('chat-text-field'),
                      controller: _inputController,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitTextInput(),
                      decoration: const InputDecoration(
                        hintText: '输入现场问题…',
                        isDense: true,
                      ),
                    ),
                  )
                : _buildHoldToTalkBar(context),
          ),
          const SizedBox(width: AppSpacing.s1),
          IconButton(
            key: const Key('chat-vision-button'),
            onPressed: busy || _recording ? null : _pickVisionImage,
            tooltip: '拍照分析',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: _visionBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.camera_alt_outlined, size: 24),
            color: AppColors.textSecondary,
          ),
          if (_textMode) ...[
            const SizedBox(width: AppSpacing.s1),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _inputController,
              builder: (context, value, _) {
                final canSend =
                    !_sending && !_clearing && value.text.trim().isNotEmpty;
                return FilledButton(
                  key: const Key('chat-send-button'),
                  onPressed: canSend ? _submitTextInput : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: _sending
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 20),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHoldToTalkBar(BuildContext context) {
    final canRecord = !_processing && !_sending && !_clearing;
    final label = _recording
        ? '正在聆听 · 松开发送'
        : _processing
        ? '正在识别语音…'
        : _sending
        ? '正在生成回复，请稍候…'
        : '按住向水元素提问';
    final bgColor = _recording ? AppColors.voice : AppColors.surfaceSubtle;
    final borderColor = _recording ? AppColors.voice : AppColors.border;
    final fgColor = _recording ? AppColors.onPrimary : AppColors.textPrimary;
    final iconColor = _recording ? AppColors.onPrimary : AppColors.voice;

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        key: const Key('chat-hold-to-talk'),
        onTap: () {
          if (_recording) {
            unawaited(finishRecording());
            return;
          }
          if (!canRecord) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('请按住说话提问，或点左侧键盘输入文字'),
                duration: Duration(seconds: 1),
              ),
            );
        },
        onLongPressStart: canRecord
            ? (_) {
                HapticFeedback.mediumImpact();
                unawaited(beginRecording());
              }
            : null,
        onLongPressEnd: (_) {
          unawaited(finishRecording());
        },
        onLongPressCancel: () {
          if (_recording || _recordingRequested) {
            unawaited(finishRecording());
          }
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s3,
            vertical: AppSpacing.s2,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_processing)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textSecondary,
                  ),
                )
              else
                Icon(
                  _recording ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                  size: 20,
                  color: iconColor,
                ),
              const SizedBox(width: AppSpacing.s2),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.label.copyWith(
                    color: _recording
                        ? fgColor
                        : canRecord
                        ? fgColor
                        : AppColors.textTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingHint() {
    final warning = _recordingSeconds >= _recordingWarningDuration.inSeconds;
    return Container(
      key: const Key('chat-recording-limit'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        0,
        AppSpacing.s4,
        AppSpacing.s2,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: (warning ? AppColors.caution : AppColors.voice).withValues(
          alpha: 0.10,
        ),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        warning
            ? '录音还剩 ${max(0, _maxRecordingDuration.inSeconds - _recordingSeconds)} 秒，时间到将自动结束'
            : '录音中 · 最长 60 秒 · 已录 $_recordingSeconds 秒',
        textAlign: TextAlign.center,
        style: AppTextStyles.caption.copyWith(
          color: warning ? AppColors.caution : AppColors.voice,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      key: const Key('chat-header'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s3,
        AppSpacing.s2,
        AppSpacing.s2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              '辅助问答',
              style: AppTextStyles.h1.copyWith(color: AppColors.textPrimary),
            ),
          ),
          if (_messages.isNotEmpty)
            IconButton(
              onPressed: _sending || _clearing ? null : _confirmClear,
              icon: const Icon(Icons.delete_sweep_outlined, size: 24),
              tooltip: '清空问答记录',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              color: AppColors.textTertiary,
            ),
          IconButton(
            onPressed: _showLegacyHistory,
            tooltip: '历史通用对话',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.history, size: 24),
            color: AppColors.textTertiary,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_messages.isEmpty) {
      return Column(
        children: [
          Expanded(child: _buildWelcome()),
          if (_recording || (_processing && _transcript != null))
            _buildTranscriptPreview(),
        ],
      );
    }
    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s2,
              AppSpacing.s4,
              0,
            ),
            child: AppNotice(kind: AppNoticeKind.error, text: _error!),
          ),
        if (_recording || (_processing && _transcript != null))
          _buildTranscriptPreview(),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s3,
              AppSpacing.s4,
              AppSpacing.s6,
            ),
            itemCount: _messages.length,
            itemBuilder: (context, i) {
              final m = _messages[i];
              // 请求占位（内容为空）：显示"水元素思考中…"气泡，完整回复到达后自动切换
              if (m.role == 'assistant' && m.content.isEmpty) {
                return _sending
                    ? const _ThinkingBubble()
                    : const SizedBox.shrink();
              }
              return _MessageBubble(
                message: m,
                onFollowUpTap: m.isUser ? null : (q) => submitQuestion(q),
                onCopy: _copyMessage,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTranscriptPreview() {
    final text = _transcript?.trim();
    final hasText = text != null && text.isNotEmpty;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s1,
        AppSpacing.s4,
        AppSpacing.s2,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: AppColors.voice.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.voice.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            hasText ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
            size: 18,
            color: AppColors.voice,
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              hasText ? text : '正在识别语音…',
              style: AppTextStyles.bodyMd.copyWith(
                height: 1.5,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcome() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s1,
        AppSpacing.s4,
        AppSpacing.s2,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s1,
            vertical: AppSpacing.s1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: AssistantAvatar(size: 64)),
              const SizedBox(height: AppSpacing.s2),
              Text(
                '你好，我是水元素',
                textAlign: TextAlign.center,
                style: AppTextStyles.h2.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.s1),
              Text(
                '现场危化速查 · 战术支招 · 拍照识险',
                textAlign: TextAlign.center,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              _VisionCallout(onTap: _pickVisionImage),
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.s3,
                  bottom: AppSpacing.s1 + 2,
                ),
                child: Text(
                  '常见紧急提问',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const _SampleQuestion(
                '气瓶压力下降太快怎么办？',
                icon: Icons.gas_meter_outlined,
              ),
              const SizedBox(height: 6),
              const _SampleQuestion(
                '浓烟中看不清路怎么办？',
                icon: Icons.visibility_off_outlined,
              ),
              const SizedBox(height: 6),
              const _SampleQuestion(
                '破拆卷帘门有哪些注意事项？',
                icon: Icons.blinds_closed_outlined,
              ),
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.s3,
                  bottom: AppSpacing.s1,
                ),
                child: Text(
                  '建议仅供参考，以指挥口令和规程为准。',
                  key: const Key('chat-disclaimer-footnote'),
                  textAlign: TextAlign.center,
                  style: AppTextStyles.caption.copyWith(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s3),
            child: AppNotice(kind: AppNoticeKind.error, text: _error!),
          ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final ValueChanged<String>? onFollowUpTap; // 点击「追问」直接发送该问题
  final ValueChanged<String>? onCopy;
  const _MessageBubble({
    required this.message,
    this.onFollowUpTap,
    this.onCopy,
  });

  /// 从 AI 回复中解析「追问：xxx」段：返回 (正文, 追问问题)
  /// 回复固定三段（结论/立即行动/注意事项），注意事项尾部常带一句追问
  static (String body, String? followUp) splitFollowUp(String content) {
    final re = RegExp(r'\*{0,2}(关键)?\s*追问\s*[：:]\s*');
    final matches = re.allMatches(content).toList();
    if (matches.isEmpty) return (content, null);
    final m = matches.last;
    final body = content.substring(0, m.start).trim();
    var rest = content.substring(m.end).trim();
    rest = rest.replaceAll(RegExp(r'^\*\*|\*\*$'), '').trim();
    if (rest.isEmpty) return (content, null);
    return (body, rest);
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final split = isUser
        ? (message.content, null)
        : splitFollowUp(message.content);
    final body = split.$1;
    final followUp = split.$2;
    final followUpLabel = followUp == null ? null : '我想进一步确认：$followUp';
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final timeText =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.s1, right: AppSpacing.s2),
              child: AssistantAvatar(size: 32),
            ),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                AppCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4,
                    vertical: AppSpacing.s3,
                  ),
                  color: isUser ? AppColors.actionPrimary : AppColors.surface,
                  side: isUser
                      ? BorderSide(color: AppColors.actionPrimary, width: 1)
                      : BorderSide(color: AppColors.border, width: 1),
                  radius: AppRadius.md,
                  child: isUser
                      ? Text(
                          message.content,
                          style: AppTextStyles.bodyMd.copyWith(
                            height: 1.5,
                            color: AppColors.onPrimary,
                          ),
                        )
                      : MarkdownBody(
                          data: body,
                          styleSheet:
                              MarkdownStyleSheet.fromTheme(
                                Theme.of(context),
                              ).copyWith(
                                p: AppTextStyles.bodyMd.copyWith(
                                  height: 1.5,
                                  color: AppColors.textPrimary,
                                ),
                                h1: AppTextStyles.h2.copyWith(
                                  height: 1.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                h2: AppTextStyles.bodyLg.copyWith(
                                  height: 1.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                h3: AppTextStyles.bodyMd.copyWith(
                                  height: 1.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                h4: AppTextStyles.bodyMd.copyWith(
                                  height: 1.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                h5: AppTextStyles.label.copyWith(
                                  height: 1.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                h6: AppTextStyles.label.copyWith(
                                  height: 1.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                strong: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                em: TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: AppColors.textPrimary,
                                ),
                                blockquote: AppTextStyles.bodyMd.copyWith(
                                  height: 1.5,
                                  color: AppColors.textSecondary,
                                ),
                                blockquoteDecoration: BoxDecoration(
                                  color: AppColors.surfaceSubtle
                                      .withValues(alpha: 0.6),
                                  border: Border(
                                    left: BorderSide(
                                      color: AppColors.border,
                                      width: 3,
                                    ),
                                  ),
                                ),
                                listBullet: AppTextStyles.bodyMd.copyWith(
                                  height: 1.5,
                                  color: AppColors.textSecondary,
                                ),
                                code: AppTextStyles.label.copyWith(
                                  fontFamily: 'Menlo',
                                  color: AppColors.textPrimary,
                                  backgroundColor:
                                      AppColors.surfaceSubtle,
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: AppColors.surfaceSubtle
                                      .withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.sm,
                                  ),
                                ),
                                codeblockPadding:
                                    const EdgeInsets.symmetric(
                                      horizontal: AppSpacing.s3,
                                      vertical: AppSpacing.s2,
                                    ),
                              ),
                        ),
                ),
                if (followUpLabel != null && onFollowUpTap != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s2),
                    child: Material(
                      color: AppColors.actionPrimary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        onTap: () => onFollowUpTap!(followUp!),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.s3,
                              vertical: AppSpacing.s2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.north_east_rounded,
                                  size: 15,
                                  color: AppColors.actionPrimary,
                                ),
                                const SizedBox(width: AppSpacing.s2),
                                Flexible(
                                  child: Text(
                                    followUpLabel,
                                    style: AppTextStyles.label.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.s1,
                    left: AppSpacing.s1,
                    right: AppSpacing.s1,
                  ),
                  child: Row(
                    mainAxisAlignment: isUser
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.spaceBetween,
                    children: [
                      if (!isUser) ...[
                        Expanded(
                          child: Text(
                            '仅供参考，以指挥口令和规程为准',
                            style: AppTextStyles.caption.copyWith(
                              fontSize: 11,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s2),
                      ],
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('chat-copy-${message.id}'),
                            onPressed: onCopy == null || body.trim().isEmpty
                                ? null
                                : () => onCopy!(body),
                            icon: const Icon(Icons.copy_rounded),
                            tooltip: '复制',
                            iconSize: 20,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            padding: const EdgeInsets.all(AppSpacing.s2),
                            color: AppColors.textTertiary,
                          ),
                          const SizedBox(width: AppSpacing.s1),
                          Text(
                            timeText,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AssistantAvatar(size: 32, margin: EdgeInsets.only(right: AppSpacing.s2)),
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: AppSpacing.s2),
          Text(
            '水元素思考中…',
            style: AppTextStyles.label.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 视觉动作卡：暖橙强调底 + 实心相机徽标，与下方白底预设提问卡明显区分。
class _VisionCallout extends StatelessWidget {
  final VoidCallback onTap;

  const _VisionCallout({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('chat-vision-callout'),
      onTap: onTap,
      color: AppColors.voice.withValues(alpha: 0.08),
      side: BorderSide(color: AppColors.voice.withValues(alpha: 0.35), width: 1),
      radius: AppRadius.md,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2 + 2,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.voice,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(
                Icons.camera_alt_rounded,
                size: 20,
                color: AppColors.onPrimary,
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '拍照分析现场',
                    style: AppTextStyles.label.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    '识别危化标牌、装备与环境风险',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppColors.voice,
            ),
          ],
        ),
      ),
    );
  }
}

/// 预设提问轻量列表行：三条等高防截断，右侧用提问引导箭头与拍照动作卡区分。
class _SampleQuestion extends StatelessWidget {
  final String text;
  final IconData icon;
  const _SampleQuestion(this.text, {required this.icon});

  static const _titles = [
    '气瓶压力下降太快怎么办？',
    '浓烟中看不清路怎么办？',
    '破拆卷帘门有哪些注意事项？',
  ];

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.label.copyWith(
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 三条预设提问按最长标题统一高度，大字与窄屏下也不截断文字。
        final textWidth = max(1.0, constraints.maxWidth - 96);
        var textHeight = 0.0;
        for (final title in _titles) {
          final painter = TextPainter(
            text: TextSpan(text: title, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: textWidth);
          textHeight = max(textHeight, painter.height);
          painter.dispose();
        }
        final minCardHeight = max(48.0, textHeight + AppSpacing.s2 * 2);
        return ConstrainedBox(
          key: ValueKey('chat-sample-question-$text'),
          constraints: BoxConstraints(minHeight: minCardHeight),
          child: AppCard(
            onTap: () {
              final page = context.findAncestorStateOfType<ChatPageState>();
              page?.submitQuestion(text);
            },
            color: AppColors.surface,
            radius: AppRadius.md,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3,
              vertical: AppSpacing.s2,
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSubtle,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(icon, size: 17, color: AppColors.textSecondary),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(child: Text(text, style: style)),
                const SizedBox(width: AppSpacing.s2),
                Icon(
                  Icons.north_east_rounded,
                  size: 16,
                  color: AppColors.textTertiary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
