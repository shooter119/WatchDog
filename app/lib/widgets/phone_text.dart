import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/phone_caller.dart';
import '../theme/app_widgets.dart';

/// 具备手机号/固话自动识别、高亮与一键呼叫能力的富文本组件。
///
/// 遵循 UI Spec v2.0 规范：
/// 1. 严格继承父级文本样式与基线高度，零行高抖动；
/// 2. 识别中国大陆 11 位手机号（1[3-9]\d{9}）及带区号固话；
/// 3. 号码文本呈主题动作色并带轻量下划线，末尾紧随 14dp 电话图标；
/// 4. 支持点击即刻调起系统原生拨号盘，长按自动复制到剪贴板。
class PhoneText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final PhoneLauncher? phoneLauncher;
  final bool showCallIcon;

  const PhoneText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.phoneLauncher,
    this.showCallIcon = true,
  });

  /// 手机号与固话识别正则
  static final RegExp phoneRegex = RegExp(
    r'(?:(?:\+?86)?1[3-9]\d{9}|0\d{2,3}-?\d{7,8})',
  );

  @override
  State<PhoneText> createState() => _PhoneTextState();
}

class _PhoneTextState extends State<PhoneText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  void _copyToClipboard(String phone) {
    Clipboard.setData(ClipboardData(text: phone));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制号码: $phone'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawText = widget.text;
    final defaultStyle = DefaultTextStyle.of(context).style;
    final effectiveStyle = defaultStyle.merge(widget.style);

    final matches = PhoneText.phoneRegex.allMatches(rawText).toList();
    if (matches.isEmpty) {
      return Text(
        rawText,
        style: effectiveStyle,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        textAlign: widget.textAlign,
      );
    }

    _clearRecognizers();

    final spans = <InlineSpan>[];
    var lastIndex = 0;

    for (final match in matches) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(
          text: rawText.substring(lastIndex, match.start),
          style: effectiveStyle,
        ));
      }

      final matchedPhone = rawText.substring(match.start, match.end);
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          PhoneCaller.dial(
            context,
            matchedPhone,
            launcher: widget.phoneLauncher,
          );
        };
      _recognizers.add(recognizer);

      // 高亮电话号码段
      spans.add(TextSpan(
        text: matchedPhone,
        style: effectiveStyle.copyWith(
          color: AppColors.actionPrimary,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.actionPrimary.withValues(alpha: 0.6),
          fontWeight: FontWeight.w600,
        ),
        recognizer: recognizer,
      ));

      // 紧随轻量呼叫小图标
      if (widget.showCallIcon) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 2, right: 4),
            child: Semantics(
              button: true,
              label: '呼叫 $matchedPhone',
              child: GestureDetector(
                onTap: () {
                  PhoneCaller.dial(
                    context,
                    matchedPhone,
                    launcher: widget.phoneLauncher,
                  );
                },
                onLongPress: () => _copyToClipboard(matchedPhone),
                child: Icon(
                  Icons.phone_in_talk_outlined,
                  size: 15,
                  color: AppColors.actionPrimary,
                ),
              ),
            ),
          ),
        ));
      }

      lastIndex = match.end;
    }

    if (lastIndex < rawText.length) {
      spans.add(TextSpan(
        text: rawText.substring(lastIndex),
        style: effectiveStyle,
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
      style: effectiveStyle,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
  }
}
