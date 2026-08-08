import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../pages/same_name_dialog.dart';
import '../services/audio_service.dart';
import '../services/op_log_service.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 任务主页面（核心 hub）：语音录入 + 任务身份（任务码）+ 任务状态 + 任务管理（结束任务）。
/// 识别结果按 AI 意图分流：进出场本页确认；日志/提问/环境音交 main 统一路由。
class HomePage extends StatefulWidget {
  final AppController controller;
  final bool autoRecord; // 底部导航语音按钮长按触发
  final VoidCallback? onAutoRecordConsumed;
  final ValueChanged<bool>? onRecordingChanged; // 录音状态上报（底部导航按钮）
  final ValueChanged<bool>? onProcessingChanged; // 识别/确认中状态上报（禁用底部按钮）
  final ValueChanged<String>? onNoteIntent; // 识别为火场日志：记入并跳日志页
  final ValueChanged<String>? onAskIntent; // 识别为提问：跳问答页并发送
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
      WidgetsBinding.instance.addPostFrameCallback((_) => beginRecording());
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
        if (mounted) beginRecording();
      });
    }
  }

  @override
  void dispose() {
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

  /// 开始录音（长按触发）
  Future<void> beginRecording() async {
    widget.onAutoRecordConsumed?.call();
    if (_recording || _processing) return;
    _opId = 'op-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFF).toRadixString(16)}';
    OpLogService.instance.record(_opId!, 'record_start', '开始录音');
    setState(() {
      _error = null;
      _inlineError = null;
      _transcript = null;
      _parsed = null;
      _permDenied = false;
    });
    // 不清空已录入人员：支持多人分批次语音录入，最后一次性统一确认
    final ok = await _audio.hasPermission();
    if (!ok) {
      OpLogService.instance.record(_opId!, 'record_perm_denied', '缺少麦克风权限', level: 'warn');
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
      if (!mounted) return;
      setState(() => _recording = true);
      widget.onRecordingChanged?.call(true);
      _ampSub = _audio.amplitudeStream().listen((a) {
        if (mounted) setState(() => _amp = a);
      });
    } catch (e) {
      OpLogService.instance.record(_opId!, 'record_start_err', '录音启动失败: $e', level: 'error');
      if (mounted) setState(() => _error = '录音启动失败: $e');
      _endOp('record_error');
    }
  }

  /// 结束录音（松手触发）→ 转写 + 解析
  Future<void> finishRecording() async {
    if (!_recording) return;
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
      OpLogService.instance
          .record(opId, 'record_stop', '录音结束', data: {'bytes': bytes.length, 'ms': sw.elapsedMilliseconds});
      String text;
      try {
        text = await widget.controller.transcribeAudio(bytes, opId: opId);
        OpLogService.instance
            .record(opId, 'transcribe_ok', '转写成功', data: {'text': text, 'ms': sw.elapsedMilliseconds});
      } catch (e) {
        OpLogService.instance.record(opId, 'transcribe_err', '转写失败: $e', level: 'error');
        rethrow;
      }
      if (text.isEmpty) {
        OpLogService.instance.record(opId, 'transcribe_empty', '未识别到语音，请再说一次', level: 'warn');
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
        OpLogService.instance.record(opId, 'parse_ok', '语义解析完成',
            data: {'text': text, 'parsed': parsed.toJson(), 'ms': sw.elapsedMilliseconds});
      } catch (e) {
        OpLogService.instance.record(opId, 'parse_err', '解析失败: $e', level: 'error');
        rethrow;
      }
      if (!mounted) return;
      // 识别"钢瓶为9升"等容积表达：应用到全部待确认人员，并作为新录入默认值
      final statedVol = _extractVolumeL(text);
      if (statedVol != null) {
        _statedVolumeL = statedVol;
        OpLogService.instance
            .record(opId, 'volume_detected', '识别到气瓶容积', data: {'text': text, 'volume_l': statedVol});
        for (final ed in _peopleEditors) {
          ed.volumeCtrl.text = statedVol.toStringAsFixed(1);
        }
      }
      // 意图路由：日志 → 交 main 记入并跳转；提问 → 跳问答页；环境音 → 提示重新录入
      if (parsed.intent == VoiceIntent.note) {
        OpLogService.instance.record(opId, 'note_auto', '识别为火场日志，跳转日志页', data: {'text': text});
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
        OpLogService.instance.record(opId, 'ask_auto', '识别为提问，跳转辅助问答', data: {'text': text});
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
        OpLogService.instance.record(opId, 'ignore_auto', '环境音/无关内容，丢弃', data: {'text': text});
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
      // 追加到已录入名单：同名人员更新压力（更正），其余新增一行
      for (final p in parsed.people) {
        final idx = _peopleEditors
            .indexWhere((ed) => (ed.name == p.name && ed.name.isNotEmpty) || ed.sourceName == p.name);
        if (idx >= 0) {
          if (p.pressureMpa != null) _peopleEditors[idx].pressureCtrl.text = p.pressureMpa.toString();
          continue;
        }
        final ed = _PersonEdit(onChanged: _onEditsChanged);
        // 非名单内姓名大概率是口误/识别错误：姓名栏留空，等用户手动补全
        if (_isKnownName(p.name)) {
          ed.nameCtrl.text = p.name;
        } else {
          ed.sourceName = p.name;
        }
        if (p.pressureMpa != null) ed.pressureCtrl.text = p.pressureMpa.toString();
        final defaultVol = _statedVolumeL ?? widget.controller.calcConfig.cylinderVolL;
        ed.volumeCtrl.text = defaultVol.toStringAsFixed(1);
        _peopleEditors.add(ed);
      }
      setState(() {
        _transcript = text;
        _parsed = parsed;
        _processing = false;
      });
      widget.onProcessingChanged?.call(false);
      if (parsed.action == 'exit') {
        if (parsed.people.isNotEmpty) {
          await _handleExit(parsed.people.map((p) => p.name).toList());
        } else {
          await _confirmAllExit(text);
        }
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
  void _endOp(String outcome, {String level = 'info', Map<String, dynamic>? data}) {
    final opId = _opId;
    _opId = null;
    if (opId == null) return;
    OpLogService.instance
        .record(opId, 'op_end', '本次操作结束', level: level, data: {'outcome': outcome, ...?data});
    OpLogService.instance.flush(api: widget.controller.api);
  }

  Future<void> _handleExit(List<String> names) async {
    final notFound = <String>[];
    var exited = 0;
    for (final name in names) {
      final active = widget.controller.entries.where((e) => e.isActive && e.name == name).toList();
      if (active.isEmpty) {
        notFound.add(name);
        OpLogService.instance
            .record(_opId ?? '', 'exit_skip', '未找到在场人员「$name」', level: 'warn');
        continue;
      }
      for (final e in active) {
        await widget.controller.markExited(e.id, opId: _opId);
        OpLogService.instance
            .record(_opId ?? '', 'exit_ok', '已登记「$name」出火场', data: {'entryId': e.id, 'name': name});
      }
      exited++;
    }
    if (!mounted) return;
    final done = names.where((n) => !notFound.contains(n)).join('、');
    if (exited > 0) {
      // 进出场同步写火场日志：合并一条，只记名字+动作
      final noteText = names.where((n) => !notFound.contains(n)).map((n) => '$n出场').join('、');
      try {
        await widget.controller.addNote(noteText, opId: _opId);
        OpLogService.instance.record(_opId ?? '', 'exit_note', '出场事件已写入火场日志', data: {'text': noteText});
      } catch (_) {
        // 写日志失败不影响主流程
      }
      widget.controller.tts.speak('$done 已登记出火场');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$done 已登记出火场'), duration: const Duration(seconds: 2)),
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
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
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
        content: Text('识别到全员离场指令，当前在场 ${active.length} 人：${active.map((e) => e.name).join('、')}\n\n语音原文：「$voiceText」\n\n确认全部登记离场？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认全员离场')),
        ],
      ),
    );
    if (confirmed != true) {
      OpLogService.instance.record(_opId ?? '', 'exit_all_cancelled', '用户取消全员离场', level: 'info');
      if (mounted) {
        setState(() {
          _transcript = null;
          _parsed = null;
          _error = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已取消全员离场'), duration: Duration(seconds: 2)),
        );
      }
      _endOp('exit_all_cancel');
      return;
    }
    var exited = 0;
    for (final e in active) {
      await widget.controller.markExited(e.id, opId: _opId);
      OpLogService.instance
          .record(_opId ?? '', 'exit_all_ok', '全员离场已登记「${e.name}」', data: {'entryId': e.id, 'name': e.name});
      exited++;
    }
    if (!mounted) return;
    widget.controller.tts.speak('全体人员已登记离场');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已全员离场（$exited 人）'), duration: const Duration(seconds: 2)),
    );
    // 进出场同步写火场日志：合并一条，只记名字+动作
    final noteText = active.map((e) => '${e.name}出场').join('、');
    try {
      await widget.controller.addNote(noteText, opId: _opId);
      OpLogService.instance.record(_opId ?? '', 'exit_all_note', '全员离场已写入火场日志', data: {'text': noteText});
    } catch (_) {
      // 写日志失败不影响主流程
    }
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
    final m = RegExp(r'([0-9]+(?:\.[0-9]+)?|[一二两三四五六七八九十]+)\s*(?:公升|升)').firstMatch(text);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!) ?? _cnNum(m.group(1)!);
    if (v == null || v <= 0 || v > 20) return null;
    return v;
  }

  double? _cnNum(String s) {
    const digits = {
      '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
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
    setState(() {
      _transcript = null;
      _parsed = null;
      _error = null;
      _inlineError = null;
      _processing = false;
      _permDenied = false;
    });
    widget.onProcessingChanged?.call(false);
    _clearEditors();
  }

  /// 兜底：把当前转写内容转为火场日志（识别为报数但实际是记录时使用）
  Future<void> _saveAsNote() async {
    final text = _transcript;
    if (text == null || text.isEmpty) return;
    try {
      await widget.controller.addNote(text, opId: _opId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已转为日志记录'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      _retry();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '转为日志失败：$e');
      }
    }
  }

  /// 从空闲态回到待确认名单（出场/取消录音后仍有已录入人员时）
  void _showPendingConfirm() {
    if (_peopleEditors.isEmpty) return;
    setState(() {
      _transcript = '已录入 ${_peopleEditors.length} 人，待统一确认';
      _parsed = ParseResult(
        action: 'enter',
        people: _peopleEditors
            .map((ed) => ParsePerson(
                  name: ed.name.isEmpty ? (ed.sourceName ?? '') : ed.name,
                  pressureMpa: ed.pressure,
                ))
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
        OpLogService.instance.record(_opId ?? '', 'confirm_enter', '已登记「${ed.name}」进场', data: {
          'name': ed.name,
          'pressure_mpa': ed.pressure,
          'volume_l': ed.volume,
          'result': result == _SubmitResult.created ? 'created' : 'merged',
        });
      } else if (result == _SubmitResult.error) {
        OpLogService.instance.record(_opId ?? '', 'confirm_err', '「${ed.name}」登记进场失败', level: 'error');
      }
      results.add((ed: ed, result: result));
      if (result == _SubmitResult.cancelled) break;
    }
    if (!mounted) return;

    final done = <String>[];
    final failed = <String>[];
    final kept = <_PersonEdit>[];
    for (final r in results) {
      final ok =
          r.result == _SubmitResult.created || r.result == _SubmitResult.merged;
      if (ok) {
        done.add(r.ed.name);
        r.ed.dispose();
      } else {
        failed.add(r.ed.name);
        kept.add(r.ed);
      }
    }
    // 取消中断后未提交的剩余行一并保留
    for (var i = results.length; i < _peopleEditors.length; i++) {
      kept.add(_peopleEditors[i]);
    }
    _peopleEditors
      ..clear()
      ..addAll(kept);

    if (done.isNotEmpty) {
      // 进出场同步写火场日志：合并一条，只记名字+动作
      final noteText = done.map((n) => '$n进场').join('、');
      try {
        await widget.controller.addNote(noteText, opId: _opId);
        OpLogService.instance.record(_opId ?? '', 'enter_note', '进场事件已写入火场日志', data: {'text': noteText});
      } catch (_) {
        // 写日志失败不影响主流程
      }
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
    final allDone = failed.isEmpty && _peopleEditors.isEmpty;
    if (mounted) {
      setState(() {
        if (allDone) {
          _transcript = null;
          _parsed = null;
        }
        _inlineError = null;
        _processing = false;
      });
    }
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
      _endOp('enter_ok', data: {'names': done});
    }
  }

  /// 提交单个人：本地预检同名 → 弹窗合并/另建；服务端 409 时兜底再弹一次
  Future<_SubmitResult> _submitPerson(String name, double p, double volumeL) async {
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
    ed.dispose();
    if (_peopleEditors.isEmpty) {
      _retry();
      return;
    }
    if (mounted) setState(() {});
  }

  Future<_SubmitResult> _tryMerge(Entry existing, double p) async {
    try {
      await widget.controller.mergeEntryPressure(id: existing.id, pressureMpa: p, opId: _opId);
      return _SubmitResult.merged;
    } catch (e) {
      OpLogService.instance.record(_opId ?? '', 'merge_err', '合并压力失败: $e', level: 'error');
      if (mounted) setState(() => _error = '$e');
      return _SubmitResult.error;
    }
  }

  Future<_SubmitResult> _tryCreate(String name, double p, {bool force = false, double? volumeL}) async {
    try {
      await widget.controller.createEntryFromVoice(
        name: name,
        pressureMpa: p,
        rawText: _transcript,
        force: force,
        volumeL: volumeL,
        opId: _opId,
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
      OpLogService.instance.record(_opId ?? '', 'create_err', '登记进场失败: $e', level: 'error');
      if (mounted) setState(() => _error = '$e');
      return _SubmitResult.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.controller.calcConfig;
    final sceneEnded = widget.controller.sceneEnded;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Text('任务', style: AppTextStyles.h1),
                const Spacer(),
                ConnectionStatus(
                  connected: !widget.controller.connectionLost,
                  onRetry: widget.controller.startSync,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _TaskBar(
              sceneCode: widget.controller.api?.sceneCode ?? 'default',
              activeCount: widget.controller.entries.where((e) => e.isActive).length,
              dangerCount: widget.controller.entries
                  .where((e) =>
                      e.isActive &&
                      e.statusAt(warnMin: cfg.warnMin, alarmMin: cfg.alarmMin) != 'normal')
                  .length,
              onCopy: _copySceneCode,
              onChange: _changeSceneCode,
              onEndTask: _confirmEndTask,
            ),
            if (sceneEnded != null) ...[
              const SizedBox(height: 8),
              _SceneEndedBanner(
                state: sceneEnded,
                onSwitch: _switchScene,
              ),
            ],
            const SizedBox(height: 8),
            Expanded(child: _buildResultCard(context, cfg)),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// 复制当前任务码（新设备加入本任务时使用）
  Future<void> _copySceneCode() async {
    final code = widget.controller.api?.sceneCode ?? 'default';
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('任务码 $code 已复制，新设备输入即可加入本任务'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 更换任务码：输入其他设备正在使用的任务码即可加入该任务（替代设置页入口）
  Future<void> _changeSceneCode() async {
    final current = widget.controller.api?.sceneCode ?? 'default';
    String input = current;
    final newCode = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('更换任务码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '输入其他设备正在使用的任务码，即可加入该任务。',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                onChanged: (v) => input = v,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '任务码',
                  hintText: '如 苹果',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, input.trim()),
              child: const Text('确认更换'),
            ),
          ],
        ),
      ),
    );
    if (newCode == null || newCode.isEmpty || !mounted) return;
    await Settings.setSceneCode(newCode);
    await widget.controller.refreshConfig();
    await widget.controller.sync();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已切换到任务码 $newCode'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 结束任务（归档）：二次确认（影响场景内所有设备，要求确认灾情处置已结束）
  Future<void> _confirmEndTask() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('结束任务（归档）'),
        content: const Text(
          '将结束当前灾情处置任务，所有连接本场景的设备将被提示切换到新任务。\n\n'
          '• 新场景码由服务器统一分配\n'
          '• 本机各页数据将清零（旧数据服务器保留，7-30 天后自动清理）\n\n'
          '请确认灾情处置是否已结束？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.alarm),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认结束'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final newCode = await widget.controller.endTask();
      if (!mounted) return;
      await _showNewSceneCode(newCode);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('结束任务失败：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 展示服务端分配的新场景码（新设备加入需手输此码）
  Future<void> _showNewSceneCode(String newCode) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('任务已结束'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('本机已切换到新任务，各页数据已清零。'),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surfaceSubtle,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.border),
              ),
              child: SelectableText(
                newCode,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '其他设备会自动收到切换提示；新设备加入时请输入此任务码。',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: newCode));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text('任务码已复制'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 其他设备响应归档横幅：一键切换到服务端分配的新场景码
  Future<void> _switchScene() async {
    await widget.controller.switchToNewScene();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已切换到新任务'),
        duration: Duration(seconds: 2),
      ),
    );
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
              style: TextStyle(color: AppColors.textSecondary, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('或：出火场人员姓名', style: TextStyle(color: AppColors.textTertiary, fontSize: 14)),
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
            const Text('语音转文字中…', style: TextStyle(color: AppColors.textSecondary)),
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
            border: Border.all(color: AppColors.caution.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.caution, size: 36),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
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
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.voice,
                          ),
                          child: const Icon(Icons.mic_rounded, size: 17, color: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          '按住下方按钮说话',
                          style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (ctx, c) {
                        final itemW = (c.maxWidth - 10) / 2;
                        return Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            SizedBox(width: itemW, child: _guideItem(Icons.login_rounded, '进场登记', '「张伟，20兆帕」\n自动开始倒计时')),
                            SizedBox(width: itemW, child: _guideItem(Icons.groups_rounded, '多人进场', '「张伟20兆帕，刘洋22兆帕」\n一次确认全部进场')),
                            SizedBox(width: itemW, child: _guideItem(Icons.logout_rounded, '出场登记', '「刘洋出来了」\n登记出火场')),
                            SizedBox(width: itemW, child: _guideItem(Icons.edit_note_rounded, '火场随手记', '「三楼破拆完成」\n自动记入火场日志')),
                            SizedBox(width: itemW, child: _guideItem(Icons.assistant_rounded, '火场提问', '「浓烟太大看不清路怎么办？」\n转给辅助智囊')),
                          ],
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
                    const Text('转写结果', style: TextStyle(color: AppColors.textTertiary, fontSize: 12, letterSpacing: 0.5)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(_transcript!, style: const TextStyle(fontSize: 17, height: 1.4, color: AppColors.textPrimary)),
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
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
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
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
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
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _confirmAll,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('确认进入火场，开始倒计时', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: _processing ? null : beginRecording,
                      icon: const Icon(Icons.mic_none),
                      label: const Text('继续语音添加'),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: TextButton.icon(
                      onPressed: _processing ? null : _saveAsNote,
                      icon: const Icon(Icons.edit_note, size: 18),
                      label: const Text('转为日志记录'),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
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
            children: [
              const Icon(Icons.fact_check_outlined, size: 16, color: AppColors.voice),
              const SizedBox(width: 6),
              Text(
                '确认名单（${_peopleEditors.length} 人）：请下滑核对后一次性确认',
                style: const TextStyle(color: AppColors.textTertiary, fontSize: 12, letterSpacing: 0.5),
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
                  minimumSize: const Size(0, 36),
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
            height: 52,
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
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _processing ? null : beginRecording,
              icon: const Icon(Icons.mic_none),
              label: const Text('继续语音添加'),
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: TextButton.icon(
              onPressed: _processing ? null : _saveAsNote,
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('转为日志记录'),
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: 44,
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
    return Row(
      children: [
        _IndexBadge(index: index),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: ed.nameCtrl,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '姓名',
              prefixIcon: Icon(Icons.person_outline, size: 20),
            ),
            style: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 104,
          child: TextField(
            controller: ed.pressureCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              isDense: true,
              labelText: '压力',
              suffixText: 'MPa',
            ),
            style: const TextStyle(fontSize: 16),
          ),
        ),
      ],
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
        ? widget.controller.entries.where((e) => e.isActive && e.name == name).toList()
        : <Entry>[];
    final boxStyle = BoxDecoration(
      color: AppColors.caution.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      border: Border.all(color: AppColors.caution.withValues(alpha: 0.4)),
    );
    final style = const TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600, height: 1.4);
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
                const Icon(Icons.gas_meter_outlined, size: 16, color: AppColors.textTertiary),
                const SizedBox(width: 6),
                const Text('容量', style: TextStyle(fontSize: 12.5, color: AppColors.textTertiary, fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 62,
                  height: 34,
                  child: TextField(
                    controller: ed.volumeCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Text('L', style: TextStyle(fontSize: 12.5, color: AppColors.textTertiary, fontWeight: FontWeight.w600)),
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
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }

  /// 引导网格项：图标 + 意图标签 + 语音示例（两行，覆盖全部语音意图）
  Widget _guideItem(IconData icon, String label, String example) {
    return Container(
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
            children: [
              Icon(icon, size: 15, color: AppColors.voice),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
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

  _PersonEdit({required this.onChanged}) {
    nameCtrl.addListener(onChanged);
    pressureCtrl.addListener(onChanged);
    volumeCtrl.addListener(onChanged);
  }

  String get name => nameCtrl.text.trim();

  double? get pressure => double.tryParse(pressureCtrl.text.trim());

  double? get volume => double.tryParse(volumeCtrl.text.trim());

  void dispose() {
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
      decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.voice),
      child: Text(
        '${index + 1}',
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
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
    return SizedBox(
      width: 112,
      height: 112,
      child: AnimatedScale(
        scale: 0.96 + intensity.clamp(0, 1) * 0.04,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.voice.withValues(alpha: 0.1),
            border: Border.all(
              color: AppColors.voice.withValues(alpha: 0.58),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.voice.withValues(alpha: 0.12),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.mic_rounded, size: 46, color: AppColors.voice),
        ),
      ),
    );
  }
}

/// 任务卡：任务码（复制/更换）+ 在场概览 + 结束任务入口。
/// 任务身份与任务管理都收在核心 hub 页面，设置页不再承载任务码。
class _TaskBar extends StatelessWidget {
  final String sceneCode;
  final int activeCount;
  final int dangerCount;
  final VoidCallback onCopy;
  final VoidCallback onChange;
  final VoidCallback onEndTask;

  const _TaskBar({
    required this.sceneCode,
    required this.activeCount,
    required this.dangerCount,
    required this.onCopy,
    required this.onChange,
    required this.onEndTask,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('task-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.card,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '任务码',
                      style: TextStyle(fontSize: 10.5, color: AppColors.textTertiary, letterSpacing: 0.5),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: onCopy,
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.copy_rounded, size: 13, color: AppColors.textTertiary),
                      ),
                    ),
                    const SizedBox(width: 2),
                    InkWell(
                      onTap: onChange,
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.edit_outlined, size: 13, color: AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                SelectableText(
                  sceneCode,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                    color: AppColors.textPrimary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, height: 36, color: AppColors.border),
          const SizedBox(width: 12),
          Tooltip(
            message: '进入火场内部、正在气瓶倒计时管控的人数',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '在场 $activeCount 人',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  dangerCount > 0 ? '需关注 $dangerCount' : '状态正常',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: dangerCount > 0 ? AppColors.alarm : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: '结束任务',
            child: IconButton(
              onPressed: onEndTask,
              icon: const Icon(Icons.flag_outlined, size: 22),
              color: AppColors.alarm,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

/// 归档横幅：本场景已被某设备结束任务，常驻提示可一键切换（不弹窗打断）
class _SceneEndedBanner extends StatelessWidget {
  final SceneState state;
  final VoidCallback onSwitch;

  const _SceneEndedBanner({required this.state, required this.onSwitch});

  String get _timeText {
    final t = DateTime.fromMillisecondsSinceEpoch(state.endedAt);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('scene-ended-banner'),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.caution.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.caution.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.flag_rounded, size: 17, color: AppColors.caution),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '本场景任务已结束（$_timeText）',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: onSwitch,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('切换到新任务', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
