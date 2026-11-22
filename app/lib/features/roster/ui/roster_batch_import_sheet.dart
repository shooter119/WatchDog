import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design_system/design_system.dart';

/// 常见的职务/衔级词，避免整表复制时被误识别为姓名。
const Set<String> _titleWords = <String>{
  '站长',
  '副站长',
  '站长助理',
  '指导员',
  '班长',
  '副班长',
  '分队长',
  '副分队长',
  '车管',
  '文书',
  '出纳',
  '会计',
  '实习',
  '干部',
  '领导',
  '助理',
  '驾驶员',
  '战斗员',
  '通信员',
  '给养员',
  '消防员',
  '宣传员',
  '调度员',
  '管理员',
  '协查员',
  '受理员',
  '考评员',
  '信息员',
  '装备技师',
};

/// 从一段粘贴文本中解析姓名（逐行处理，保留重复项，由调用方去重）。
List<String> extractNamesFromPaste(String raw) {
  final out = <String>[];
  for (final line in raw.split('\n')) {
    out.addAll(_extractNamesFromLine(line));
  }
  return out;
}

/// 从一行粘贴内容中提取姓名：
/// - 含 Tab 视为表格行，取第一个单元格
/// - 去掉空白后整体为 2~4 字汉字 → 直接作为姓名（兼容"张 伟"这类中间带空格的）
/// - 否则按连续 2~4 字汉字切分，过滤职务词（兼容"张伟 大队长"）
List<String> _extractNamesFromLine(String line) {
  final cell = line.contains('\t') ? line.split('\t').first : line;
  final compact = cell.replaceAll(RegExp(r'\s+'), '');
  if (RegExp(r'^[\u4e00-\u9fa5]{2,4}$').hasMatch(compact)) {
    return _titleWords.contains(compact) ? const <String>[] : <String>[compact];
  }
  return RegExp(r'[\u4e00-\u9fa5]{2,4}')
      .allMatches(cell)
      .map((match) => match.group(0)!)
      .where((word) => !_titleWords.contains(word) && !_hasTitleSuffix(word))
      .toList();
}

/// 职务词常见后缀（大队长/会计助理/政治教导员…），仅在混排兜底切分时用于过滤。
bool _hasTitleSuffix(String word) => RegExp(r'[员长师理]$').hasMatch(word);

/// 弹出批量导入姓名半屏面板（Design System v3.0 [CommandSheet]）。
///
/// 支持多行粘贴、Excel 整表首列提取以及一键读取剪贴板。
Future<String?> showRosterBatchImportSheet(BuildContext context) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext routeContext) => Theme(
      data: capturedTheme,
      child: MediaQuery(
        data: capturedMediaQuery.copyWith(
          viewInsets: MediaQuery.viewInsetsOf(routeContext),
          padding: MediaQuery.paddingOf(routeContext),
          viewPadding: MediaQuery.viewPaddingOf(routeContext),
        ),
        child: const _RosterBatchImportSheet(),
      ),
    ),
  );
}

class _RosterBatchImportSheet extends StatefulWidget {
  const _RosterBatchImportSheet();

  @override
  State<_RosterBatchImportSheet> createState() => _RosterBatchImportSheetState();
}

class _RosterBatchImportSheetState extends State<_RosterBatchImportSheet> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _close([String? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return CommandSheet(
      title: '批量导入姓名',
      subtitle: '每行一个姓名，重复姓名自动跳过',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => _close(),
        ),
        CommandButton(
          label: '导入',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => _close(_input.text),
        ),
      ],
      child: _RosterBatchImportBody(controller: _input),
    );
  }
}

class _RosterBatchImportBody extends StatefulWidget {
  const _RosterBatchImportBody({required this.controller});

  final TextEditingController controller;

  @override
  State<_RosterBatchImportBody> createState() => _RosterBatchImportBodyState();
}

class _RosterBatchImportBodyState extends State<_RosterBatchImportBody> {
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('剪贴板为空')));
      return;
    }
    if (!mounted) return;
    setState(() {
      if (widget.controller.text.isEmpty) {
        widget.controller.text = text;
      } else {
        widget.controller.text = '${widget.controller.text}\n$text';
      }
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final mq = MediaQuery.of(context);
    final maxFieldHeight = math.max(
      120.0,
      math.min(240.0, mq.size.height - mq.viewInsets.bottom - 340.0),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '每行一个姓名，支持粘贴 Excel 姓名列；\n整表复制时自动取每行第一个单元格。\n重复姓名自动跳过。',
          style: typo.caption.copyWith(color: colors.textSecondary, height: 1.5),
        ),
        const SizedBox(height: DsSpacing.md),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxFieldHeight),
          child: TextField(
            controller: widget.controller,
            maxLines: null,
            minLines: 4,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              alignLabelWithHint: true,
              hintText: '张伟\n李娜\n王强',
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Align(
          alignment: Alignment.centerRight,
          child: CommandButton(
            label: '从剪贴板粘贴',
            icon: DsIcons.copyAll,
            variant: CommandButtonVariant.ghost,
            size: CommandButtonSize.standard,
            onPressed: _pasteFromClipboard,
          ),
        ),
      ],
    );
  }
}
