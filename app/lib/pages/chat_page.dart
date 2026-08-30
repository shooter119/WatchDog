import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/audio_service.dart';
import '../services/op_log_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import '../theme/assistant_avatar.dart';

/// 智能体问答页「辅助」：文字输入 + 就地语音提问，AI 解答火场困难。
/// 辅助页语音转写结果只作为本页提问发送，不参与火场语音意图路由。
class ChatPage extends StatefulWidget {
  final AppController controller;
  final VoidCallback? onBack; // 顶部返回按钮（回进入前的来源页），辅助页底部不再展示全部导航入口
  final ValueChanged<bool>? onRecordingChanged;
  final ValueChanged<bool>? onProcessingChanged;
  final ValueChanged<bool>? onSendingChanged; // 问答请求中（驱动底部发送按钮禁用态）
  final AudioService? audioService; // 测试注入
  final Duration requestTimeout;

  const ChatPage({
    super.key,
    required this.controller,
    this.onBack,
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

  List<ChatMessage> _messages = [];
  // 本机历史异步读取不应阻塞辅助页首屏；未读完时先展示欢迎态。
  bool _loading = false;
  bool _sending = false;
  bool _recording = false;
  bool _processing = false;
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
    _loadHistory();
  }

  @override
  void dispose() {
    _recordingRequested = false;
    _recordingGeneration++;
    _recordingStarting = false;
    _stopRecordingTimer();
    _endOp('page_disposed');
    widget.controller.cancelAssistantRequest();
    _scroll.dispose();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final loadGeneration = _historyGeneration;
    try {
      final history = await widget.controller.fetchChatHistory();
      if (!mounted) return;
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
      await _audio.start();
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
      final bytes = await _audio.stop();
      String text;
      try {
        text = await widget.controller.transcribeAudio(bytes, opId: opId);
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
      child: Column(
        children: [
          _buildHeader(context),
          if (_recording) _buildRecordingHint(),
          Expanded(child: _buildBody()),
          Container(
            width: double.infinity,
            color: AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: const Text(
              '水元素建议仅供参考，现场以指挥员口令和现行规程为准。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingHint() {
    final warning = _recordingSeconds >= _recordingWarningDuration.inSeconds;
    return Container(
      key: const Key('chat-recording-limit'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
        style: TextStyle(
          color: warning ? AppColors.caution : AppColors.voice,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      key: const Key('chat-header'),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            tooltip: '返回',
            color: AppColors.textSecondary,
            visualDensity: VisualDensity.compact,
          ),
          const Spacer(),
          IconButton(
            onPressed: _messages.isEmpty || _sending || _clearing
                ? null
                : _confirmClear,
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            tooltip: '清空问答记录',
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
      return _buildWelcome();
    }
    return Column(
      children: [
        if (_error != null)
          Container(
            width: double.infinity,
            color: AppColors.alarm.withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: AppColors.alarm),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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

  Widget _buildWelcome() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const AssistantAvatar(size: 112),
              const SizedBox(height: 12),
              const Text(
                '你好，我是水元素',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                '火场里遇到困难，按住底部语音按钮说话，\n或在这里输入问题，我来帮你支招。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              const _SampleQuestion('气瓶压力下降太快怎么办？'),
              const SizedBox(height: 8),
              const _SampleQuestion('浓烟太大看不清路，有什么办法？'),
              const SizedBox(height: 8),
              const _SampleQuestion('破拆卷帘门有哪些注意事项？'),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.alarm),
            ),
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
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final timeText =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            const AssistantAvatar(size: 30, margin: EdgeInsets.only(right: 8)),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: isUser ? AppColors.actionPrimary : AppColors.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(AppRadius.md),
                      topRight: const Radius.circular(AppRadius.md),
                      bottomLeft: Radius.circular(
                        isUser ? AppRadius.md : AppRadius.sm,
                      ),
                      bottomRight: Radius.circular(
                        isUser ? AppRadius.sm : AppRadius.md,
                      ),
                    ),
                    border: isUser ? null : Border.all(color: AppColors.border),
                    boxShadow: AppShadow.card,
                  ),
                  child: isUser
                      ? Text(
                          message.content,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: isUser
                                ? Colors.white
                                : AppColors.textPrimary,
                          ),
                        )
                      : MarkdownBody(
                          data: body,
                          styleSheet:
                              MarkdownStyleSheet.fromTheme(
                                Theme.of(context),
                              ).copyWith(
                                p: const TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                  color: AppColors.textPrimary,
                                ),
                                h1: const TextStyle(
                                  fontSize: 17,
                                  height: 1.4,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                h2: const TextStyle(
                                  fontSize: 16,
                                  height: 1.4,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                h3: const TextStyle(
                                  fontSize: 15,
                                  height: 1.4,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                                strong: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                                em: const TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: AppColors.textPrimary,
                                ),
                                blockquote: const TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: AppColors.textSecondary,
                                ),
                                blockquoteDecoration: BoxDecoration(
                                  color: AppColors.surfaceSubtle.withValues(
                                    alpha: 0.6,
                                  ),
                                  border: const Border(
                                    left: BorderSide(
                                      color: AppColors.border,
                                      width: 3,
                                    ),
                                  ),
                                ),
                                listBullet: const TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                  color: AppColors.textSecondary,
                                ),
                                code: const TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'Menlo',
                                  color: AppColors.textPrimary,
                                  backgroundColor: AppColors.surfaceSubtle,
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: AppColors.surfaceSubtle.withValues(
                                    alpha: 0.7,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.sm,
                                  ),
                                ),
                                codeblockPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                        ),
                ),
                if (followUp != null && onFollowUpTap != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Material(
                      color: AppColors.voice.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        onTap: () => onFollowUpTap!(followUp),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.quickreply_outlined,
                                size: 15,
                                color: AppColors.voice,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  '追问：$followUp',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 2, right: 2),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey('chat-copy-${message.id}'),
                          onPressed: onCopy == null || body.trim().isEmpty
                              ? null
                              : () => onCopy!(body),
                          icon: const Icon(Icons.copy_rounded),
                          tooltip: '复制',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          padding: const EdgeInsets.all(5),
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          timeText,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
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
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 8),
          Text(
            '水元素思考中…',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _SampleQuestion extends StatelessWidget {
  final String text;
  const _SampleQuestion(this.text);

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: ValueKey('chat-sample-question-$text'),
      constraints: const BoxConstraints(minHeight: 48),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onTap: () {
          final page = context.findAncestorStateOfType<ChatPageState>();
          page?.submitQuestion(text);
        },
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13.5,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
