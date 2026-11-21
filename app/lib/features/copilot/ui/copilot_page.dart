import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../design_system/design_system.dart';
import '../state/copilot_reply_parser.dart';
import '../state/copilot_store.dart';
import '../state/copilot_stream_revealer.dart';
import 'copilot_message_bubble.dart';
import 'copilot_page_chrome.dart';
import 'copilot_vision_sheet.dart';
import 'copilot_welcome_view.dart';

/// 智能辅助页（Copilot，Design System v3.0）。
///
/// 挂载于新外壳 Tab 2：支持底栏中置语音键就地录音提问（不参与火场意图路由）、
/// 左下角悬浮键盘切换文字输入、右下角悬浮拍照识险、52ms/字匀速揭示与防抢滚。
class CopilotPage extends StatefulWidget {
  const CopilotPage({
    super.key,
    required this.store,
    this.onRecordingChanged,
    this.onProcessingChanged,
    this.onSendingChanged,
    this.onOpenIncidentDetails,
    this.bottomNavClearance = 0.0,
    this.streamCharInterval = const Duration(milliseconds: 52),
    this.pickImageBytes,
  });

  final CopilotStore store;
  final ValueChanged<bool>? onRecordingChanged;
  final ValueChanged<bool>? onProcessingChanged;
  final ValueChanged<bool>? onSendingChanged;
  final VoidCallback? onOpenIncidentDetails;
  final double bottomNavClearance;
  final Duration streamCharInterval;
  final Future<Uint8List?> Function(ImageSource source)? pickImageBytes;

  @override
  State<CopilotPage> createState() => CopilotPageState();
}

class CopilotPageState extends State<CopilotPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  late final CopilotStreamRevealer _revealer;
  bool _textMode = false;
  bool _hadKeyboardOpenInTextMode = false;
  bool _autoFollowScroll = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _revealer = CopilotStreamRevealer(
      vsync: this,
      charInterval: widget.streamCharInterval,
      parseVisibleBody: (raw, {required streaming}) =>
          parseAssistantReply(raw, streaming: streaming).body,
      onReveal: (streamId, visibleText) {
        widget.store.updateStreamingMessage(streamId, visibleText);
        _maybeAutoScroll();
      },
      onComplete: (streamId, fullReply) {
        widget.store.finalizeStreamReply(streamId, fullReply);
        _maybeAutoScroll();
      },
    );
    _attachStore(widget.store);
    unawaited(widget.store.loadHistory());
  }

  @override
  void didUpdateWidget(covariant CopilotPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealer.charInterval = widget.streamCharInterval;
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onStoreChanged);
      oldWidget.store.detachUi();
      _revealer.stop();
      _attachStore(widget.store);
      unawaited(widget.store.loadHistory());
    } else if (oldWidget.onRecordingChanged != widget.onRecordingChanged ||
        oldWidget.onProcessingChanged != widget.onProcessingChanged ||
        oldWidget.onSendingChanged != widget.onSendingChanged) {
      _bindStoreCallbacks(widget.store);
    }
  }

  void _attachStore(CopilotStore store) {
    store.addListener(_onStoreChanged);
    _bindStoreCallbacks(store);
  }

  void _bindStoreCallbacks(CopilotStore store) {
    store.attachUi(
      streamCallbacks: CopilotStreamCallbacks(
        onStart: (streamId) {
          _autoFollowScroll = true;
          _revealer.begin(streamId);
          _maybeAutoScroll(force: true);
        },
        onChunk: _revealer.pushChunk,
        onComplete: _revealer.finishNetwork,
        onStop: _revealer.stop,
      ),
      onNotice: _showNotice,
      onRecordingChanged: widget.onRecordingChanged,
      onProcessingChanged: widget.onProcessingChanged,
      onSendingChanged: widget.onSendingChanged,
    );
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted || !_textMode) return;
    final insetBottom = View.of(context).viewInsets.bottom;
    if (insetBottom > 0) {
      _hadKeyboardOpenInTextMode = true;
      return;
    }
    if (_hadKeyboardOpenInTextMode) {
      _hadKeyboardOpenInTextMode = false;
      _toggleInputMode(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_onStoreChanged);
    widget.store.detachUi();
    _revealer.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 外部切换页面或长按语音键前收起软键盘。
  void dismissKeyboard() {
    if (_inputFocus.hasFocus) _inputFocus.unfocus();
  }

  /// 在智能辅助 Tab 就地开始语音提问录音。
  Future<void> beginRecording() async {
    if (_textMode) {
      _inputFocus.unfocus();
      _textMode = false;
      _hadKeyboardOpenInTextMode = false;
      if (mounted) setState(() {});
    }
    await widget.store.beginRecording();
  }

  /// 结束就地语音录音并自动提交转写提问。
  Future<void> finishRecording() => widget.store.finishRecording();

  /// 提交问题（文字输入、语音提问、示例提问或追问胶囊点击）。
  Future<void> submitQuestion(String text) {
    _autoFollowScroll = true;
    return widget.store.submitQuestion(text);
  }

  void _toggleInputMode(bool textMode) {
    if (textMode) {
      final keyboardAlreadyOpen = View.of(context).viewInsets.bottom > 0;
      setState(() {
        _textMode = true;
        _hadKeyboardOpenInTextMode = keyboardAlreadyOpen;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _textMode) _inputFocus.requestFocus();
      });
    } else {
      _inputFocus.unfocus();
      setState(() {
        _textMode = false;
        _hadKeyboardOpenInTextMode = false;
      });
    }
  }

  void _submitTextInput() {
    final clean = _inputController.text.trim();
    if (clean.isEmpty || widget.store.sending || widget.store.clearing) return;
    _inputController.clear();
    _toggleInputMode(false);
    unawaited(submitQuestion(clean));
  }

  Future<void> _showLegacyHistory() async {
    final history = await widget.store.loadLegacyHistory();
    if (!mounted) return;
    await showCopilotLegacyHistorySheet(context, history);
  }

  Future<void> _confirmClear() async {
    if (widget.store.sending || widget.store.clearing) return;
    final confirmed = await showCopilotClearConfirmSheet(context);
    if (!confirmed || !mounted) return;
    await widget.store.clearHistory();
  }

  Future<void> _pickVisionImage() async {
    final store = widget.store;
    if (store.busy) return;
    final generation = store.requestGeneration;
    final source = await showCopilotVisionSourceSheet(context);
    if (source == null || !mounted || generation != store.requestGeneration) {
      return;
    }
    final Uint8List? original;
    if (widget.pickImageBytes != null) {
      original = await widget.pickImageBytes!(source);
    } else {
      final picked = await ImagePicker().pickImage(source: source);
      original = picked == null ? null : await picked.readAsBytes();
    }
    if (original == null || !mounted || generation != store.requestGeneration) {
      return;
    }
    final prepared = store.prepareVisionImage(original);
    if (!prepared.isValid) {
      _showNotice(prepared.errorMessage!);
      return;
    }
    if (!mounted || generation != store.requestGeneration) return;
    final question = await showCopilotVisionPromptSheet(context);
    if (question == null || !mounted || generation != store.requestGeneration) {
      return;
    }
    final ok = await store.submitVisionImage(
      prepared.bytes!,
      question: question,
      expectedGeneration: generation,
    );
    if (ok && mounted) {
      _autoFollowScroll = true;
      _maybeAutoScroll(force: true);
    }
  }

  Future<void> _copyMessage(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showNotice('已复制到剪贴板', duration: const Duration(seconds: 1));
  }

  void _showNotice(
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: duration),
    );
  }

  void _maybeAutoScroll({bool force = false}) {
    if (!force && !_autoFollowScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (!force && !_autoFollowScroll) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final isUserGesture =
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle);
    if (!isUserGesture) return false;
    final extentAfter = notification.metrics.extentAfter;
    if (extentAfter > 64.0) {
      _autoFollowScroll = false;
    } else if (extentAfter <= 24.0) {
      _autoFollowScroll = true;
    }
    return false;
  }

  double _composerBottom(bool keyboardOpen) =>
      keyboardOpen ? DsSpacing.sm : widget.bottomNavClearance + DsSpacing.sm;

  double _scrollBottomPadding(bool keyboardOpen) {
    if (!_textMode) {
      return max(
        88.0,
        widget.bottomNavClearance +
            DsSpacing.md +
            DsSizes.touchTarget +
            DsSpacing.lg,
      );
    }
    return _composerBottom(keyboardOpen) + 124.0 + DsSpacing.md;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final store = widget.store;
    final keyboardOpen = View.of(context).viewInsets.bottom > 0;
    if (_textMode && keyboardOpen && !_hadKeyboardOpenInTextMode) {
      _hadKeyboardOpenInTextMode = true;
    }
    final floatBottom = widget.bottomNavClearance + DsSpacing.md;
    final composerBottom = _composerBottom(keyboardOpen);
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return ColoredBox(
      color: colors.canvas,
      child: SafeArea(
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Column(
              children: <Widget>[
                CopilotHeaderBar(
                  hasMessages: store.messages.isNotEmpty,
                  canClear: !store.sending && !store.clearing,
                  onClearTap: _confirmClear,
                  onLegacyHistoryTap: _showLegacyHistory,
                ),
                if (store.hasIncidentContext)
                  CopilotIncidentContextPill(
                    onTap:
                        widget.onOpenIncidentDetails ??
                        store.gateway.onOpenIncidentDetails,
                  ),
                if (store.recording)
                  CopilotRecordingBanner(
                    isWarning: store.isRecordingWarning,
                    recordingSeconds: store.recordingSeconds,
                    remainingSeconds: store.recordingRemainingSeconds,
                  ),
                Expanded(child: _buildBody(store, keyboardOpen)),
              ],
            ),
            if (!_textMode) ...<Widget>[
              Positioned(
                left: DsSpacing.lg,
                bottom: floatBottom,
                child: CopilotFloatingCircleButton(
                  key: const Key('chat-mode-toggle'),
                  tooltip: '文字输入',
                  onPressed: store.recording || store.processing
                      ? null
                      : () => _toggleInputMode(true),
                  icon: Icon(
                    Icons.keyboard_alt_outlined,
                    size: DsSizes.iconMd + 2,
                    color: store.recording || store.processing
                        ? colors.textTertiary
                        : colors.textPrimary,
                  ),
                ),
              ),
              Positioned(
                right: DsSpacing.lg,
                bottom: floatBottom,
                child: CopilotFloatingCircleButton(
                  key: const Key('chat-vision-button'),
                  tooltip: '拍照分析',
                  onPressed: store.busy || store.recording
                      ? null
                      : _pickVisionImage,
                  icon: store.visionBusy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            value: disableAnimations ? 0.72 : null,
                            strokeWidth: 2,
                            color: colors.brandText,
                          ),
                        )
                      : Icon(
                          Icons.camera_alt_outlined,
                          size: DsSizes.iconMd + 2,
                          color: store.busy || store.recording
                              ? colors.textTertiary
                              : colors.brandText,
                        ),
                ),
              ),
            ] else
              Positioned(
                left: DsSpacing.lg,
                right: DsSpacing.lg,
                bottom: composerBottom,
                child: CopilotTextComposerBar(
                  controller: _inputController,
                  focusNode: _inputFocus,
                  sending: store.sending,
                  clearing: store.clearing,
                  onClose: () => _toggleInputMode(false),
                  onSubmit: _submitTextInput,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(CopilotStore store, bool keyboardOpen) {
    if (store.loading) {
      return const StatePlaceholder.loading(message: '正在加载问答记录…');
    }
    final showTranscript =
        store.recording || (store.processing && store.transcript != null);
    if (store.messages.isEmpty) {
      return Column(
        children: <Widget>[
          if (showTranscript)
            CopilotTranscriptBanner(transcript: store.transcript),
          Expanded(
            child: CopilotWelcomeView(
              onSelectSample: submitQuestion,
              scrollBottomPadding: _scrollBottomPadding(keyboardOpen),
              error: store.error,
            ),
          ),
        ],
      );
    }
    return Column(
      children: <Widget>[
        if (store.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.lg,
              DsSpacing.sm,
              DsSpacing.lg,
              0,
            ),
            child: CopilotErrorBanner(message: store.error!),
          ),
        if (showTranscript)
          CopilotTranscriptBanner(transcript: store.transcript),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _handleScrollNotification,
            child: ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                DsSpacing.lg,
                DsSpacing.md,
                DsSpacing.lg,
                _scrollBottomPadding(keyboardOpen),
              ),
              itemCount: store.messages.length,
              itemBuilder: (BuildContext context, int index) {
                final m = store.messages[index];
                if (m.role == 'assistant' && m.content.isEmpty) {
                  return store.sending
                      ? const CopilotThinkingBubble()
                      : const SizedBox.shrink();
                }
                return CopilotMessageBubble(
                  message: m,
                  isStreaming: m.id == store.activeStreamId,
                  canTapFollowUp: !store.sending && !store.clearing,
                  onFollowUpTap: m.isUser ? null : submitQuestion,
                  onCopy: _copyMessage,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
