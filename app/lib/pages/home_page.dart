import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/audio_service.dart';
import '../state/app_controller.dart';

/// 语音录入主页面
class HomePage extends StatefulWidget {
  final AppController controller;
  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
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
  void dispose() {
    _ampSub?.cancel();
    _nameCtrl.dispose();
    _pressureCtrl.dispose();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _beginRecording() async {
    if (_recording) return;
    setState(() {
      _error = null;
      _transcript = null;
      _parsed = null;
    });
    final ok = await _audio.hasPermission();
    if (!ok) {
      setState(() => _error = '需要麦克风权限');
      return;
    }
    try {
      await _audio.start();
      setState(() => _recording = true);
      _ampSub = _audio.amplitudeStream().listen((a) {
        if (mounted) setState(() => _amp = a);
      });
    } catch (e) {
      setState(() => _error = '录音启动失败: $e');
    }
  }

  Future<void> _finishRecording() async {
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
        setState(() {
          _processing = false;
          _error = '未识别到语音，请再说一次';
        });
        return;
      }
      final parsed = await widget.controller.api!.parse(text);
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
      setState(() {
        _processing = false;
        _error = '$e';
      });
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
                const Text('语音录入', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (widget.controller.syncError != null)
                  const Icon(Icons.cloud_off, color: Colors.orange, size: 18),
                if (widget.controller.syncError == null)
                  const Icon(Icons.cloud_done, color: Colors.green, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _buildResultCard(context, cfg),
            ),
            const SizedBox(height: 16),
            _buildMicButton(),
            const SizedBox(height: 8),
            Text(
              _recording ? '正在聆听…' : (_processing ? '识别中…' : '按住说话，例：「张伟，20兆帕」'),
              style: TextStyle(
                fontSize: 15,
                color: _recording ? Colors.redAccent : Colors.grey.shade400,
                fontWeight: _recording ? FontWeight.bold : FontWeight.normal,
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
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 90 + _amp * 140,
              height: 90 + _amp * 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent.withValues(alpha: 0.15 + _amp * 0.4),
              ),
              child: const Icon(Icons.mic, size: 48, color: Colors.redAccent),
            ),
            const SizedBox(height: 24),
            Text('请清晰说出：姓名 + 气瓶压力', style: TextStyle(color: Colors.grey.shade400, fontSize: 16)),
            const SizedBox(height: 8),
            Text('或：出火场人员姓名', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
          ],
        ),
      );
    }
    if (_processing) {
      return const Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('语音转文字中…', style: TextStyle(color: Colors.grey)),
        ],
      ));
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.orange, fontSize: 16)));
    }
    if (_transcript == null || _parsed == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.record_voice_over, size: 96, color: Colors.white24),
            const SizedBox(height: 24),
            Text('按住下方按钮说话', style: TextStyle(color: Colors.grey.shade500, fontSize: 18)),
            const SizedBox(height: 8),
            Text('例：「张伟，20兆帕」 → 自动计算可用34分钟并倒计时', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 4),
            Text('例：「李娜出来了」 → 登记出火场', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
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
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2126),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('转写结果', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                const SizedBox(height: 6),
                Text(_transcript!, style: const TextStyle(fontSize: 18)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_parsed!.action == 'exit')
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.logout, color: Colors.teal),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '识别为出火场指令：${_parsed!.name ?? '未识别姓名'}',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2126),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(labelText: '姓名', prefixIcon: Icon(Icons.person)),
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pressureCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: '气瓶压力 (MPa)',
                      prefixIcon: Icon(Icons.speed),
                      suffixText: 'MPa',
                    ),
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 12),
                  if (durationMin != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2E35),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '可用时间：$durationMin 分钟（${cfg.cylinderVolL}L 气瓶 × ${_parsed!.pressureMpa} 兆帕 ÷ ${cfg.consumptionLpm}L/min）',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15, color: Colors.amber),
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '未识别到气瓶压力，请手动填写（如 20）后确认',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.orange),
                      ),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _confirmEnter,
                      icon: const Icon(Icons.check),
                      label: const Text('确认进入火场，开始倒计时', style: TextStyle(fontSize: 17)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMicButton() {
    return GestureDetector(
      onLongPressStart: (_) => _beginRecording(),
      onLongPressEnd: (_) => _finishRecording(),
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _recording ? Colors.redAccent : const Color(0xFFD32F2F),
          boxShadow: [
            BoxShadow(
              color: (_recording ? Colors.redAccent : const Color(0xFFD32F2F)).withValues(alpha: 0.5),
              blurRadius: _recording ? 32 : 16,
              spreadRadius: _recording ? 8 : 2,
            ),
          ],
        ),
        child: Icon(
          _recording ? Icons.stop : Icons.mic,
          size: 44,
          color: Colors.white,
        ),
      ),
    );
  }
}
