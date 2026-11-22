import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../design_system/design_system.dart';
import '../data/models/chat_message.dart';
import '../state/copilot_reply_parser.dart';

/// 水元素辅助头像（直接复用 Design System 统一纯矢量 `AssistantAvatar`）。
class CopilotAvatar extends StatelessWidget {
  const CopilotAvatar({super.key, this.size = 56, this.margin});

  final double size;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return AssistantAvatar(size: size, margin: margin);
  }
}

/// 流式首个字符到达前的思考态指示行。
class CopilotThinkingBubble extends StatelessWidget {
  const CopilotThinkingBubble({super.key});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DsSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const CopilotAvatar(
            size: 32,
            margin: EdgeInsets.only(right: DsSpacing.sm),
          ),
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              value: disableAnimations ? 0.72 : null,
              strokeWidth: 2.5,
              color: colors.brandText,
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          Flexible(
            child: Text(
              '水元素思考中…',
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 智能辅助消息气泡（用户提问 / 水元素 Markdown 回复 + 最多 3 个独立追问胶囊 + 纯净复制）。
class CopilotMessageBubble extends StatelessWidget {
  const CopilotMessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.canTapFollowUp = true,
    this.onFollowUpTap,
    this.onCopy,
  });

  final ChatMessage message;
  final bool isStreaming;
  final bool canTapFollowUp;
  final ValueChanged<String>? onFollowUpTap;
  final ValueChanged<String>? onCopy;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final isUser = message.isUser;
    final parsed = isUser
        ? ChatReplyParts(body: message.content, followUps: const [])
        : parseAssistantReply(message.content, streaming: isStreaming);
    final body = parsed.body;
    final followUps = isStreaming ? const <String>[] : parsed.followUps;
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final timeText =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!isUser)
            const Padding(
              padding: EdgeInsets.only(top: DsSpacing.xs, right: DsSpacing.sm),
              child: CopilotAvatar(size: 32),
            ),
          Flexible(
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: <Widget>[
                SurfaceCard(
                  level: DsSurfaceLevel.outlined,
                  borderRadius: DsRadius.borderMd,
                  padding: const EdgeInsets.symmetric(
                    horizontal: DsSpacing.lg,
                    vertical: DsSpacing.md,
                  ),
                  backgroundColor: isUser ? colors.brand : colors.surface,
                  borderColor: isUser ? colors.brand : colors.border,
                  child: isUser
                      ? Text(
                          message.content,
                          style: typo.body.copyWith(
                            height: 1.5,
                            color: colors.onBrand,
                          ),
                        )
                      : MarkdownBody(
                          data: body,
                          styleSheet: _buildMarkdownStyle(context, ds),
                        ),
                ),
                if (!isStreaming &&
                    followUps.isNotEmpty &&
                    onFollowUpTap != null)
                  Padding(
                    padding: const EdgeInsets.only(top: DsSpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (var i = 0; i < followUps.length; i++)
                          Padding(
                            padding: EdgeInsets.only(
                              top: i == 0 ? 0 : DsSpacing.sm,
                            ),
                            child: _FollowUpCapsule(
                              key: ValueKey('chat-followup-${message.id}-$i'),
                              label: parsed.isLegacy && followUps.length == 1
                                  ? '我想进一步确认：${followUps[i]}'
                                  : followUps[i],
                              onTap: canTapFollowUp
                                  ? () => onFollowUpTap!(followUps[i])
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(
                    top: DsSpacing.xs,
                    left: DsSpacing.xs,
                    right: DsSpacing.xs,
                  ),
                  child: Row(
                    mainAxisAlignment: isUser
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      if (!isUser) ...<Widget>[
                        Expanded(
                          child: Text(
                            '仅供参考，以指挥口令和规程为准',
                            style: typo.micro.copyWith(
                              color: colors.textTertiary,
                            ),
                          ),
                        ),
                        const SizedBox(width: DsSpacing.sm),
                      ],
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (!isStreaming) ...<Widget>[
                            IconButton(
                              key: ValueKey('chat-copy-${message.id}'),
                              onPressed: onCopy == null || body.trim().isEmpty
                                  ? null
                                  : () => onCopy!(body),
                              icon: const Icon(DsIcons.copy),
                              tooltip: '复制',
                              iconSize: DsSizes.iconMd,
                              constraints: const BoxConstraints(
                                minWidth: DsSizes.touchTarget,
                                minHeight: DsSizes.touchTarget,
                              ),
                              padding: const EdgeInsets.all(DsSpacing.sm),
                              color: colors.textTertiary,
                            ),
                            const SizedBox(width: DsSpacing.xs),
                          ],
                          Text(
                            timeText,
                            style: typo.captionTabular.copyWith(
                              color: colors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  MarkdownStyleSheet _buildMarkdownStyle(BuildContext context, DsTheme ds) {
    final colors = ds.colors;
    final typo = ds.typography;
    final bodyStyle = typo.body.copyWith(height: 1.5, color: colors.textPrimary);
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: bodyStyle,
      h1: typo.headline.copyWith(
        height: 1.4,
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
      ),
      h2: typo.title.copyWith(
        height: 1.45,
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
      ),
      h3: bodyStyle.copyWith(fontWeight: FontWeight.w700),
      h4: bodyStyle.copyWith(fontWeight: FontWeight.w700),
      h5: typo.caption.copyWith(
        height: 1.5,
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
      ),
      h6: typo.caption.copyWith(
        height: 1.5,
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
      ),
      strong: bodyStyle.copyWith(fontWeight: FontWeight.w700),
      em: bodyStyle.copyWith(fontStyle: FontStyle.italic),
      del: bodyStyle.copyWith(
        color: colors.textTertiary,
        decoration: TextDecoration.lineThrough,
      ),
      a: bodyStyle.copyWith(
        color: colors.brandText,
        decoration: TextDecoration.underline,
        decorationColor: colors.brandText,
      ),
      tableHead: typo.caption.copyWith(
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
      ),
      tableBody: typo.caption.copyWith(color: colors.textPrimary),
      tableBorder: TableBorder.all(color: colors.border, width: 1),
      blockquote: typo.body.copyWith(height: 1.5, color: colors.textSecondary),
      blockquoteDecoration: BoxDecoration(
        color: colors.surfaceMuted,
        border: Border(left: BorderSide(color: colors.border, width: 3)),
      ),
      listBullet: typo.body.copyWith(height: 1.5, color: colors.textSecondary),
      code: typo.caption.copyWith(
        fontFamily: 'Menlo',
        color: colors.textPrimary,
        backgroundColor: colors.surfaceMuted,
      ),
      codeblockDecoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: DsRadius.borderSm,
      ),
      codeblockPadding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.md,
        vertical: DsSpacing.sm,
      ),
    );
  }
}

class _FollowUpCapsule extends StatelessWidget {
  const _FollowUpCapsule({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Material(
      color: colors.brand.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: DsRadius.borderPill,
        side: BorderSide(color: colors.brand.withValues(alpha: 0.28), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: DsRadius.borderPill,
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.md,
              vertical: DsSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  DsIcons.arrowUpRight,
                  size: DsSizes.iconSm,
                  color: colors.brandText,
                ),
                const SizedBox(width: DsSpacing.sm),
                Flexible(
                  child: Text(
                    label,
                    style: ds.typography.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
