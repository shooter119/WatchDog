import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 名单管理：消防员姓名 + 专业术语（作为语音识别热词，提升识别准确率）（规范 5.5）
class RosterPage extends StatefulWidget {
  final AppController controller;
  const RosterPage({super.key, required this.controller});

  @override
  State<RosterPage> createState() => _RosterPageState();
}

class _RosterPageState extends State<RosterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.loadRoster();
  }

  @override
  void dispose() {
    _tab.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _input.clear());
    try {
      if (_tab.index == 0) {
        await widget.controller.api!.addFirefighter(text);
      } else {
        await widget.controller.api!.addHotword(text);
      }
      await widget.controller.loadRoster();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 批量导入姓名：弹窗粘贴（支持 Excel 姓名列/整表），切分去重后逐条入库
  Future<void> _batchImport() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _BatchImportDialog(),
    );
    if (raw == null || raw.trim().isEmpty) return;

    final existing = widget.controller.firefighters.map((f) => f.name).toSet();
    final seen = <String>{};
    var dup = 0;
    for (final name in extractNamesFromPaste(raw)) {
      if (existing.contains(name) || !seen.add(name)) {
        dup++;
      }
    }
    final toAdd = seen.toList();
    if (toAdd.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('未发现可导入的姓名（已有 $dup 个重复）')));
      }
      return;
    }

    if (!mounted) return;
    final api = widget.controller.api!;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('正在导入姓名…')),
          ],
        ),
      ),
    );
    var added = 0;
    var failed = 0;
    for (final name in toAdd) {
      try {
        if (await api.addFirefighter(name)) {
          added++;
        } else {
          dup++;
        }
      } catch (_) {
        failed++;
      }
    }
    await widget.controller.loadRoster();
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '导入完成：新增 $added 人，跳过重复 $dup 个'
            '${failed > 0 ? '，失败 $failed 个（可重试）' : ''}',
          ),
        ),
      );
    }
  }

  Future<void> _remove(String id, bool isFirefighter, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「$label」？'),
        content: Text(
          isFirefighter ? '删除后无法恢复，语音识别时将不再匹配该姓名' : '删除后无法恢复，该术语将不再作为识别热词',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.alarm),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (isFirefighter) {
        await widget.controller.api!.removeFirefighter(id);
      } else {
        await widget.controller.api!.removeHotword(id);
      }
      await widget.controller.loadRoster();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('名单与热词'),
        actions: [
          TextButton.icon(
            onPressed: _batchImport,
            icon: const Icon(Icons.paste, size: 18),
            label: const Text('批量导入'),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => SafeArea(
          top: false,
          child: Column(
            children: [
              AnimatedBuilder(
                animation: _tab,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          onSubmitted: (_) => _add(),
                          decoration: InputDecoration(
                            hintText: _tab.index == 0 ? '输入消防员姓名…' : '输入专业术语…',
                            prefixIcon: Icon(
                              _tab.index == 0
                                  ? Icons.person_add_alt
                                  : Icons.tag,
                            ),
                          ),
                          textInputAction: TextInputAction.done,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _add,
                          icon: const Icon(Icons.add),
                          label: const Text('添加'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              TabBar(
                controller: _tab,
                tabs: [
                  Tab(
                    child: _TabLabel(
                      text: '消防员',
                      count: widget.controller.firefighters.length,
                    ),
                  ),
                  Tab(
                    child: _TabLabel(
                      text: '专业术语',
                      count: widget.controller.hotwords.length,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tab,
                  children: [
                    _buildList(isFirefighter: true),
                    _buildList(isFirefighter: false),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList({required bool isFirefighter}) {
    final items = isFirefighter
        ? widget.controller.firefighters
        : widget.controller.hotwords;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(
                isFirefighter ? Icons.group_outlined : Icons.interpreter_mode,
                size: 40,
                color: AppColors.textTertiary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              isFirefighter ? '暂无消防员，先添加几人吧' : '暂无专业术语',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            if (!isFirefighter)
              const Text(
                '例如：空气呼吸器、水枪阵地、破拆工具',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12.5),
              ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final String id = (item as dynamic).id;
        final String label = isFirefighter
            ? (item as dynamic).name
            : (item as dynamic).word;
        final String source = (item as dynamic).source;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceSubtle,
                ),
                child: Icon(
                  isFirefighter ? Icons.person_outline : Icons.tag,
                  size: 19,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (source != 'builtin')
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.alarm,
                    size: 21,
                  ),
                  onPressed: () => _remove(id, isFirefighter, label),
                  tooltip: '删除',
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TabLabel extends StatelessWidget {
  final String text;
  final int count;

  const _TabLabel({required this.text, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(text),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: AppColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 批量导入弹窗：多行粘贴，支持一键读取剪贴板
class _BatchImportDialog extends StatefulWidget {
  const _BatchImportDialog();

  @override
  State<_BatchImportDialog> createState() => _BatchImportDialogState();
}

class _BatchImportDialogState extends State<_BatchImportDialog> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('剪贴板为空')));
      }
      return;
    }
    if (mounted) {
      setState(() {
        if (_input.text.isEmpty) {
          _input.text = text;
        } else {
          _input.text = '${_input.text}\n$text';
        }
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxFieldHeight = math.max(
      120.0,
      math.min(260.0, mq.size.height - mq.viewInsets.bottom - 300.0),
    );
    return AlertDialog(
      title: const Text('批量导入姓名'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '每行一个姓名，支持粘贴 Excel 姓名列；\n整表复制时自动取每行第一个单元格。\n重复姓名自动跳过。',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxFieldHeight),
            child: TextField(
              controller: _input,
              maxLines: null,
              minLines: 4,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(alignLabelWithHint: true),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.copy_all, size: 18),
              label: const Text('从剪贴板粘贴'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _input.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// 常见的职务/衔级词，避免整表复制时被误识别为姓名
const _titleWords = <String>{
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

/// 从一段粘贴文本中解析姓名（逐行处理，保留重复项，由调用方去重）
List<String> extractNamesFromPaste(String raw) {
  final out = <String>[];
  for (final line in raw.split('\n')) {
    out.addAll(_extractNames(line));
  }
  return out;
}

/// 从一行粘贴内容中提取姓名：
/// - 含 Tab 视为表格行，取第一个单元格
/// - 去掉空白后整体为 2~4 字汉字 → 直接作为姓名（兼容"李 翔"这类中间带空格的）
/// - 否则按连续 2~4 字汉字切分，过滤职务词（兼容"盛承华 大队长"）
List<String> _extractNames(String line) {
  final cell = line.contains('\t') ? line.split('\t').first : line;
  final compact = cell.replaceAll(RegExp(r'\s+'), '');
  if (RegExp(r'^[\u4e00-\u9fa5]{2,4}$').hasMatch(compact)) {
    return _titleWords.contains(compact) ? const [] : [compact];
  }
  return RegExp(r'[\u4e00-\u9fa5]{2,4}')
      .allMatches(cell)
      .map((m) => m.group(0)!)
      .where((w) => !_titleWords.contains(w) && !_hasTitleSuffix(w))
      .toList();
}

/// 职务词常见后缀（大队长/会计助理/政治教导员…），仅在混排兜底切分时用于过滤
bool _hasTitleSuffix(String w) => RegExp(r'[员长师理]$').hasMatch(w);
