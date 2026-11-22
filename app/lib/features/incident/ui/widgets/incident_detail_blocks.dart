import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design_system/design_system.dart';
import '../../../../services/phone_caller.dart';

/// 警情详情单个字段块（内嵌手机号/固话自动识别高亮与点击拨打）。
class IncidentDetailFieldBlock extends StatelessWidget {
  const IncidentDetailFieldBlock({
    super.key,
    required this.label,
    required this.value,
    this.phoneLauncher,
  });

  final String label;
  final String value;
  final PhoneLauncher? phoneLauncher;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: ds.typography.caption.copyWith(
            color: ds.colors.textSecondary,
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        _InlinePhoneText(
          text: value,
          style: ds.typography.body.copyWith(
            color: ds.colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          phoneLauncher: phoneLauncher,
        ),
      ],
    );
  }
}

class _InlinePhoneText extends StatefulWidget {
  const _InlinePhoneText({
    required this.text,
    required this.style,
    this.phoneLauncher,
  });

  final String text;
  final TextStyle style;
  final PhoneLauncher? phoneLauncher;

  static final RegExp phoneRegex = RegExp(
    r'(?:(?:\+?86)?1[3-9]\d{9}|0\d{2,3}-?\d{7,8})',
  );

  @override
  State<_InlinePhoneText> createState() => _InlinePhoneTextState();
}

class _InlinePhoneTextState extends State<_InlinePhoneText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final matches = _InlinePhoneText.phoneRegex.allMatches(widget.text).toList();
    if (matches.isEmpty) {
      return Text(widget.text, style: widget.style);
    }

    final colors = context.ds.colors;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(
          TextSpan(
            text: widget.text.substring(cursor, m.start),
            style: widget.style,
          ),
        );
      }
      final phone = widget.text.substring(m.start, m.end);
      final recognizer = TapGestureRecognizer()
        ..onTap = () => PhoneCaller.dial(
          context,
          phone,
          launcher: widget.phoneLauncher,
        );
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: phone,
          style: widget.style.copyWith(
            color: colors.brandText,
            decoration: TextDecoration.underline,
            decorationColor: colors.brandText.withValues(alpha: 0.6),
          ),
          recognizer: recognizer,
        ),
      );
      cursor = m.end;
    }
    if (cursor < widget.text.length) {
      spans.add(
        TextSpan(text: widget.text.substring(cursor), style: widget.style),
      );
    }
    return Text.rich(TextSpan(children: spans));
  }
}

/// 岗位人员与联系方式单行组件（完整号码校验、点击拨打、长按复制）。
class IncidentContactItemRow extends StatelessWidget {
  const IncidentContactItemRow({
    super.key,
    required this.role,
    required this.name,
    required this.phone,
    required this.onCall,
  });

  final String role;
  final String name;
  final String phone;
  final ValueChanged<String> onCall;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final normalized = phone.trim();
    final canDial = PhoneCaller.isValidPhoneNumber(normalized);
    final label = <String>[
      role.trim(),
      name.trim(),
    ].where((String s) => s.isNotEmpty).join(' · ');

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
        child: Row(
          children: <Widget>[
            Expanded(
              child: InkWell(
                borderRadius: DsRadius.borderSm,
                onTap: canDial ? () => onCall(normalized) : null,
                onLongPress: normalized.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: normalized));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已复制号码: $normalized')),
                        );
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (label.isNotEmpty)
                        Text(
                          label,
                          style: ds.typography.body.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (normalized.isNotEmpty)
                        Text(
                          normalized,
                          style: ds.typography.bodyTabular.copyWith(
                            color: canDial
                                ? colors.brandText
                                : colors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (canDial) ...<Widget>[
              const SizedBox(width: DsSpacing.sm),
              CommandButton(
                label: '拨打',
                icon: DsIcons.phone,
                variant: CommandButtonVariant.secondary,
                size: CommandButtonSize.standard,
                onPressed: () => onCall(normalized),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 警情详情可折叠分组列表卡片（用于风险/车辆/通信/录像语音/导入历史）。
class IncidentExpandableListCard extends StatelessWidget {
  const IncidentExpandableListCard({
    super.key,
    required this.title,
    required this.items,
    this.subtitle,
    this.selectable = false,
  });

  final String title;
  final String? subtitle;
  final List<String> items;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: DsSpacing.md),
          title: Text(
            title,
            style: ds.typography.title.copyWith(color: colors.textPrimary),
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle!,
                  style: ds.typography.caption.copyWith(
                    color: colors.textTertiary,
                  ),
                )
              : null,
          children: <Widget>[
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: selectable
                      ? SelectableText(
                          item,
                          style: ds.typography.body.copyWith(
                            color: colors.textSecondary,
                          ),
                        )
                      : Text(
                          item,
                          style: ds.typography.body.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
