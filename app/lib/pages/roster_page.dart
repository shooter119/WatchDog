import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 名单管理：消防员姓名 + 专业术语（作为语音识别热词，提升识别准确率）（规范 5.5）
class RosterPage extends StatefulWidget {
  final AppController controller;
  const RosterPage({super.key, required this.controller});

  @override
  State<RosterPage> createState() => _RosterPageState();
}

class _RosterPageState extends State<RosterPage> with SingleTickerProviderStateMixin {
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _remove(String id, bool isFirefighter, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「$label」？'),
        content: Text(isFirefighter ? '删除后无法恢复，语音识别时将不再匹配该姓名' : '删除后无法恢复，该术语将不再作为识别热词'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: [
            const Text('名单与热词'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.actionPrimary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: const Text(
                '提前录入，识别更准',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      onSubmitted: (_) => _add(),
                      decoration: InputDecoration(
                        hintText: _tab.index == 0 ? '输入消防员姓名…' : '输入专业术语…',
                        prefixIcon: Icon(_tab.index == 0 ? Icons.person_add_alt : Icons.tag),
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
            TabBar(
              controller: _tab,
              tabs: [
                Tab(
                  text: '消防员',
                  child: _TabLabel(text: '消防员', count: widget.controller.firefighters.length),
                ),
                Tab(
                  text: '专业术语',
                  child: _TabLabel(text: '专业术语', count: widget.controller.hotwords.length),
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
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 15, fontWeight: FontWeight.w600),
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
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.alarm, size: 21),
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
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
