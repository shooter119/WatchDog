import 'dart:math';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/chat_message.dart';
import 'copilot_message_bubble.dart';

const List<(String text, IconData icon)> _copilotSampleQuestions =
    <(String, IconData)>[
      ('气瓶压力下降太快怎么办？', DsIcons.gasMeter),
      ('浓烟中看不清路怎么办？', DsIcons.eyeOff),
      ('破拆卷帘门有哪些注意事项？', DsIcons.doorLock),
    ];

/// 智能辅助欢迎态：水元素头像、核心能力提示、三条等高常见紧急提问卡片及免责声明。
class CopilotWelcomeView extends StatelessWidget {
  const CopilotWelcomeView({
    super.key,
    required this.onSelectSample,
    required this.scrollBottomPadding,
    this.error,
  });

  final ValueChanged<String> onSelectSample;
  final double scrollBottomPadding;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return ListView(
      padding: EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.lg,
        DsSpacing.lg,
        scrollBottomPadding,
      ),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.xs,
            vertical: DsSpacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Center(child: CopilotAvatar(size: 64)),
              const SizedBox(height: DsSpacing.md),
              Text(
                '你好，我是水元素',
                textAlign: TextAlign.center,
                style: typo.headline.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: DsSpacing.xs),
              Text(
                '现场危化速查 · 战术支招 · 拍照识险',
                textAlign: TextAlign.center,
                style: typo.caption.copyWith(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  top: DsSpacing.md,
                  bottom: DsSpacing.sm,
                ),
                child: Text(
                  '常见紧急提问',
                  style: typo.caption.copyWith(
                    color: colors.textTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (var i = 0; i < _copilotSampleQuestions.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: DsSpacing.sm),
                _SampleQuestionCard(
                  text: _copilotSampleQuestions[i].$1,
                  icon: _copilotSampleQuestions[i].$2,
                  onTap: () => onSelectSample(_copilotSampleQuestions[i].$1),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(
                  top: DsSpacing.md,
                  bottom: DsSpacing.xs,
                ),
                child: Text(
                  '建议仅供参考，以指挥口令和规程为准。',
                  key: const Key('chat-disclaimer-footnote'),
                  textAlign: TextAlign.center,
                  style: typo.micro.copyWith(color: colors.textTertiary),
                ),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: DsSpacing.md),
            child: CopilotErrorBanner(message: error!),
          ),
      ],
    );
  }
}

/// 双通道语义错误横幅（告警色条 + 图标 + 文字）。
class CopilotErrorBanner extends StatelessWidget {
  const CopilotErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final alarmPair = ds.colors.statusColors(DsStatus.alarm);
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      accentStatus: DsStatus.alarm,
      borderRadius: DsRadius.borderMd,
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
      backgroundColor: alarmPair.pillBg,
      borderColor: alarmPair.fill.withValues(alpha: 0.28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              DsIcons.warning,
              size: DsSizes.iconSm,
              color: alarmPair.text,
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: ds.typography.caption.copyWith(
                color: alarmPair.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 打开旧版通用历史记录弹窗（基于 DS v3.0 [CommandSheet]）。
Future<void> showCopilotLegacyHistorySheet(
  BuildContext context,
  List<ChatMessage> history,
) {
  return showCommandSheet<void>(
    context: context,
    title: '历史通用对话',
    subtitle: '早期未按警情作用域隔离的本机记录',
    builder: (BuildContext sheetContext) {
      final ds = sheetContext.ds;
      if (history.isEmpty) {
        return const StatePlaceholder.empty(
          icon: DsIcons.opLog,
          message: '没有旧版通用对话记录',
          padding: EdgeInsets.symmetric(vertical: DsSpacing.xl),
        );
      }
      return SelectableText(
        history
            .map((m) => '${m.role == 'user' ? '提问' : '回复'}：${m.content}')
            .join('\n\n'),
        style: ds.typography.body.copyWith(
          color: ds.colors.textPrimary,
          height: 1.5,
        ),
      );
    },
    actionsBuilder: (BuildContext sheetContext) => <Widget>[
      CommandButton(
        label: '关闭',
        variant: CommandButtonVariant.secondary,
        size: CommandButtonSize.standard,
        onPressed: () => Navigator.of(sheetContext).pop(),
      ),
    ],
  );
}

class _SampleQuestionCard extends StatelessWidget {
  const _SampleQuestionCard({
    required this.text,
    required this.icon,
    required this.onTap,
  });

  final String text;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final style = ds.typography.body.copyWith(
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        );
        // 三条预设提问按最长标题统一高度，360dp / 130% 及 200% 大字号下不截断文字。
        final textWidth = max(1.0, constraints.maxWidth - 96);
        var textHeight = 0.0;
        for (final (title, _) in _copilotSampleQuestions) {
          final painter = TextPainter(
            text: TextSpan(text: title, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: textWidth);
          textHeight = max(textHeight, painter.height);
          painter.dispose();
        }
        final minCardHeight = max(
          DsSizes.touchTarget,
          textHeight + DsSpacing.sm * 2,
        );
        return ConstrainedBox(
          key: ValueKey('chat-sample-question-$text'),
          constraints: BoxConstraints(minHeight: minCardHeight),
          child: SurfaceCard(
            level: DsSurfaceLevel.outlined,
            borderRadius: DsRadius.borderMd,
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.md,
              vertical: DsSpacing.sm,
            ),
            onTap: onTap,
            child: Row(
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: DsRadius.borderSm,
                    border: Border.all(
                      color: colors.border.withValues(alpha: 0.7),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: DsSizes.iconSm + 2,
                    color: Color.lerp(
                      colors.textPrimary,
                      colors.textSecondary,
                      0.55,
                    )!,
                  ),
                ),
                const SizedBox(width: DsSpacing.md),
                Expanded(child: Text(text, style: style)),
                const SizedBox(width: DsSpacing.sm),
                Icon(
                  DsIcons.arrowUpRight,
                  size: DsSizes.iconSm,
                  color: colors.textTertiary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
