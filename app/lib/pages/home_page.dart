import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/audio_service.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 语音录入主页面：按住说话 → 自动识别 → 确认进场 / 登记出场
class HomePage extends StatefulWidget {
  final AppController controller;
  final bool autoRecord; // 底部导航语音按钮长按触发
  final VoidCallback? onAutoRecordConsumed;

  const HomePage({
    super.key,
    required this.controller,
    this.autoRecord = false,
    this.onAutoRecordConsumed,
  });

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final AudioService _audio = AudioService();

  bool _recording = false;
  bool _processing = false;
  String? _transcript;
  ParseResult? _parsed;
  String? _error;
  StreamSubscription<double>? _ampSub;
  double _amp = 0.15;

  // 确认编辑用
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _pressureCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.autoRecord) {
      WidgetsBinding.instance.addPostFrameCallback((_) => beginRecording());
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
    _nameCtrl.dispose();
    _pressureCtrl.dispose();
    _audio.dispose();
    super.dispose();
  }

  /// 开始录音（长按触发）
  Future<void> beginRecording() async {
    widget.onAutoRecordConsumed?.call();
    if (_recording || _processing) return;
    setState(() {
      _error = null;
      _transcript = null;
      _parsed = null;
    });
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
      setState(() {
        _transcript = text;
        _parsed = parsed;
        _processing = false;
        _nameCtrl.text = parsed.name ?? '';
        _pressureCtrl.text = parsed.pressureMpa != null ? parsed.pressureMpa.toString() : '';
      });
      if (parsed.action == 'enter' && parsed.name != null) {
        widget.controller.tts.speak(
          '${parsed.name}，${parsed.pressureMpa ?? ''}兆帕，可用${widget.controller.calcConfig.durationMinFor(parsed.pressureMpa ?? 0).round()}分钟，已开始倒计时',
        );
      } else if (parsed.action == 'exit' && parsed.name != null) {
        await _handleExit(parsed.name!);
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

  Future<void> _handleExit(String name) async {
    final active = widget.controller.entries.where((e) => e.isActive && e.name == name).toList();
    if (active.isEmpty) {
      setState(() {
        _error = '未找到在场人员「$name」';
      });
      widget.controller.tts.speak('未找到在场人员 $name');
      return;
    }
    for (final e in active) {
      await widget.controller.markExited(e.id);
    }
    widget.controller.tts.speak('$name 已登记出火场');
    if (mounted) {
      final count = active.length > 1 ? '${active.length} ' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count$name 已登记出火场'), duration: const Duration(seconds: 2)),
      );
      setState(() {
        _transcript = null;
        _parsed = null;
      });
    }
  }

  Future<void> _confirmEnter() async {
    final name = _nameCtrl.text.trim();
    final pressure = double.tryParse(_pressureCtrl.text.trim());
    if (name.isEmpty) {
      setState(() => _error = '请输入姓名');
      return;
    }
    if (pressure == null) {
      setState(() => _error = '请填写气瓶压力（MPa）');
      return;
    }
    final p = pressure;
    if (p <= 0 || p > 40) {
      setState(() => _error = '压力数值异常（0-40MPa）');
      return;
    }
    setState(() => _processing = true);
    try {
      await widget.controller.createEntryFromVoice(
        name: name,
        pressureMpa: p,
        rawText: _transcript,
      );
      widget.controller.tts.speak(
          '$name，$p兆帕，可用${widget.controller.calcConfig.durationMinFor(p).round()}分钟，已开始倒计时',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name 已入火场，倒计时 ${widget.controller.calcConfig.durationMinFor(p).round()} 分钟')),
        );
        setState(() {
          _transcript = null;
          _parsed = null;
          _nameCtrl.clear();
          _pressureCtrl.clear();
          _processing = false;
        });
      }
    } catch (e) {
      setState(() {
        _processing = false;
        _error = '$e';
      });
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
            VoiceButton(
              size: 88,
              recording: _recording,
              onTap: _recording
                  ? null
                  : () {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('请按住按钮说话，松手自动识别'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
              onLongPressStart: (_) => beginRecording(),
              onLongPressEnd: (_) => finishRecording(),
            ),
            const SizedBox(height: 10),
            Text(
              _recording ? '正在聆听，松开结束' : (_processing ? '识别中…' : '按住说话，例：「张伟，20兆帕」'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: _recording ? FontWeight.w700 : FontWeight.w500,
                color: _recording ? AppColors.voice : AppColors.textSecondary,
              ),
            ),
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
            _example('例：「张伟，20兆帕」 → 自动计算可用34分钟并倒计时'),
            const SizedBox(height: 4),
            _example('例：「李娜出来了」 → 登记出火场'),
          ],
        ),
      );
    }

    final durationMin = _parsed!.pressureMpa != null
        ? cfg.durationMinFor(_parsed!.pressureMpa!).round()
        : null;

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
              child: Row(
                children: [
                  const Icon(Icons.logout, color: AppColors.safe),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '识别为出火场指令：${_parsed!.name ?? '未识别姓名'}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    ),
                  ),
                ],
              ),
            )
          else
            AppCard(
              child: Column(
                children: [
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(labelText: '姓名', prefixIcon: Icon(Icons.person_outline)),
                    style: const TextStyle(fontSize: 17),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _pressureCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: '气瓶压力 (MPa)',
                      prefixIcon: Icon(Icons.speed),
                      suffixText: 'MPa',
                    ),
                    style: const TextStyle(fontSize: 17),
                  ),
                  const SizedBox(height: 14),
                  if (durationMin != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.caution.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppColors.caution.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        '可用时间：$durationMin 分钟\n（${cfg.cylinderVolL}L 气瓶 × ${_parsed!.pressureMpa} 兆帕 ÷ ${cfg.consumptionLpm}L/min）',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14, color: AppColors.textPrimary, fontWeight: FontWeight.w600, height: 1.5),
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.caution.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppColors.caution.withValues(alpha: 0.4)),
                      ),
                      child: const Text(
                        '未识别到气瓶压力，请手动填写（如 20）后确认',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                      ),
                    ),
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
                ],
              ),
            ),
        ],
      ),
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
