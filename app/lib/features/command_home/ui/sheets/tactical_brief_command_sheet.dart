import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design_system/design_system.dart';
import '../../../../services/tactical_brief_engine.dart';

typedef BriefClipboardWriter = Future<void> Function(String text);

/// 弹出基于 [CommandSheet] 的警情上报（战术简报）抽屉。
///
/// 由外部（`command_home_assembly.dart` 或测试）调用冻结引擎
/// [TacticalBriefEngine.formatObjectiveBrief] 生成纯客观公文文本并传入，
/// 弹窗内部再次经过 [TacticalBriefEngine.sanitizeBriefText] 脱敏兜底。
Future<void> showTacticalBriefCommandSheet(
  BuildContext context, {
  required String briefText,
  BriefClipboardWriter? clipboardWriter,
  Duration copiedResetDelay = const Duration(seconds: 2),
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext _) => TacticalBriefCommandSheet(
      briefText: briefText,
      clipboardWriter: clipboardWriter,
      copiedResetDelay: copiedResetDelay,
    ),
  );
}

/// 通讯员警情上报生成与一键复制面板（Design System v3.0）。
class TacticalBriefCommandSheet extends StatefulWidget {
  const TacticalBriefCommandSheet({
    super.key,
    required this.briefText,
    this.clipboardWriter,
    this.copiedResetDelay = const Duration(seconds: 2),
  });

  final String briefText;
  final BriefClipboardWriter? clipboardWriter;
  final Duration copiedResetDelay;

  @override
  State<TacticalBriefCommandSheet> createState() =>
      _TacticalBriefCommandSheetState();
}

class _TacticalBriefCommandSheetState extends State<TacticalBriefCommandSheet> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String sanitized) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final writer =
        widget.clipboardWriter ??
        (String text) => Clipboard.setData(ClipboardData(text: text));
    await writer(sanitized);
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    setState(() => _copied = true);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('已复制标准化警情上报，可直接切换至政务微信/政务钉群粘贴发送'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          backgroundColor: context.ds.colors.safeFill,
        ),
      );
    _resetTimer?.cancel();
    _resetTimer = Timer(widget.copiedResetDelay, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final sanitized = TacticalBriefEngine.sanitizeBriefText(widget.briefText);

    return CommandSheet(
      title: '警情上报',
      subtitle: '纯客观陈述 · 去富文本杂质 · 适合政务通讯直接发送',
      actions: <Widget>[
        CommandButton(
          key: const Key('tactical-brief-copy-btn'),
          label: _copied ? '已复制到剪贴板' : '一键复制上报全文',
          icon: _copied ? Icons.check_circle_rounded : Icons.copy_rounded,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          expanded: true,
          onPressed: () => _copy(sanitized),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SurfaceCard(
            level: DsSurfaceLevel.flat,
            borderColor: colors.border,
            borderRadius: DsRadius.borderMd,
            child: SelectableText(
              sanitized,
              style: typo.body.copyWith(
                fontFamily: 'monospace',
                color: colors.textPrimary,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: DsSpacing.sm),
          Text(
            '已自动脱敏过滤内部密码与敏感标识',
            textAlign: TextAlign.center,
            style: typo.micro.copyWith(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}
