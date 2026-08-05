import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../pages/same_name_dialog.dart';
import '../services/audio_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 语音录入主页面：按住说话 → 自动识别 → 确认进场 / 登记出场
class HomePage extends StatefulWidget {
  final AppController controller;
  final bool autoRecord; // 底部导航语音按钮长按触发
  final VoidCallback? onAutoRecordConsumed;
  final AudioService? audioService; // 测试注入

  const HomePage({
    super.key,
    required this.controller,
    this.autoRecord = false,
    this.onAutoRecordConsumed,
    this.audioService,
  });

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  late final AudioService _audio = widget.audioService ?? AudioService();

  bool _recording = false;
  bool _processing = false;
  String? _transcript;
  ParseResult? _parsed;
  String? _error;
  StreamSubscription<double>? _ampSub;
  double _amp = 0.15;

  // 确认编辑用：每次语音识别出的每个人员一组输入
  final List<_PersonEdit> _peopleEditors = [];

  // 多人逐人确认：当前确认到第几人 + 已确认姓名
  int _confirmIndex = 0;
  final List<String> _confirmedNames = [];

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
    _confirmIndex = 0;
    _confirmedNames.clear();
  }

  /// 开始录音（长按触发）
  Future<void> beginRecording() async {
    widget.onAutoRecordConsumed?.call();
    if (_recording || _processing) return;
    setState(() {
      _error = null;
      _inlineError = null;
      _transcript = null;
      _parsed = null;
    });
    _clearEditors();
    final ok = await _audio.hasPermission();
    if (!ok) {
      if (mounted) setState(() => _error = '需要麦克风权限');
      return;
    }
    try {
      await _audio.start();
      if (!mounted) return;
      setState(() => _recording = true);
      _ampSub = _audio.amplitudeStream().listen((a) {
        if (mounted) setState(() => _amp = a);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '录音启动失败: $e');
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
    _ampSub?.cancel();
    try {
      final bytes = await _audio.stop();
      final text = await widget.controller.api!.transcribe(bytes);
      if (text.isEmpty) {
        if (mounted) {
          setState(() {
            _processing = false;
            _error = '未识别到语音，请再说一次';
          });
        }
        return;
      }
      final parsed = await widget.controller.api!.parse(text);
      if (!mounted) return;
      _clearEditors();
      for (final p in parsed.people) {
        final ed = _PersonEdit(onChanged: _onEditsChanged);
        ed.nameCtrl.text = p.name;
        if (p.pressureMpa != null) ed.pressureCtrl.text = p.pressureMpa.toString();
        _peopleEditors.add(ed);
      }
      setState(() {
        _transcript = text;
        _parsed = parsed;
        _processing = false;
      });
      if (parsed.action == 'exit' && parsed.people.isNotEmpty) {
        await _handleExit(parsed.people.map((p) => p.name).toList());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processing = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _handleExit(List<String> names) async {
    final notFound = <String>[];
    var exited = 0;
    for (final name in names) {
      final active = widget.controller.entries.where((e) => e.isActive && e.name == name).toList();
      if (active.isEmpty) {
        notFound.add(name);
        continue;
      }
      for (final e in active) {
        await widget.controller.markExited(e.id);
      }
      exited++;
    }
    if (!mounted) return;
    final done = names.where((n) => !notFound.contains(n)).join('、');
    if (exited > 0) {
      widget.controller.tts.speak('$done 已登记出火场');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$done 已登记出火场'), duration: const Duration(seconds: 2)),
      );
    }
    setState(() {
      _transcript = null;
      _parsed = null;
      _error = notFound.isEmpty ? null : '未找到在场人员「${notFound.join('、')}」';
      _clearEditors();
    });
  }

  /// 重新语音输入：清除本次转写/解析结果与错误状态
  void _retry() {
    setState(() {
      _transcript = null;
      _parsed = null;
      _error = null;
      _inlineError = null;
      _processing = false;
    });
    _clearEditors();
  }

  /// 校验单个人员：返回错误文案，null 表示通过
  String? _validatePerson(_PersonEdit ed) {
    if (ed.name.isEmpty) return '缺少姓名';
    final p = ed.pressure;
    if (p == null) return '「${ed.name}」缺少气瓶压力';
    if (p <= 0 || p > 40) return '「${ed.name}」压力数值异常';
    return null;
  }

  /// 确认进场：单人直接提交；多人逐人确认（同名在场时弹窗二选一），全部确认完才清空表单
  Future<void> _confirmEnter() async {
    if (_peopleEditors.isEmpty) {
      setState(() => _error = '未识别到人员信息，请重新语音输入');
      return;
    }
    final ed = _peopleEditors[_confirmIndex];
    final problem = _validatePerson(ed);
    if (problem != null) {
      setState(() => _inlineError = problem);
      return;
    }

    setState(() => _processing = true);
    final result = await _submitPerson(ed.name, ed.pressure!);
    if (!mounted) return;
    if (result == _SubmitResult.cancelled || result == _SubmitResult.error) {
      setState(() => _processing = false);
      return;
    }
    _confirmedNames.add(ed.name);
    final isLast = _confirmIndex >= _peopleEditors.length - 1;
    if (!isLast) {
      setState(() {
        _processing = false;
        _confirmIndex++;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已登记「${ed.name}」，请确认第 ${_confirmIndex + 1} 位'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    final names = List.of(_confirmedNames);
    _confirmedNames.clear();
    widget.controller.tts.speak('${names.join('、')}，已开始倒计时');
    setState(() {
      _transcript = null;
      _parsed = null;
      _error = null;
      _inlineError = null;
      _processing = false;
      _confirmIndex = 0;
      _clearEditors();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${names.join('、')} 已入火场，开始倒计时'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 提交单个人：本地预检同名 → 弹窗合并/另建；服务端 409 时兜底再弹一次
  Future<_SubmitResult> _submitPerson(String name, double p) async {
    final existing = widget.controller.entries
        .where((e) => e.isActive && e.name == name)
        .toList();
    if (existing.isNotEmpty) {
      final choice = await _askSameName(existing.first, p);
      if (choice == null) return _SubmitResult.cancelled;
      if (choice == SameNameChoice.merge) {
        return await _tryMerge(existing.first, p);
      }
      return await _tryCreate(name, p, force: true);
    }
    return await _tryCreate(name, p);
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
    if (_confirmIndex >= _peopleEditors.length) {
      _confirmIndex = _peopleEditors.isEmpty ? 0 : _peopleEditors.length - 1;
    }
    if (mounted) setState(() {});
  }

  /// 逐人确认中移除当前人员；全部移除后回到初始状态
  void _removeCurrentPerson() {
    _removeEditorAt(_confirmIndex);
    if (_peopleEditors.isEmpty) {
      _retry();
    }
  }

  Future<_SubmitResult> _tryMerge(Entry existing, double p) async {
    try {
      await widget.controller.mergeEntryPressure(id: existing.id, pressureMpa: p);
      return _SubmitResult.merged;
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return _SubmitResult.error;
    }
  }

  Future<_SubmitResult> _tryCreate(String name, double p, {bool force = false}) async {
    try {
      await widget.controller.createEntryFromVoice(
        name: name,
        pressureMpa: p,
        rawText: _transcript,
        force: force,
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
      return await _tryCreate(name, p, force: true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return _SubmitResult.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.controller.calcConfig;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Text('语音录入', style: AppTextStyles.h1),
                const Spacer(),
                ConnectionStatus(
                  syncing: widget.controller.syncing,
                  offline: widget.controller.syncError != null,
                  onRetry: widget.controller.startSync,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildResultCard(context, cfg)),
            const SizedBox(height: 12),
            Text(
              _recording
                  ? '正在聆听，松开结束'
                  : (_processing ? '识别中…' : '按住下方按钮说话，例：「张伟，20兆帕」'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: _recording ? FontWeight.w700 : FontWeight.w500,
                color: _recording ? AppColors.voice : AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(BuildContext context, CalcConfig cfg) {
    if (_recording) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _PulseMic(size: 90 + _amp * 140, intensity: _amp),
            const SizedBox(height: 24),
            const Text(
              '请清晰说出：姓名 + 气瓶压力',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('或：出火场人员姓名', style: TextStyle(color: AppColors.textTertiary, fontSize: 14)),
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
              OutlinedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.replay),
                label: const Text('重新语音输入'),
              ),
              if (_parsed != null && _peopleEditors.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('返回确认'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_transcript == null || _parsed == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.record_voice_over, size: 44, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 24),
            const Text('按住下方按钮说话', style: TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            _example('例：「张伟20兆帕，李娜22兆帕」 → 多人逐人确认进场'),
            const SizedBox(height: 4),
            _example('例：「张伟，20兆帕」 → 单人进场，可用34分钟'),
            const SizedBox(height: 4),
            _example('例：「李娜出来了」 → 登记出火场'),
          ],
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
                          '识别为出火场指令：${_parsed!.people.map((p) => p.name).join('、')}',
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
            _buildWizardCard(context, cfg)
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
                      onPressed: _confirmEnter,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('确认进入火场，开始倒计时', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 10),
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
            ),
        ],
      ),
    );
  }

  /// 多人逐人确认卡片：进度 + 当前人员信息 + 逐人确认
  Widget _buildWizardCard(BuildContext context, CalcConfig cfg) {
    final ed = _peopleEditors[_confirmIndex];
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
                '逐人确认：第 ${_confirmIndex + 1} / ${_peopleEditors.length} 人',
                style: const TextStyle(color: AppColors.textTertiary, fontSize: 12, letterSpacing: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _wizardProgress(),
          const SizedBox(height: 14),
          _personEditorRow(_confirmIndex, ed),
          const SizedBox(height: 8),
          _personHints(ed, cfg),
          if (_inlineError != null) ...[
            const SizedBox(height: 8),
            _inlineErrorBox(_inlineError!),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: _processing ? null : _confirmEnter,
              icon: const Icon(Icons.check_circle_outline),
              label: Text(
                '确认「${ed.name.isEmpty ? '第${_confirmIndex + 1}人' : ed.name}」进入火场',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _processing ? null : _removeCurrentPerson,
                  icon: const Icon(Icons.person_remove_outlined, size: 18),
                  label: const Text('移除该人员'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.replay),
                  label: const Text('重新语音输入'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 逐人确认进度：已确认（绿）/ 当前（橙）/ 待确认（灰）
  Widget _wizardProgress() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (i, ed) in _peopleEditors.indexed)
          _wizardChip(i: i, name: ed.name.isEmpty ? '未识别姓名' : ed.name),
      ],
    );
  }

  Widget _wizardChip({required int i, required String name}) {
    final done = i < _confirmIndex;
    final current = i == _confirmIndex;
    final c = done
        ? AppColors.safe
        : (current ? AppColors.voice : AppColors.textTertiary);
    final bg = done
        ? AppColors.safe.withValues(alpha: 0.12)
        : (current ? AppColors.voice.withValues(alpha: 0.14) : AppColors.surfaceSubtle);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            done
                ? Icons.check_circle
                : (current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            size: 14,
            color: c,
          ),
          const SizedBox(width: 5),
          Text(
            '${i + 1}.$name',
            style: TextStyle(
              fontSize: 12.5,
              color: done || current ? AppColors.textPrimary : AppColors.textSecondary,
              fontWeight: current ? FontWeight.w700 : FontWeight.w600,
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
              labelText: '压力 (MPa)',
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
          height: 1.4,
        ),
      ),
    );
  }

  /// 单行人员的提示：在场同名警告 + 可用时间
  Widget _personHints(_PersonEdit ed, CalcConfig cfg) {
    final name = ed.name;
    final p = ed.pressure;
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: boxStyle,
            child: Text(
              '可用时间 ${cfg.durationMinFor(p).round()} 分钟（${cfg.cylinderVolL}L × $p MPa ÷ ${cfg.consumptionLpm}L/min）',
              textAlign: TextAlign.center,
              style: style,
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

  Widget _example(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(text, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
    );
  }
}

/// 单人提交结果
enum _SubmitResult { created, merged, cancelled, error }

/// 单个人员的姓名/压力编辑组（随输入实时刷新提示）
class _PersonEdit {
  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController pressureCtrl = TextEditingController();
  final VoidCallback onChanged;

  _PersonEdit({required this.onChanged}) {
    nameCtrl.addListener(onChanged);
    pressureCtrl.addListener(onChanged);
  }

  String get name => nameCtrl.text.trim();

  double? get pressure => double.tryParse(pressureCtrl.text.trim());

  void dispose() {
    nameCtrl.removeListener(onChanged);
    pressureCtrl.removeListener(onChanged);
    nameCtrl.dispose();
    pressureCtrl.dispose();
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

/// 录音时随振幅缩放的核心圆（橙色脉冲）
class _PulseMic extends StatelessWidget {
  final double size;
  final double intensity;

  const _PulseMic({required this.size, required this.intensity});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.voice;
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PulseRing(color: c.withValues(alpha: 0.5), ringSize: 150 + intensity * 50),
          PulseRing(color: c.withValues(alpha: 0.3), ringSize: 170 + intensity * 40),
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.withValues(alpha: 0.15 + intensity * 0.35),
              border: Border.all(
                color: c.withValues(alpha: 0.4 + intensity * 0.5),
                width: 2,
              ),
            ),
            child: Icon(Icons.mic_rounded, size: 48, color: c),
          ),
        ],
      ),
    );
  }
}
