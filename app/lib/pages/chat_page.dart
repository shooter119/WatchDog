import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/models.dart';
import '../services/audio_service.dart';
import '../services/op_log_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import '../theme/assistant_avatar.dart';
import '../api/api_client.dart' show ApiClient;

/// 智能体问答页「辅助」：文字输入 + 就地语音提问，AI 解答火场困难。
/// 语音识别结果按意图路由：提问留本页发送；进出场/日志交 main 跳转对应页面。
class ChatPage extends StatefulWidget {
  final AppController controller;
  final VoidCallback? onBack; // 顶部返回按钮（回进入前的来源页），辅助页底部不再展示全部导航入口
  final void Function(String text, ParseResult parsed)?
  onEntryExit; // 语音识别为进出场：交语音页确认
  final ValueChanged<String>? onNote; // 语音识别为日志：记入日志并跳日志页
  final ValueChanged<bool>? onRecordingChanged;
  final ValueChanged<bool>? onProcessingChanged;
  final ValueChanged<bool>? onSendingChanged; // 问答请求中（驱动底部发送按钮禁用态）
  final AudioService? audioService; // 测试注入

  const ChatPage({
    super.key,
    required this.controller,
    this.onBack,
    this.onEntryExit,
    this.onNote,
    this.onRecordingChanged,
    this.onProcessingChanged,
    this.onSendingChanged,
    this.audioService,
  });

  @override
  State<ChatPage> createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> {
  late final AudioService _audio = widget.audioService ?? AudioService();
  final ScrollController _scroll = ScrollController();

  List<ChatMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  bool _recording = false;
  bool _processing = false;
  String? _error;
  String? _opId;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onConfigChanged);
    _lastIncidentId = widget.controller.currentIncident?.id;
    _loadHistory();
  }

  /// 配置就绪（api 从空变为可用）后自动重试加载历史：
  /// 首次打开辅助页时尚未配置服务器 → 加载失败 → 设置页保存配置后无需重启即可恢复
  ApiClient? _lastRetryApi; // 已重试过的 api 实例（避免每秒 notify 重复请求）
  String? _lastIncidentId; // 上次加载历史的警情（切换警情后重载）
  void _onConfigChanged() {
    final a = widget.controller.api;
    final incident = widget.controller.currentIncident?.id;
    if (incident != null && incident != _lastIncidentId) {
      _lastIncidentId = incident;
      _loadHistory();
      return;
    }
    if (_error != null && a != null && !identical(a, _lastRetryApi)) {
      _lastRetryApi = a;
      _loadHistory();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onConfigChanged);
    _scroll.dispose();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await widget.controller.fetchChatHistory();
      if (!mounted) return;
      setState(() {
        _messages = history;
        _loading = false;
        _error = null;
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
    if (clean.isEmpty || _sending) return;
    final opId =
        'op-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFF).toRadixString(16)}';
    OpLogService.instance.record(
      opId,
      'chat_submit',
      '提交问题',
      data: {'text': clean},
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
        // 流式占位：内容为空时渲染"思考中"，收到首段增量后变为正常气泡
        ChatMessage(
          id: 'stream-$opId',
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
      await widget.controller.askAssistantStream(
        clean,
        opId: opId,
        onChunk: (delta) {
          if (!mounted || _messages.isEmpty) return;
          setState(() {
            final last = _messages[_messages.length - 1];
            _messages[_messages.length - 1] = ChatMessage(
              id: last.id,
              role: last.role,
              content: last.content + delta,
              createdAt: last.createdAt,
            );
          });
          _scrollToBottom();
        },
      );
      if (!mounted) return;
      setState(() => _sending = false);
      widget.onSendingChanged?.call(false);
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // 流式失败：丢弃空占位（已流出的部分保留可见），避免假"思考中"卡住
        if (_messages.isNotEmpty && _messages.last.content.isEmpty) {
          _messages = _messages.take(_messages.length - 1).toList();
        }
        _sending = false;
        _error = '辅助回复失败：$e';
      });
      widget.onSendingChanged?.call(false);
      OpLogService.instance.record(
        opId,
        'chat_err',
        '回复失败: $e',
        level: 'error',
      );
    }
    OpLogService.instance.flush(api: widget.controller.api);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// 就地语音提问（底部语音按钮在问答页长按时调用）
  Future<void> beginRecording() async {
    if (_recording || _processing || _sending) return;
    _opId =
        'op-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFF).toRadixString(16)}';
    OpLogService.instance.record(_opId!, 'record_start', '开始录音');
    final ok = await _audio.hasPermission();
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
      );
      _endOp('perm_denied');
      return;
    }
    try {
      await _audio.start();
      if (!mounted) return;
      setState(() => _recording = true);
      widget.onRecordingChanged?.call(true);
    } catch (e) {
      OpLogService.instance.record(
        _opId!,
        'record_start_err',
        '录音启动失败: $e',
        level: 'error',
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

  /// 结束录音 → 转写 → 意图判断 → 路由
  Future<void> finishRecording() async {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _processing = true;
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
        );
      } catch (e) {
        OpLogService.instance.record(
          opId,
          'transcribe_err',
          '转写失败: $e',
          level: 'error',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('识别失败：$e'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
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
        );
        return;
      }
      ParseResult parsed;
      try {
        parsed = await widget.controller.parseText(text, opId: opId);
        OpLogService.instance.record(
          opId,
          'parse_ok',
          '语义解析完成',
          data: {'text': text, 'intent': parsed.intent},
        );
      } catch (e) {
        OpLogService.instance.record(
          opId,
          'parse_err',
          '解析失败: $e',
          level: 'error',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('解析失败：$e'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      _routeIntent(parsed, text, opId);
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

  void _routeIntent(ParseResult parsed, String text, String opId) {
    switch (parsed.intent) {
      case VoiceIntent.entry:
      case VoiceIntent.exit:
        _endOp(parsed.intent);
        widget.onEntryExit?.call(text, parsed);
      case VoiceIntent.note:
        _endOp('note');
        widget.onNote?.call(text);
      case VoiceIntent.ask:
        _endOp('ask');
        submitQuestion(text);
      case VoiceIntent.ignore:
        _endOp('ignore');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('未识别到有效指令，请重新录入'),
              duration: Duration(seconds: 2),
            ),
          );
        }
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
    );
    OpLogService.instance.flush(api: widget.controller.api);
  }

  Future<void> _confirmClear() async {
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
    if (ok != true) return;
    try {
      await widget.controller.clearChatHistory();
      if (!mounted) return;
      setState(() => _messages = []);
    } catch (e) {
      if (!mounted) return;
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
            onPressed: _messages.isEmpty ? null : _confirmClear,
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
              // 流式占位（内容为空）：显示"水元素思考中…"气泡，首段增量到达后自动切换
              if (m.role == 'assistant' && m.content.isEmpty) {
                return const _ThinkingBubble();
              }
              return _MessageBubble(
                message: m,
                onFollowUpTap: m.isUser ? null : (q) => submitQuestion(q),
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
              const AssistantAvatar(size: 56),
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
  const _MessageBubble({required this.message, this.onFollowUpTap});

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
                  padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
                  child: Text(
                    timeText,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.textTertiary,
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
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: () {
        final page = context.findAncestorStateOfType<ChatPageState>();
        page?.submitQuestion(text);
      },
      child: Text(
        text,
        style: const TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
      ),
    );
  }
}
