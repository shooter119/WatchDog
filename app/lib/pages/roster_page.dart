import 'package:flutter/material.dart';

import '../state/app_controller.dart';

/// 名单管理：消防员姓名 + 专业术语（作为语音识别热词，提升识别准确率）
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

  Future<void> _remove(String id, bool isFirefighter) async {
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
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Text('名单与热词', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(width: 10),
                const Icon(Icons.help_outline, size: 16, color: Colors.grey),
                Expanded(
                  child: Text(
                    '提前录入，识别更准',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _add(),
                    decoration: InputDecoration(
                      hintText: _tab.index == 0 ? '输入消防员姓名…' : '输入专业术语…',
                      hintStyle: TextStyle(color: Colors.grey.shade600),
                      filled: true,
                      fillColor: const Color(0xFF1E2126),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('添加'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: '消防员'),
              Tab(text: '专业术语'),
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
    );
  }

  Widget _buildList({required bool isFirefighter}) {
    final items = isFirefighter
        ? widget.controller.firefighters
        : widget.controller.hotwords;
    if (items.isEmpty) {
      return Center(
        child: Text(
          isFirefighter ? '暂无消防员，先添加几人吧' : '暂无术语，例如：空气呼吸器、水枪阵地、破拆工具',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final String id = (item as dynamic).id;
        final String label = isFirefighter
            ? (item as dynamic).name
            : (item as dynamic).word;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2126),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                isFirefighter ? Icons.person : Icons.tag,
                size: 18,
                color: isFirefighter ? Colors.lightBlueAccent : Colors.purpleAccent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 16)),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                onPressed: () => _remove(id, isFirefighter),
              ),
            ],
          ),
        );
      },
    );
  }
}
