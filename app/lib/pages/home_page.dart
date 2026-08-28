import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../pages/same_name_dialog.dart';
import '../services/audio_service.dart';
import '../services/op_log_service.dart';
import '../services/screen_on.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 警情主页面（核心 hub）：语音录入 + 当前警情 + 现场状态。
/// 识别结果按 AI 意图分流：进出场本页确认；日志/提问/环境音交 main 统一路由。
class HomePage extends StatefulWidget {
  final AppController controller;
  final bool autoRecord; // 底部导航语音按钮长按触发
  final VoidCallback? onAutoRecordConsumed;
  final ValueChanged<bool>? onRecordingChanged; // 录音状态上报（底部导航按钮）
  final ValueChanged<bool>? onProcessingChanged; // 识别/确认中状态上报（禁用底部按钮）
  final ValueChanged<String>? onNoteIntent; // 识别为火场日志：记入并跳日志页
  final ValueChanged<String>? onAskIntent; // 识别为提问：跳问答页并发送
  final VoidCallback? onEntryConfirmed; // 进场确认成功后跳转看板
  final AudioService? audioService; // 测试注入

  const HomePage({
    super.key,
    required this.controller,
    this.autoRecord = false,
    this.onAutoRecordConsumed,
    this.onRecordingChanged,
    this.onProcessingChanged,
    this.onNoteIntent,
    this.onAskIntent,
    this.onEntryConfirmed,
    this.audioService,
  });

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  late final AudioService _audio = widget.audioService ?? AudioService();

  bool _recording = false;
  bool _processing = false;
  bool _permDenied = false; // 权限被拒（用于错误视图显示"去系统设置"）
  String? _transcript;
  ParseResult? _parsed;
  String? _error;
  StreamSubscription<double>? _ampSub;
  double _amp = 0.15;
  bool _recordingRequested = false;
  int _recordingGeneration = 0;
  bool _recordingStarting = false;

  // 本次语音操作 ID：贯穿 录音→转写→解析→确认/出场，客户端与服务端日志以此对齐
  String? _opId;

  // 确认编辑用：每次语音识别出的每个人员一组输入
  final List<_PersonEdit> _peopleEditors = [];

  // 语音中说出的气瓶容积（如"钢瓶为9升"）：作为新录入的默认值
  double? _statedVolumeL;

  // 表单内联校验错误（不遮挡确认卡片）
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    if (widget.autoRecord) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.autoRecord) beginRecording();
      });
    }
  }

  /// 姓名/压力变化时刷新卡片内的时长与在场同名提示
  void _onEditsChanged() {
    if (mounted) {
      setState(() => _inlineError = null);
    }
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoRecord && !oldWidget.autoRecord) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.autoRecord) beginRecording();
      });
    }
  }

  @override
  void dispose() {
    _recordingRequested = false;
    _recordingGeneration++;
    _recordingStarting = false;
    _ampSub?.cancel();
    _clearEditors();
    _audio.dispose();
    super.dispose();
  }

  void _clearEditors() {
    for (final ed in _peopleEditors) {
      ed.dispose();
    }
    _peopleEditors.clear();
  }

  /// 先让 TextField 从 widget tree 移除，再释放其 controller。
  /// 直接在 setState 前 dispose 会让 TextField 的动画/手势子树在同一帧
  /// 继续监听已销毁的 controller，触发红屏和级联的 build scope 断言。
  void _disposeEditorsAfterFrame(Iterable<_PersonEdit> editors) {
    final pending = editors.toList();
    if (pending.isEmpty) return;
    if (!mounted) {
      for (final ed in pending) {
        ed.dispose();
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final ed in pending) {
        ed.dispose();
      }
    });
  }

  /// 弹窗关闭后再释放输入控制器，避免 TextField 尚未完成移除就收到 dispose。
  void _disposeControllerAfterFrame(TextEditingController controller) {
    if (!mounted) {
      controller.dispose();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
  }

  /// 开始录音（长按触发）
  Future<void> beginRecording() async {
    widget.onAutoRecordConsumed?.call();
    if (_recording ||
        _processing ||
        _recordingRequested ||
        _recordingStarting) {
      return;
    }
    final generation = ++_recordingGeneration;
    _recordingRequested = true;
    _recordingStarting = true;
    _opId =
        'op-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFF).toRadixString(16)}';
    OpLogService.instance.record(_opId!, 'record_start', '开始录音');
    setState(() {
      _error = null;
      _inlineError = null;
      _transcript = null;
      _parsed = null;
      _permDenied = false;
    });
    // 不清空已录入人员：支持多人分批次语音录入，最后一次性统一确认
    late final bool ok;
    try {
      ok = await _audio.hasPermission();
    } catch (e) {
      _recordingRequested = false;
      _recordingStarting = false;
      if (mounted) setState(() => _error = '麦克风权限检查失败: $e');
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
      OpLogService.instance.record(
        _opId!,
        'record_perm_denied',
        '缺少麦克风权限',
        level: 'warn',
      );
      if (mounted) {
        setState(() {
          _error = '需要麦克风权限';
          _permDenied = true;
        });
      }
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
      setState(() => _recording = true);
      _recordingStarting = false;
      widget.onRecordingChanged?.call(true);
      _ampSub = _audio.amplitudeStream().listen((a) {
        if (mounted) setState(() => _amp = a);
      });
    } catch (e) {
      _recordingStarting = false;
      OpLogService.instance.record(
        _opId!,
        'record_start_err',
        '录音启动失败: $e',
        level: 'error',
      );
      if (mounted) setState(() => _error = '录音启动失败: $e');
      _endOp('record_error');
    }
  }

  /// 结束录音（松手触发）→ 转写 + 解析
  Future<void> finishRecording() async {
    if (!_recording) {
      // 松手可能早于麦克风权限/录音插件返回；撤销尚未真正开始的录音请求，
      // 防止手势结束后异步回调又偷偷启动录音。
      _recordingRequested = false;
      _recordingGeneration++;
      return;
    }
    _recordingRequested = false;
    _recordingGeneration++;
    setState(() {
      _recording = false;
      _processing = true;
      _amp = 0.15;
    });
    widget.onRecordingChanged?.call(false);
    widget.onProcessingChanged?.call(true);
    _ampSub?.cancel();
    final opId = _opId ?? '';
    try {
      final sw = Stopwatch()..start();
      final bytes = await _audio.stop();
      OpLogService.instance.record(
        opId,
        'record_stop',
        '录音结束',
        data: {'bytes': bytes.length, 'ms': sw.elapsedMilliseconds},
      );
      String text;
      try {
        text = await widget.controller.transcribeAudio(bytes, opId: opId);
        OpLogService.instance.record(
          opId,
          'transcribe_ok',
          '转写成功',
          data: {'text': text, 'ms': sw.elapsedMilliseconds},
        );
      } catch (e) {
        OpLogService.instance.record(
          opId,
          'transcribe_err',
          '转写失败: $e',
          level: 'error',
        );
        rethrow;
      }
      if (text.isEmpty) {
        OpLogService.instance.record(
          opId,
          'transcribe_empty',
          '未识别到语音，请再说一次',
          level: 'warn',
        );
        if (mounted) {
          setState(() {
            _processing = false;
            _error = '未识别到语音，请再说一次';
          });
        }
        widget.onProcessingChanged?.call(false);
        _endOp('no_speech');
        return;
      }
      ParseResult parsed;
      try {
        parsed = await widget.controller.parseText(text, opId: opId);
        OpLogService.instance.record(
          opId,
          'parse_ok',
          '语义解析完成',
          data: {
            'text': text,
            'parsed': parsed.toJson(),
            'ms': sw.elapsedMilliseconds,
          },
        );
      } catch (e) {
        OpLogService.instance.record(
          opId,
          'parse_err',
          '解析失败: $e',
          level: 'error',
        );
        rethrow;
      }
      if (!mounted) return;
      // 识别"钢瓶为9升"等容积表达：应用到全部待确认人员，并作为新录入默认值
      final statedVol = _extractVolumeL(text);
      if (statedVol != null) {
        _statedVolumeL = statedVol;
        OpLogService.instance.record(
          opId,
          'volume_detected',
          '识别到气瓶容积',
          data: {'text': text, 'volume_l': statedVol},
        );
        for (final ed in _peopleEditors) {
          ed.volumeCtrl.text = statedVol.toStringAsFixed(1);
        }
      }
      // 意图路由：日志 → 交 main 记入并跳转；提问 → 跳问答页；环境音 → 提示重新录入
      if (parsed.intent == VoiceIntent.note) {
        OpLogService.instance.record(
          opId,
          'note_auto',
          '识别为火场日志，跳转日志页',
          data: {'text': text},
        );
        setState(() {
          _transcript = null;
          _parsed = null;
          _error = null;
          _processing = false;
        });
        widget.onProcessingChanged?.call(false);
        _endOp('note');
        widget.onNoteIntent?.call(text);
        return;
      }
      if (parsed.intent == VoiceIntent.ask) {
        OpLogService.instance.record(
          opId,
          'ask_auto',
          '识别为提问，跳转辅助问答',
          data: {'text': text},
        );
        setState(() {
          _transcript = null;
          _parsed = null;
          _error = null;
          _processing = false;
        });
        widget.onProcessingChanged?.call(false);
        _endOp('ask');
        widget.onAskIntent?.call(text);
        return;
      }
      if (parsed.intent == VoiceIntent.ignore) {
        OpLogService.instance.record(
          opId,
          'ignore_auto',
          '环境音/无关内容，丢弃',
          data: {'text': text},
        );
        setState(() {
          _transcript = null;
          _parsed = null;
          _error = '未识别到有效指令，请重新录入';
          _processing = false;
        });
        widget.onProcessingChanged?.call(false);
        _endOp('ignore');
        return;
      }
      // 出场意图只处理当前在场记录，不应把识别到的姓名追加进待确认的
      // 进场编辑器；否则“张伟退场”可能在处理后又显示为待进场。
      if (parsed.action == 'exit') {
        setState(() {
          _transcript = text;
          _parsed = parsed;
          _processing = false;
        });
        widget.onProcessingChanged?.call(false);
        if (parsed.people.isNotEmpty) {
          await _handleExit(parsed.people.map((p) => p.name).toList());
        } else {
          await _confirmAllExit(text);
        }
        return;
      }
      // 追加到已录入名单：同名人员更新压力（更正），其余新增一行
      for (final p in parsed.people) {
        final idx = _peopleEditors.indexWhere(
          (ed) =>
              (ed.name == p.name && ed.name.isNotEmpty) ||
              ed.sourceName == p.name,
        );
        if (idx >= 0) {
          if (p.pressureMpa != null) {
            _peopleEditors[idx].pressureCtrl.text = p.pressureMpa.toString();
          }
          continue;
        }
        final ed = _PersonEdit(onChanged: _onEditsChanged);
        // 非名单内姓名大概率是口误/识别错误：姓名栏留空，等用户手动补全
        if (_isKnownName(p.name)) {
          ed.nameCtrl.text = p.name;
        } else {
          ed.sourceName = p.name;
        }
        if (p.pressureMpa != null) {
          ed.pressureCtrl.text = p.pressureMpa.toString();
        }
        final defaultVol =
            _statedVolumeL ?? widget.controller.calcConfig.cylinderVolL;
        ed.volumeCtrl.text = defaultVol.toStringAsFixed(1);
        _peopleEditors.add(ed);
      }
      setState(() {
        _transcript = text;
        _parsed = parsed;
        _processing = false;
      });
      widget.onProcessingChanged?.call(false);
      // 进场意图但未识别到任何姓名：不进空确认页，提示重新报读
      if (parsed.action == 'enter' && parsed.people.isEmpty) {
        OpLogService.instance.record(
          opId,
          'entry_empty',
          '进场意图未识别到姓名',
          data: {'text': text},
        );
        setState(() {
          _transcript = null;
          _parsed = null;
          _error = '未识别到进场人员姓名，请重新报：姓名+压力';
          _processing = false;
        });
        widget.onProcessingChanged?.call(false);
        _endOp('entry_empty');
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processing = false;
          _error = '$e';
        });
      }
      widget.onProcessingChanged?.call(false);
      _endOp('error');
    }
  }

  /// 问答页就地录音识别为进出场时：展示本页确认面板（不经语音页再录一次）
  void applyVoiceResult(String text, ParseResult parsed) {
    setState(() {
      _transcript = text;
      _parsed = parsed;
      _error = null;
      _inlineError = null;
    });
  }

  /// 本次操作收尾：记录结束步 + 把待上传日志批量同步到服务器
  void _endOp(
    String outcome, {
    String level = 'info',
    Map<String, dynamic>? data,
  }) {
    final opId = _opId;
    _opId = null;
    if (opId == null) return;
    OpLogService.instance.record(
      opId,
      'op_end',
      '本次操作结束',
      level: level,
      data: {'outcome': outcome, ...?data},
    );
    OpLogService.instance.flush(api: widget.controller.api);
  }

  Future<void> _handleExit(List<String> names) async {
    final notFound = <String>[];
    var exited = 0;
    for (final name in names) {
      final active = widget.controller.entries
          .where((e) => e.isActive && e.name == name)
          .toList();
      if (active.isEmpty) {
        notFound.add(name);
        OpLogService.instance.record(
          _opId ?? '',
          'exit_skip',
          '未找到在场人员「$name」',
          level: 'warn',
        );
        continue;
      }
      for (final e in active) {
        await widget.controller.markExited(
          e.id,
          opId: '${_opId ?? 'exit'}-${e.id}',
        );
        OpLogService.instance.record(
          _opId ?? '',
          'exit_ok',
          '已登记「$name」出火场',
          data: {'entryId': e.id, 'name': name},
        );
      }
      exited++;
    }
    if (!mounted) return;
    final doneNames = names.where((n) => !notFound.contains(n)).toList();
    final done = doneNames.join('、');
    if (exited > 0) {
      await _writeActionLog(
        doneNames,
        action: '出场',
        category: NoteCategory.withdraw,
        opSuffix: 'exit-note',
      );
      widget.controller.tts.speak('$done 已登记出火场');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$done 已登记出火场'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _transcript = null;
      _parsed = null;
      _error = notFound.isEmpty ? null : '未找到在场人员「${notFound.join('、')}」';
      // 保留已录入未确认的人员，出场指令不清空分批名单
    });
    _endOp(exited > 0 ? 'exit_ok' : 'exit_none');
  }

  /// 全员离场确认：识别到"全部人员离开火场"等指令且未提取到具体姓名时，
  /// 弹框让用户确认（展示语音原文以便核对机器理解），确认后把当前所有在场人员统一登记离场
  Future<void> _confirmAllExit(String voiceText) async {
    final active = widget.controller.entries.where((e) => e.isActive).toList();
    if (!mounted) return;
    if (active.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('全员离场'),
          content: const Text('当前没有在场人员，无需全员离场'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      if (mounted) {
        setState(() {
          _transcript = null;
          _parsed = null;
          _error = null;
        });
      }
      _endOp('exit_all_none');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全员离场确认'),
        content: Text(
          '识别到全员离场指令，当前在场 ${active.length} 人：${active.map((e) => e.name).join('、')}\n\n语音原文：「$voiceText」\n\n确认全部登记离场？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认全员离场'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      OpLogService.instance.record(
        _opId ?? '',
        'exit_all_cancelled',
        '用户取消全员离场',
        level: 'info',
      );
      if (mounted) {
        setState(() {
          _transcript = null;
          _parsed = null;
          _error = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已取消全员离场'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      _endOp('exit_all_cancel');
      return;
    }
    var exited = 0;
    for (final e in active) {
      await widget.controller.markExited(
        e.id,
        opId: '${_opId ?? 'exit'}-${e.id}',
      );
      OpLogService.instance.record(
        _opId ?? '',
        'exit_all_ok',
        '全员离场已登记「${e.name}」',
        data: {'entryId': e.id, 'name': e.name},
      );
      exited++;
    }
    if (!mounted) return;
    await _writeActionLog(
      active.map((e) => e.name),
      action: '出场',
      category: NoteCategory.withdraw,
      opSuffix: 'exit-all-note',
    );
    if (!mounted) return;
    widget.controller.tts.speak('全体人员已登记离场');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已全员离场（$exited 人）'),
        duration: const Duration(seconds: 2),
      ),
    );
    setState(() {
      _transcript = null;
      _parsed = null;
      _error = null;
    });
    _endOp('exit_all', data: {'count': exited});
  }

  /// 姓名是否在已知消防员名单内（名单为空时不拦截，避免误清空）
  bool _isKnownName(String name) {
    final roster = widget.controller.firefighters.map((f) => f.name).toSet();
    if (roster.isEmpty) return true;
    return roster.contains(name);
  }

  /// 从语音文本中提取气瓶容积升数（如"9升"/"九升"），未提及返回 null
  double? _extractVolumeL(String text) {
    final m = RegExp(
      r'([0-9]+(?:\.[0-9]+)?|[一二两三四五六七八九十]+)\s*(?:公升|升)',
    ).firstMatch(text);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!) ?? _cnNum(m.group(1)!);
    if (v == null || v <= 0 || v > 20) return null;
    return v;
  }

  double? _cnNum(String s) {
    const digits = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
    };
    if (digits.containsKey(s)) return digits[s]!.toDouble();
    if (s.contains('十')) {
      final parts = s.split('十');
      final tens = parts[0].isEmpty ? 1 : digits[parts[0]];
      final ones = parts[1].isEmpty ? 0 : digits[parts[1]];
      if (tens == null || ones == null) return null;
      return (tens * 10 + ones).toDouble();
    }
    return null;
  }

  /// 重新语音输入：清除本次转写/解析结果与错误状态
  void _retry() {
    final disposedEditors = List<_PersonEdit>.from(_peopleEditors);
    _peopleEditors.clear();
    setState(() {
      _transcript = null;
      _parsed = null;
      _error = null;
      _inlineError = null;
      _processing = false;
      _permDenied = false;
    });
    widget.onProcessingChanged?.call(false);
    _disposeEditorsAfterFrame(disposedEditors);
  }

  /// 从空闲态回到待确认名单（出场/取消录音后仍有已录入人员时）
  void _showPendingConfirm() {
    if (_peopleEditors.isEmpty) return;
    setState(() {
      _transcript = '已录入 ${_peopleEditors.length} 人，待统一确认';
      _parsed = ParseResult(
        action: 'enter',
        people: _peopleEditors
            .map(
              (ed) => ParsePerson(
                name: ed.name.isEmpty ? (ed.sourceName ?? '') : ed.name,
                pressureMpa: ed.pressure,
              ),
            )
            .toList(),
      );
      _error = null;
    });
  }

  /// 校验单个人员：返回错误文案，null 表示通过
  String? _validatePerson(_PersonEdit ed) {
    if (ed.name.isEmpty) return '缺少姓名';
    final p = ed.pressure;
    if (p == null) return '「${ed.name}」缺少气瓶压力';
    if (p <= 0 || p > 40) return '「${ed.name}」压力数值异常';
    final v = ed.volume;
    if (v == null || v <= 0 || v > 20) return '「${ed.name}」气瓶容量数值异常（1~20L）';
    return null;
  }

  /// 一次性确认全部人员进场：先整体校验（错误全部列出），再逐个提交。
  /// 成功者移除，失败/取消者保留在表单中供修正后再次确认。
  Future<void> _confirmAll() async {
    if (_peopleEditors.isEmpty) {
      setState(() => _error = '未识别到人员信息，请重新语音输入');
      return;
    }
    final problems = <String>[];
    for (final (i, ed) in _peopleEditors.indexed) {
      final problem = _validatePerson(ed);
      if (problem != null) problems.add('${i + 1}. $problem');
    }
    if (problems.isNotEmpty) {
      setState(() => _inlineError = problems.join('\n'));
      return;
    }

    setState(() => _processing = true);
    widget.onProcessingChanged?.call(true);
    final results = <({_PersonEdit ed, _SubmitResult result})>[];
    for (final ed in _peopleEditors) {
      final result = await _submitPerson(ed.name, ed.pressure!, ed.volume!);
      if (!mounted) return;
      if (result == _SubmitResult.created || result == _SubmitResult.merged) {
        OpLogService.instance.record(
          _opId ?? '',
          'confirm_enter',
          '已登记「${ed.name}」进场',
          data: {
            'name': ed.name,
            'pressure_mpa': ed.pressure,
            'volume_l': ed.volume,
            'result': result == _SubmitResult.created ? 'created' : 'merged',
          },
        );
      } else if (result == _SubmitResult.error) {
        OpLogService.instance.record(
          _opId ?? '',
          'confirm_err',
          '「${ed.name}」登记进场失败',
          level: 'error',
        );
      }
      results.add((ed: ed, result: result));
      if (result == _SubmitResult.cancelled) break;
    }
    if (!mounted) return;

    final done = <String>[];
    final donePressures = <String, double>{};
    final failed = <String>[];
    final kept = <_PersonEdit>[];
    final disposedEditors = <_PersonEdit>[];
    for (final r in results) {
      final ok =
          r.result == _SubmitResult.created || r.result == _SubmitResult.merged;
      if (ok) {
        done.add(r.ed.name);
        donePressures[r.ed.name] = r.ed.pressure!;
        disposedEditors.add(r.ed);
      } else {
        failed.add(r.ed.name);
        kept.add(r.ed);
      }
    }
    // 取消中断后未提交的剩余行一并保留
    for (var i = results.length; i < _peopleEditors.length; i++) {
      kept.add(_peopleEditors[i]);
    }
    if (done.isNotEmpty) {
      widget.controller.tts.speak('${done.join('、')}，已开始倒计时');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${done.join('、')} 已入火场，开始倒计时'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    final allDone = failed.isEmpty && kept.isEmpty;
    if (mounted) {
      setState(() {
        _peopleEditors
          ..clear()
          ..addAll(kept);
        if (allDone) {
          _transcript = null;
          _parsed = null;
        }
        _inlineError = null;
        _processing = false;
      });
    }
    _disposeEditorsAfterFrame(disposedEditors);
    widget.onProcessingChanged?.call(false);
    if (!allDone && failed.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('未登记：${failed.join('、')}，请修正后再次确认'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    if (allDone) {
      // 进场登记已经成功，先让主界面进入看板；日志同步属于后置记录，
      // 不应因为网络耗时阻塞用户查看刚刚登记的人员。
      widget.onEntryConfirmed?.call();
      await _writeActionLog(
        done,
        action: '进场',
        pressuresMpa: donePressures,
        category: NoteCategory.deploy,
        opSuffix: 'entry-note',
      );
      _endOp('enter_ok', data: {'names': done});
    }
  }

  /// 进出场成功后同步写入火场日志；登记已经成功时，日志失败不能回滚进出场结果。
  Future<void> _writeActionLog(
    Iterable<String> names, {
    required String action,
    Map<String, double>? pressuresMpa,
    required String category,
    required String opSuffix,
  }) async {
    final opId = _opId;
    final cleanNames = names.toList();
    try {
      await widget.controller.addActionLog(
        names: cleanNames,
        action: action,
        pressuresMpa: pressuresMpa,
        category: category,
        opId: '${opId ?? 'action'}-$opSuffix',
      );
      OpLogService.instance.record(
        opId ?? '',
        'action_note_created',
        '同步生成火场日志',
        data: {'action': action, 'names': cleanNames},
      );
    } catch (e) {
      OpLogService.instance.record(
        opId ?? '',
        'action_note_failed',
        '同步生成火场日志失败：$e',
        level: 'error',
        data: {'action': action, 'names': cleanNames},
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('进出场已登记，但火场日志写入失败：$e')));
      }
    }
  }

  /// 提交单个人：本地预检同名 → 弹窗合并/另建；服务端 409 时兜底再弹一次
  Future<_SubmitResult> _submitPerson(
    String name,
    double p,
    double volumeL,
  ) async {
    final existing = widget.controller.entries
        .where((e) => e.isActive && e.name == name)
        .toList();
    if (existing.isNotEmpty) {
      final choice = await _askSameName(existing.first, p);
      if (choice == null) return _SubmitResult.cancelled;
      if (choice == SameNameChoice.merge) {
        return await _tryMerge(existing.first, p);
      }
      return await _tryCreate(name, p, force: true, volumeL: volumeL);
    }
    return await _tryCreate(name, p, volumeL: volumeL);
  }

  Future<SameNameChoice?> _askSameName(Entry existing, double p) {
    return showSameNameDialog(
      context,
      existing: existing,
      pressureMpa: p,
      durationMin: widget.controller.calcConfig.durationMinFor(p).round(),
    );
  }

  /// 移除误识别/多余的人员（释放输入控制器）
  void _removeEditorAt(int index) {
    final ed = _peopleEditors.removeAt(index);
    if (_peopleEditors.isEmpty) {
      setState(() {
        _transcript = null;
        _parsed = null;
        _error = null;
        _inlineError = null;
        _processing = false;
      });
      widget.onProcessingChanged?.call(false);
    } else if (mounted) {
      setState(() {});
    }
    _disposeEditorsAfterFrame([ed]);
  }

  Future<_SubmitResult> _tryMerge(Entry existing, double p) async {
    try {
      await widget.controller.mergeEntryPressure(
        id: existing.id,
        pressureMpa: p,
        opId: _opId,
      );
      return _SubmitResult.merged;
    } catch (e) {
      OpLogService.instance.record(
        _opId ?? '',
        'merge_err',
        '合并压力失败: $e',
        level: 'error',
      );
      if (mounted) setState(() => _error = '$e');
      return _SubmitResult.error;
    }
  }

  Future<_SubmitResult> _tryCreate(
    String name,
    double p, {
    bool force = false,
    double? volumeL,
  }) async {
    try {
      await widget.controller.createEntryFromVoice(
        name: name,
        pressureMpa: p,
        rawText: _transcript,
        force: force,
        volumeL: volumeL,
        // X-Op-Id 是 HTTP 头，只能使用 ASCII。姓名仍要参与每个人员请求的
        // 唯一标识，因此将姓名按 URL-safe Base64 编码后再拼接。
        opId:
            '${_opId ?? 'entry'}-${base64Url.encode(utf8.encode(name)).replaceAll('=', '')}',
      );
      return _SubmitResult.created;
    } on EntryConflictException catch (e) {
      // 服务端兜底：本地预检未捕获的冲突（如多设备并发登记）
      if (!mounted) return _SubmitResult.error;
      final choice = await _askSameName(e.existing, p);
      if (choice == null) return _SubmitResult.cancelled;
      if (choice == SameNameChoice.merge) {
        return await _tryMerge(e.existing, p);
      }
      return await _tryCreate(name, p, force: true, volumeL: volumeL);
    } catch (e) {
      OpLogService.instance.record(
        _opId ?? '',
        'create_err',
        '登记进场失败: $e',
        level: 'error',
      );
      if (mounted) setState(() => _error = '$e');
      return _SubmitResult.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.controller.calcConfig;
    final incident = widget.controller.currentIncident;
    // 录入确认时把警情卡收起，确认区只保留人员和压力信息，避免重复占用屏幕。
    final compactEntryFlow =
        _recording ||
        _processing ||
        _peopleEditors.isNotEmpty ||
        (_transcript != null && _parsed != null);
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, viewport) {
          final compactHeader =
              viewport.maxWidth < 400 ||
              MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
          final connectionStatus = ConnectionStatus(
            connected: !widget.controller.connectionLost,
            syncing: widget.controller.syncing,
            syncError: widget.controller.syncError,
            onRetry: widget.controller.refreshNow,
          );
          final pageHeader = compactHeader
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('警情处置', style: AppTextStyles.h1),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: connectionStatus,
                    ),
                  ],
                )
              : Row(
                  children: [
                    const Text('警情处置', style: AppTextStyles.h1),
                    const Spacer(),
                    connectionStatus,
                  ],
                );
          final taskBar = incident == null || compactEntryFlow
              ? null
              : _TaskBar(
                  incident: incident,
                  forces: widget.controller.forces,
                  onRename: _renameIncident,
                  onAddForce: () => _editForce(),
                  onEditForce: (force) => _editForce(force),
                  onRemoveForce: (force) => _removeForce(force),
                  onArchive: _confirmArchive,
                  onExit: _confirmExitIncident,
                );

          // 横屏可用高度通常不足以同时放下警情卡、结果区和底部导航。
          // 改为整页滚动，并给内部 Expanded 组件明确高度，避免 Column 溢出。
          if (viewport.maxHeight < 520) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  pageHeader,
                  const SizedBox(height: 8),
                  if (incident == null)
                    SizedBox(
                      height: max(320.0, viewport.maxHeight - 72),
                      child: _IncidentPicker(
                        activeIncidents: widget.controller.activeIncidents,
                        onSelect: _selectIncident,
                        onCreate: _createIncident,
                      ),
                    )
                  else ...[
                    if (taskBar != null) taskBar,
                    if (taskBar != null) const SizedBox(height: 8),
                    SizedBox(
                      height: max(260.0, viewport.maxHeight - 96),
                      child: _buildResultCard(context, cfg),
                    ),
                  ],
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              children: [
                pageHeader,
                const SizedBox(height: 8),
                if (incident == null)
                  Expanded(
                    flex: 4,
                    child: _IncidentPicker(
                      activeIncidents: widget.controller.activeIncidents,
                      onSelect: _selectIncident,
                      onCreate: _createIncident,
                    ),
                  )
                else if (taskBar != null)
                  taskBar,
                const SizedBox(height: 8),
                Expanded(
                  child: incident == null
                      ? const SizedBox.shrink()
                      : _buildResultCard(context, cfg),
                ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _selectIncident(Incident incident) async {
    try {
      await widget.controller.selectIncident(
        incident.id,
        knownIncident: incident,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加入警情失败：$e')));
      }
    }
  }

  /// 启动警情选择浮层复用首页已有的加入流程，保持错误提示和后台同步行为一致。
  Future<void> selectIncidentFromGate(Incident incident) =>
      _selectIncident(incident);

  Future<void> _createIncident() async {
    try {
      final incident = await widget.controller.createIncident();
      if (mounted) await _renameIncident(incident: incident, prompt: true);
    } on IncidentCreateConflictException catch (e) {
      if (!mounted) return;
      final join = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已有刚创建的警情'),
          content: Text('${e.existing.displayName}\n\n${e.message}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('暂不加入'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('加入现有警情'),
            ),
          ],
        ),
      );
      if (join != true) return;
      try {
        await widget.controller.selectIncident(
          e.existing.id,
          knownIncident: e.existing,
        );
      } catch (joinError) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('加入警情失败：$joinError')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 启动警情选择浮层复用首页已有的新建流程。
  Future<void> createIncidentFromGate() => _createIncident();

  Future<void> _renameIncident({
    Incident? incident,
    bool prompt = false,
  }) async {
    final target = incident ?? widget.controller.currentIncident;
    if (target == null) return;
    final edit = TextEditingController(text: target.title ?? '');
    final title = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(prompt ? '补充警情名称' : '修改警情名称'),
        content: TextField(
          controller: edit,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: '如：幸福小区住宅火灾'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, edit.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    _disposeControllerAfterFrame(edit);
    if (title == null) return;
    try {
      await widget.controller.renameCurrent(title);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('修改名称失败：$e')));
      }
    }
  }

  Future<void> _confirmArchive() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('归档警情'),
        content: const Text('归档后现场数据只读，名称仍可在归档警情列表中修改。请确认处置已经结束。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.alarm),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认归档'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.controller.archiveCurrent();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('归档失败：$e')));
      }
    }
  }

  Future<void> _confirmExitIncident() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出当前警情'),
        content: const Text('退出后不会归档警情，仍可从正在处置的警情列表重新加入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.controller.exitCurrentIncident();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('退出警情失败：$e')));
      }
    }
  }

  Future<void> _removeForce(IncidentForce force) async {
    try {
      await widget.controller.removeForce(force.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除参战力量失败：$e')));
      }
    }
  }

  Future<void> _editForce([IncidentForce? force]) async {
    final api = widget.controller.api;
    List<Station> stations = const [];
    if (api != null) {
      try {
        stations = await api.fetchStations();
      } catch (_) {
        // 名录加载失败时仍允许现场手动填写站名。
      }
    }
    final names = <String>{...stations.map((s) => s.name)};
    if (force != null) names.add(force.stationName);
    if (!mounted) return;
    var selected = force?.stationName ?? (names.isEmpty ? '' : names.first);
    var custom = names.isEmpty || !names.contains(selected);
    final customStation = TextEditingController(
      text: custom ? force?.stationName ?? '' : '',
    );
    final vehicles = TextEditingController(text: '${force?.vehicleCount ?? 1}');
    final people = TextEditingController(text: '${force?.personnelCount ?? 1}');
    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(force == null ? '添加参战力量' : '编辑参战力量'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!custom && names.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '消防站名称'),
                  items: names
                      .map(
                        (name) =>
                            DropdownMenuItem(value: name, child: Text(name)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => selected = value ?? selected),
                )
              else
                TextField(
                  controller: customStation,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '消防站名称',
                    hintText: '如：龙翔路站',
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: names.isEmpty
                      ? null
                      : () => setDialogState(() => custom = !custom),
                  icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
                  label: Text(custom ? '返回名录选择' : '现场新增消防站'),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: vehicles,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '车辆数'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: people,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '人员数'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                'station': custom ? customStation.text.trim() : selected,
                'vehicles': vehicles.text,
                'people': people.text,
              }),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    _disposeControllerAfterFrame(customStation);
    _disposeControllerAfterFrame(vehicles);
    _disposeControllerAfterFrame(people);
    if (result == null) return;
    final stationName = result['station']?.toString().trim() ?? '';
    final vehicleCount =
        int.tryParse(result['vehicles']?.toString() ?? '') ?? 0;
    final personnelCount =
        int.tryParse(result['people']?.toString() ?? '') ?? 0;
    try {
      await widget.controller.saveForce(
        forceId: force?.id,
        stationName: stationName,
        vehicleCount: vehicleCount,
        personnelCount: personnelCount,
        expectedVersion: force?.version,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存参战力量失败：$e')));
      }
    }
  }

  Widget _buildResultCard(BuildContext context, CalcConfig cfg) {
    if (_recording) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _PulseMic(intensity: _amp),
            const SizedBox(height: 24),
            const Text(
              '请清晰说出：姓名 + 气瓶压力',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '或：出火场人员姓名',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 14),
            ),
            if (_peopleEditors.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '已录入 ${_peopleEditors.length} 人，本次语音将追加到名单',
                style: const TextStyle(
                  color: AppColors.voice,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      );
    }
    if (_processing) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 18),
            const Text(
              '语音转文字中…',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.caution.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: AppColors.caution.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: AppColors.caution,
                size: 36,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              if (_permDenied) ...[
                FilledButton.icon(
                  onPressed: () => ScreenOn.openAppSettings(),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('去系统设置'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.replay),
                label: const Text('重新语音输入'),
              ),
              if (_peopleEditors.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _showPendingConfirm,
                  child: const Text('返回确认'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_transcript == null || _parsed == null) {
      // 引导区：统一卡片 + 图标网格，内容不足时居中，窄屏可滚动不溢出
      return LayoutBuilder(
        builder: (ctx, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Center(
              child: AppCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.voice,
                          ),
                          child: const Icon(
                            Icons.mic_rounded,
                            size: 17,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '按住下方按钮说话',
                            softWrap: true,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (ctx, c) {
                        final itemW = (c.maxWidth - 10) / 2;
                        // 三行等高：文字行数不同也保持六块整齐一致
                        return IntrinsicHeight(
                          child: Column(
                            children: [
                              Expanded(
                                child: _guideRow(
                                  itemW,
                                  _guideItem(
                                    Icons.login_rounded,
                                    '进场登记',
                                    '「张伟，20兆帕」\n自动开始倒计时',
                                  ),
                                  _guideItem(
                                    Icons.groups_rounded,
                                    '多人进场',
                                    '「张伟20兆帕，刘洋22兆帕」\n一次确认全部进场',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                child: _guideRow(
                                  itemW,
                                  _guideItem(
                                    Icons.logout_rounded,
                                    '出场登记',
                                    '「刘洋出来了」\n登记出火场',
                                  ),
                                  _guideItem(
                                    Icons.update_rounded,
                                    '压力复核',
                                    '「张伟，15兆帕」\n场中报数，更新倒计时',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                child: _guideRow(
                                  itemW,
                                  _guideItem(
                                    Icons.edit_note_rounded,
                                    '火场随手记',
                                    '「三楼破拆完成」\n自动记入火场日志',
                                  ),
                                  _guideItem(
                                    Icons.assistant_rounded,
                                    '火场提问',
                                    '「浓烟太大看不清路怎么办？」\n转给辅助智囊',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    if (_peopleEditors.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _showPendingConfirm,
                        icon: const Icon(Icons.fact_check_outlined),
                        label: Text('继续确认已录入的 ${_peopleEditors.length} 人'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.graphic_eq, size: 16, color: AppColors.voice),
                    const SizedBox(width: 6),
                    const Text(
                      '转写结果',
                      style: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 12,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _transcript!,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.4,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_parsed!.action == 'exit')
            AppCard(
              padding: const EdgeInsets.all(16),
              color: AppColors.safe.withValues(alpha: 0.10),
              side: const BorderSide(color: AppColors.safe, width: 1),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.logout, color: AppColors.safe),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _parsed!.people.isEmpty
                              ? '识别为全员离场指令，正在等待确认'
                              : '识别为出火场指令：${_parsed!.people.map((p) => p.name).join('、')}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.replay),
                      label: const Text('重新语音输入'),
                    ),
                  ),
                ],
              ),
            )
          else if (_peopleEditors.isEmpty)
            AppCard(
              child: Column(
                children: [
                  const Text(
                    '未识别到人员信息，请重新语音输入',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.replay),
                    label: const Text('重新语音输入'),
                  ),
                ],
              ),
            )
          else if (_peopleEditors.length > 1)
            _buildMultiCard(context, cfg)
          else
            AppCard(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _personEditorRow(0, _peopleEditors[0]),
                  const SizedBox(height: 8),
                  _personHints(_peopleEditors[0], cfg),
                  if (_inlineError != null) ...[
                    const SizedBox(height: 8),
                    _inlineErrorBox(_inlineError!),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _confirmAll,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text(
                        '确认进入火场，开始倒计时',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _processing ? null : beginRecording,
                      icon: const Icon(Icons.mic_none),
                      label: const Text('继续语音添加'),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: TextButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.replay),
                      label: const Text('重新语音输入'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 多人一次性确认卡片：全部人员平铺列出（可下滑核对），一个按钮全部提交
  Widget _buildMultiCard(BuildContext context, CalcConfig cfg) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.fact_check_outlined,
                size: 16,
                color: AppColors.voice,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '确认名单（${_peopleEditors.length} 人）：请下滑核对后一次性确认',
                  softWrap: true,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final (i, ed) in _peopleEditors.indexed) ...[
            _personEditorRow(i, ed),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _processing ? null : () => _removeEditorAt(i),
                icon: const Icon(Icons.person_remove_outlined, size: 16),
                label: const Text('移除该人员'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 48),
                ),
              ),
            ),
            const SizedBox(height: 4),
            _personHints(ed, cfg),
            if (i < _peopleEditors.length - 1) const Divider(height: 24),
          ],
          if (_inlineError != null) ...[
            const SizedBox(height: 8),
            _inlineErrorBox(_inlineError!),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: _processing ? null : _confirmAll,
              icon: const Icon(Icons.check_circle_outline),
              label: Text(
                '全部确认进入火场（${_peopleEditors.length} 人）',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _processing ? null : beginRecording,
              icon: const Icon(Icons.mic_none),
              label: const Text('继续语音添加'),
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: TextButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.replay),
              label: const Text('重新语音输入'),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个人员的姓名/压力编辑行（列表与逐人确认共用）
  Widget _personEditorRow(int index, _PersonEdit ed) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
        final nameField = TextField(
          controller: ed.nameCtrl,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '姓名',
            prefixIcon: Icon(Icons.person_outline, size: 20),
          ),
          style: const TextStyle(fontSize: 16),
        );
        final pressureField = TextField(
          controller: ed.pressureCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            isDense: true,
            labelText: '压力',
            suffixText: 'MPa',
          ),
          style: const TextStyle(fontSize: 16),
        );

        if (compact) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IndexBadge(index: index),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    nameField,
                    const SizedBox(height: 8),
                    pressureField,
                  ],
                ),
              ),
            ],
          );
        }

        return Row(
          children: [
            _IndexBadge(index: index),
            const SizedBox(width: 8),
            Expanded(child: nameField),
            const SizedBox(width: 8),
            SizedBox(width: 104, child: pressureField),
          ],
        );
      },
    );
  }

  /// 内联校验错误提示（不遮挡确认卡片）
  Widget _inlineErrorBox(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.alarm.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.alarm.withValues(alpha: 0.4)),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 13,
          color: AppColors.alarm,
          fontWeight: FontWeight.w700,
          height: 1.5,
        ),
      ),
    );
  }

  /// 单行人员的提示：在场同名警告 + 可用时间（容量可改，实时重算）
  Widget _personHints(_PersonEdit ed, CalcConfig cfg) {
    final name = ed.name;
    final p = ed.pressure;
    final v = ed.volume ?? cfg.cylinderVolL;
    final dup = name.isNotEmpty
        ? widget.controller.entries
              .where((e) => e.isActive && e.name == name)
              .toList()
        : <Entry>[];
    final boxStyle = BoxDecoration(
      color: AppColors.caution.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      border: Border.all(color: AppColors.caution.withValues(alpha: 0.4)),
    );
    final style = const TextStyle(
      fontSize: 13,
      color: AppColors.textSecondary,
      fontWeight: FontWeight.w600,
      height: 1.4,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (name.isEmpty && ed.sourceName != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: boxStyle,
            child: Text(
              '「${ed.sourceName}」不在名单内，已清空姓名栏，请手动补全正确姓名',
              style: style,
            ),
          ),
        if (dup.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: boxStyle,
            child: Text(
              '「${dup.first.name}」已在火场内，确认时将弹窗选择：重新倒计时 / 另建记录',
              style: style,
            ),
          ),
        if (p != null && p > 0 && p <= 40)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: boxStyle,
            child: Row(
              children: [
                const Icon(
                  Icons.gas_meter_outlined,
                  size: 16,
                  color: AppColors.textTertiary,
                ),
                const SizedBox(width: 6),
                const Text(
                  '容量',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textTertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 62,
                  height: 34,
                  child: TextField(
                    controller: ed.volumeCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  'L',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textTertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '可用时间 ${cfg.durationMinFor(p, cylinderVolL: v).round()} 分钟',
                    style: style,
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: boxStyle,
            child: const Text(
              '未识别到气瓶压力，请手动填写（如 20）',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  /// 引导网格行：两个等宽卡片，行内等高（较矮的卡片底部留白对齐）
  Widget _guideRow(double itemW, Widget first, Widget second) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: itemW, child: first),
        const SizedBox(width: 10),
        SizedBox(width: itemW, child: second),
      ],
    );
  }

  /// 引导网格项：图标 + 意图标签 + 语音示例（两行，覆盖全部语音意图）
  Widget _guideItem(IconData icon, String label, String example) {
    return Container(
      key: ValueKey('guide-$label'),
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: AppColors.voice),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  softWrap: true,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            example,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单人提交结果
enum _SubmitResult { created, merged, cancelled, error }

/// 单个人员的姓名/压力/容量编辑组（随输入实时刷新提示）
class _PersonEdit {
  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController pressureCtrl = TextEditingController();
  final TextEditingController volumeCtrl = TextEditingController();
  final VoidCallback onChanged;

  /// 语音识别出的原始姓名：不在名单内时姓名栏被清空，保留原值用于提示
  String? sourceName;
  bool _disposed = false;

  _PersonEdit({required this.onChanged}) {
    nameCtrl.addListener(onChanged);
    pressureCtrl.addListener(onChanged);
    volumeCtrl.addListener(onChanged);
  }

  String get name => nameCtrl.text.trim();

  double? get pressure => double.tryParse(pressureCtrl.text.trim());

  double? get volume => double.tryParse(volumeCtrl.text.trim());

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    nameCtrl.removeListener(onChanged);
    pressureCtrl.removeListener(onChanged);
    volumeCtrl.removeListener(onChanged);
    nameCtrl.dispose();
    pressureCtrl.dispose();
    volumeCtrl.dispose();
  }
}

/// 人员序号徽标
class _IndexBadge extends StatelessWidget {
  final int index;

  const _IndexBadge({required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.voice,
      ),
      child: Text(
        '${index + 1}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 录音时随振幅轻微呼吸的核心圆。
/// 视觉始终限制在固定容器内，不使用大范围向外扩散的声波。
class _PulseMic extends StatelessWidget {
  final double intensity;

  const _PulseMic({required this.intensity});

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    return SizedBox(
      width: 112,
      height: 112,
      child: AnimatedScale(
        scale: disableAnimations ? 1 : 0.96 + intensity.clamp(0, 1) * 0.04,
        duration: disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.voice.withValues(alpha: 0.1),
            border: Border.all(
              color: AppColors.voice.withValues(alpha: 0.58),
              width: 2,
            ),
          ),
          child: const Icon(
            Icons.mic_rounded,
            size: 46,
            color: AppColors.voice,
          ),
        ),
      ),
    );
  }
}

class _IncidentPicker extends StatelessWidget {
  final List<Incident> activeIncidents;
  final ValueChanged<Incident> onSelect;
  final VoidCallback onCreate;
  const _IncidentPicker({
    required this.activeIncidents,
    required this.onSelect,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = activeIncidents.isEmpty;
    return Padding(
      key: const Key('incident-picker'),
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              SizedBox(
                width: 4,
                height: 22,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.voice,
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                  ),
                ),
              ),
              SizedBox(width: 10),
              Text(
                '选择正在处置的警情',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '加入后，现场记录都会归入这份档案。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.folder_copy_outlined,
                          size: 88,
                          color: AppColors.textTertiary,
                        ),
                        SizedBox(height: 18),
                        Text(
                          '当前没有进行中的警情',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '如果你是第一位到达的用户，可以新建警情',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: activeIncidents.length,
                    separatorBuilder: (_, __) => const Divider(
                      height: 1,
                      indent: 12,
                      endIndent: 12,
                      color: AppColors.border,
                    ),
                    itemBuilder: (context, index) {
                      final incident = activeIncidents[index];
                      final hasManualTitle = (incident.title ?? '')
                          .trim()
                          .isNotEmpty;
                      return Material(
                        color: AppColors.surface,
                        child: InkWell(
                          onTap: () => onSelect(incident),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        height: 25,
                                        width: double.infinity,
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            incident.displayName,
                                            maxLines: 1,
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        hasManualTitle
                                            ? '${incident.number} · 处置中'
                                            : '处置中',
                                        style: const TextStyle(
                                          color: AppColors.voice,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => onSelect(incident),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.voice,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    minimumSize: const Size(64, 48),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '加入',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      SizedBox(width: 2),
                                      Icon(Icons.chevron_right, size: 20),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          if (isEmpty)
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('新建警情'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.voice,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('新建警情'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.voice,
                side: const BorderSide(color: AppColors.voice),
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          const SizedBox(height: 5),
          Center(
            child: Text(
              isEmpty ? '系统将自动生成临时名称' : '新建后可补充中文名称',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskBar extends StatelessWidget {
  final Incident incident;
  final List<IncidentForce> forces;
  final VoidCallback onRename;
  final VoidCallback onAddForce;
  final ValueChanged<IncidentForce> onEditForce;
  final ValueChanged<IncidentForce> onRemoveForce;
  final VoidCallback onArchive;
  final VoidCallback onExit;

  const _TaskBar({
    required this.incident,
    required this.forces,
    required this.onRename,
    required this.onAddForce,
    required this.onEditForce,
    required this.onRemoveForce,
    required this.onArchive,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('incident-card'),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: AppColors.border),
      boxShadow: AppShadow.card,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                incident.displayName,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: const Key('rename-incident'),
              onPressed: onRename,
              icon: const Icon(Icons.edit_outlined, size: 16),
              tooltip: '修改名称',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ],
        ),
        Row(
          children: [
            const Icon(
              Icons.schedule_outlined,
              size: 14,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                incident.number,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text(
                '参战力量',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              onPressed: onAddForce,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('添加'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ),
        if (forces.isEmpty)
          const Text(
            '尚未登记参战力量',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < forces.length; i++) ...[
                _ForceRow(
                  force: forces[i],
                  onEdit: () => onEditForce(forces[i]),
                  onRemove: () => onRemoveForce(forces[i]),
                ),
                if (i < forces.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: onExit,
                icon: const Icon(Icons.logout_outlined, size: 18),
                label: const Text('退出当前警情'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: onArchive,
                icon: const Icon(Icons.archive_outlined, size: 18),
                label: const Text('归档警情'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.alarm,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ForceRow extends StatelessWidget {
  final IncidentForce force;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _ForceRow({
    required this.force,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final label =
        '${force.stationName} ${force.vehicleCount}车${force.personnelCount}人';
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      side: const BorderSide(color: AppColors.border),
    );

    return Material(
      color: AppColors.surfaceSubtle.withValues(alpha: .42),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        excludeFromSemantics: true,
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColors.surfaceSubtle,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.local_shipping_outlined,
                  size: 19,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: onEdit,
                tooltip: '编辑参战力量',
                icon: const Icon(Icons.edit_outlined, size: 19),
                color: AppColors.textTertiary,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
              IconButton(
                onPressed: onRemove,
                tooltip: '删除参战力量',
                icon: const Icon(Icons.close, size: 21),
                color: AppColors.textTertiary,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
