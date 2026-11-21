import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 从原始流式缓冲提取当前可见正文的解析回调。
typedef CopilotVisibleBodyParser =
    String Function(String raw, {required bool streaming});

String _identityBodyParser(String raw, {required bool streaming}) => raw;

/// 52ms/字（≈ 19.2 字/秒）字素簇（[Characters]）匀速流式揭示器。
///
/// 保持火场阅读节奏：
/// - 首字零额外延迟：首个有效字符到达立即上屏替换思考态；
/// - 突发分片按 [charInterval] 由 [Ticker] 平滑释放，不瞬间刷屏；
/// - 网络流完结后继续补完剩余已缓冲字数，再触发终态渲染与追问按钮展示；
/// - `charInterval <= Duration.zero` 时切入立即模式（供单元测试快速断言）。
class CopilotStreamRevealer {
  CopilotStreamRevealer({
    required TickerProvider vsync,
    required this.onReveal,
    required this.onComplete,
    CopilotVisibleBodyParser? parseVisibleBody,
    this.charInterval = const Duration(milliseconds: 52),
  }) : _vsync = vsync,
       _parseVisibleBody = parseVisibleBody ?? _identityBodyParser;

  final TickerProvider _vsync;
  final void Function(String streamId, String visibleText) onReveal;
  final void Function(String streamId, String fullReply) onComplete;
  final CopilotVisibleBodyParser _parseVisibleBody;
  Duration charInterval;

  String? _activeStreamId;
  String _rawBuffer = '';
  String? _finalFullReply;
  bool _networkStreamDone = false;
  bool _hadStreamChunks = false;
  int _revealedCharCount = 0;
  int _baseRevealedCount = 0;
  Ticker? _ticker;
  bool _disposed = false;

  String? get activeStreamId => _activeStreamId;
  int get revealedCharCount => _revealedCharCount;
  bool get isActive => _activeStreamId != null;

  /// 开始追踪一条新的流式回复。
  void begin(String streamId) {
    if (_disposed) return;
    stop();
    _activeStreamId = streamId;
  }

  /// 追加网络分片，并在需要时启动逐字揭示节拍。
  void pushChunk(String streamId, String delta) {
    if (_disposed || _activeStreamId != streamId || delta.isEmpty) return;
    _hadStreamChunks = true;
    _rawBuffer += delta;
    final visibleBody = _parseVisibleBody(_rawBuffer, streaming: true);
    if (charInterval <= Duration.zero) {
      _revealedCharCount = visibleBody.characters.length;
      onReveal(streamId, visibleBody);
      return;
    }
    final visibleChars = visibleBody.characters;
    if (visibleChars.isEmpty) return;
    if (_revealedCharCount == 0) {
      // 首字零额外延迟：首个有效字符到达立即上屏替换思考态。
      _revealedCharCount = 1;
      onReveal(streamId, visibleChars.take(1).toString());
    }
    if (_revealedCharCount < visibleChars.length &&
        !(_ticker?.isActive ?? false)) {
      _startTicker();
    }
  }

  /// 通知网络流已结束，按需匀速补完尾部字数后回调 [onComplete]。
  void finishNetwork(String streamId, String fullReply) {
    if (_disposed || _activeStreamId != streamId) return;
    final finalBody = _parseVisibleBody(fullReply, streaming: false);
    final totalBodyChars = finalBody.characters.length;
    if (!_hadStreamChunks ||
        charInterval <= Duration.zero ||
        _revealedCharCount >= totalBodyChars) {
      _finalize(streamId, fullReply);
      return;
    }
    _finalFullReply = fullReply;
    _networkStreamDone = true;
    if (_revealedCharCount == 0 && totalBodyChars > 0) {
      _revealedCharCount = 1;
      onReveal(streamId, finalBody.characters.take(1).toString());
    }
    if (_revealedCharCount >= totalBodyChars) {
      _finalize(streamId, fullReply);
    } else if (!(_ticker?.isActive ?? false)) {
      _startTicker();
    }
  }

  /// 停止揭示并按需清空内部缓冲状态。
  void stop({bool clearState = true}) {
    _ticker?.stop();
    if (clearState) {
      _activeStreamId = null;
      _rawBuffer = '';
      _finalFullReply = null;
      _networkStreamDone = false;
      _hadStreamChunks = false;
      _revealedCharCount = 0;
      _baseRevealedCount = 0;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _ticker?.dispose();
    _ticker = null;
  }

  void _startTicker() {
    _ticker ??= _vsync.createTicker(_onTick);
    if (_ticker!.isActive) return;
    _baseRevealedCount = _revealedCharCount;
    _ticker!.start();
  }

  void _finalize(String streamId, String reply) {
    stop();
    onComplete(streamId, reply);
  }

  void _onTick(Duration elapsed) {
    final streamId = _activeStreamId;
    if (_disposed || streamId == null) {
      _ticker?.stop();
      return;
    }
    final intervalUs = charInterval.inMicroseconds;
    final targetSource = _networkStreamDone
        ? (_finalFullReply ?? _rawBuffer)
        : _rawBuffer;
    final visibleBody = _parseVisibleBody(
      targetSource,
      streaming: !_networkStreamDone,
    );
    final bodyChars = visibleBody.characters;
    final total = bodyChars.length;
    if (intervalUs <= 0) {
      _revealedCharCount = total;
      onReveal(streamId, visibleBody);
    } else {
      final step = elapsed.inMicroseconds ~/ intervalUs;
      final desired = min(total, _baseRevealedCount + step);
      if (desired > _revealedCharCount) {
        _revealedCharCount = desired;
        onReveal(streamId, bodyChars.take(_revealedCharCount).toString());
      }
    }
    if (_revealedCharCount >= total) {
      _ticker?.stop();
      if (_networkStreamDone) {
        _finalize(streamId, _finalFullReply ?? _rawBuffer);
      }
    }
  }
}
