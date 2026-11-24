import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design_system/design_system.dart';
import '../../../../services/phone_caller.dart';

/// 将 ISO-8601 原始接警时间清洗为人类易读的本地格式（无法解析时保留原文）。
String formatIncidentReceivedAt(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (!trimmed.contains('T')) return trimmed;
  final parsed = DateTime.tryParse(trimmed);
  if (parsed == null) return trimmed;
  final local = parsed.isUtc ? parsed.toLocal() : parsed;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// 警情详情基础资料分组卡片（核心通栏 → 短元数据响应式 2 列网格 → 现场态势通栏）。
class IncidentBasicFieldsCard extends StatelessWidget {
  const IncidentBasicFieldsCard({
    super.key,
    required this.basicFields,
    required this.data,
    this.phoneLauncher,
  });

  final List<MapEntry<String, String>> basicFields;
  final Map<String, dynamic> data;
  final PhoneLauncher? phoneLauncher;

  static const Set<String> _primaryWideKeys = <String>{
    'location',
    'event_summary',
  };

  static const Set<String> _compactMetaKeys = <String>{
    'original_category',
    'level',
    'specific_type',
    'received_at',
    'administrative_area',
    'place_type',
  };

  Widget _buildField(MapEntry<String, String> field) {
    final rawValue = data[field.key].toString();
    final isReceivedAt = field.key == 'received_at';
    return IncidentDetailFieldBlock(
      label: field.value,
      value: isReceivedAt ? formatIncidentReceivedAt(rawValue) : rawValue,
      tabularValue: isReceivedAt,
      phoneLauncher: phoneLauncher,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final primaryFields = <MapEntry<String, String>>[];
    final metaFields = <MapEntry<String, String>>[];
    final trailingFields = <MapEntry<String, String>>[];

    for (final field in basicFields) {
      if (_primaryWideKeys.contains(field.key)) {
        primaryFields.add(field);
      } else if (_compactMetaKeys.contains(field.key)) {
        metaFields.add(field);
      } else {
        trailingFields.add(field);
      }
    }

    final sections = <Widget>[];
    if (primaryFields.isNotEmpty) {
      sections.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var i = 0; i < primaryFields.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: DsSpacing.md),
              _buildField(primaryFields[i]),
            ],
          ],
        ),
      );
    }

    if (metaFields.isNotEmpty) {
      sections.add(
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final scaledBody = MediaQuery.textScalerOf(context).scale(14.0);
            final useTwoColumns =
                constraints.maxWidth >= 300 && scaledBody <= 16.5;
            if (!useTwoColumns || metaFields.length < 2) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (var i = 0; i < metaFields.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: DsSpacing.md),
                    _buildField(metaFields[i]),
                  ],
                ],
              );
            }
            final rows = <Widget>[];
            for (var i = 0; i < metaFields.length; i += 2) {
              if (i > 0) rows.add(const SizedBox(height: DsSpacing.md));
              final left = metaFields[i];
              final right = i + 1 < metaFields.length
                  ? metaFields[i + 1]
                  : null;
              rows.add(
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(child: _buildField(left)),
                    const SizedBox(width: DsSpacing.md),
                    Expanded(
                      child: right != null
                          ? _buildField(right)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: rows,
            );
          },
        ),
      );
    }

    if (trailingFields.isNotEmpty) {
      sections.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var i = 0; i < trailingFields.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: DsSpacing.md),
              _buildField(trailingFields[i]),
            ],
          ],
        ),
      );
    }

    return SurfaceCard(
      level: DsSurfaceLevel.outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < sections.length; i++) ...<Widget>[
            if (i > 0)
              Divider(height: DsSpacing.lg * 1.25, color: colors.border),
            sections[i],
          ],
        ],
      ),
    );
  }
}

/// 警情详情单个字段块（内嵌手机号/固话自动识别高亮与点击拨打）。
class IncidentDetailFieldBlock extends StatelessWidget {
  const IncidentDetailFieldBlock({
    super.key,
    required this.label,
    required this.value,
    this.tabularValue = false,
    this.phoneLauncher,
  });

  final String label;
  final String value;
  final bool tabularValue;
  final PhoneLauncher? phoneLauncher;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final baseStyle = tabularValue ? ds.typography.bodyTabular : ds.typography.body;
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
          style: baseStyle.copyWith(
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
    final trimmedRole = role.trim();
    final trimmedName = name.trim();
    final label = <String>[
      if (trimmedRole.isNotEmpty) trimmedRole,
      if (trimmedName.isNotEmpty && trimmedName != trimmedRole) trimmedName,
    ].join(' · ');

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
            for (var i = 0; i < items.length; i++) ...<Widget>[
              if (i > 0) Divider(height: DsSpacing.md, color: colors.border),
              Align(
                alignment: Alignment.centerLeft,
                child: _buildExpandableItem(
                  ds: ds,
                  item: items[i],
                  selectable: selectable,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildExpandableItem({
    required DsTheme ds,
    required String item,
    required bool selectable,
  }) {
    final colors = ds.colors;
    final newlineIdx = item.indexOf('\n');
    if (newlineIdx > 0 && newlineIdx < item.length - 1) {
      final header = item.substring(0, newlineIdx).trim();
      final body = item.substring(newlineIdx + 1).trim();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            header,
            style: ds.typography.captionTabular.copyWith(
              color: colors.textTertiary,
            ),
          ),
          const SizedBox(height: DsSpacing.xs),
          selectable
              ? SelectableText(
                  body,
                  style: ds.typography.body.copyWith(
                    color: colors.textPrimary,
                    height: 1.45,
                  ),
                )
              : Text(
                  body,
                  style: ds.typography.body.copyWith(
                    color: colors.textPrimary,
                    height: 1.45,
                  ),
                ),
        ],
      );
    }

    final style = ds.typography.body.copyWith(
      color: colors.textSecondary,
      height: 1.45,
    );
    return selectable
        ? SelectableText(item, style: style)
        : Text(item, style: style);
  }
}
