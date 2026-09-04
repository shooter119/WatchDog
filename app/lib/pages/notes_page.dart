import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 火场日志页：单列时间线瀑布流，展示消防员用语音/手动记录的火场随手记，
/// 每条自动带时间戳与分类色条，可筛选分类、编辑、删除，供事后复盘。
class NotesPage extends StatefulWidget {
  final AppController controller;

  const NotesPage({super.key, required this.controller});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String _filter = '全部';

  @override
  Widget build(BuildContext context) {
    final notes = widget.controller.notes;
    final filtered = _filter == '全部'
        ? notes
        : notes.where((n) => n.category == _filter).toList();
    final width = MediaQuery.sizeOf(context).width;
    final largeText = MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    return SafeArea(
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: largeText || width < 300
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('火场日志', style: AppTextStyles.h1),
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _buildConnectionStatus(),
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('火场日志', style: AppTextStyles.h1),
                          const Spacer(),
                          _buildConnectionStatus(),
                        ],
                      ),
              ),
              _buildFilterChips(),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: widget.controller.refreshNow,
                  child: filtered.isEmpty
                      ? _buildEmpty()
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                          itemCount: filtered.length,
                          itemBuilder: (context, i) => _TimelineNoteCard(
                            note: filtered[i],
                            isLast: i == filtered.length - 1,
                            onTap: () => _openEditor(filtered[i]),
                          ),
                        ),
                ),
              ),
            ],
          ),
          Positioned(right: 16, bottom: 16, child: _buildManualLogFab()),
        ],
      ),
    );
  }

  Widget _buildManualLogFab() {
    return Semantics(
      button: true,
      label: '手动记录日志',
      child: FloatingActionButton(
        key: const Key('notes-manual-log-fab'),
        onPressed: () => _openEditor(null),
        tooltip: '手动记录日志',
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.voice,
        elevation: 3,
        focusElevation: 4,
        hoverElevation: 4,
        highlightElevation: 2,
        shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
        child: const Icon(Icons.add_rounded, size: 30),
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return ConnectionStatus(
      connected: !widget.controller.connectionLost,
      syncing: widget.controller.syncing,
      syncError: widget.controller.syncError,
      onRetry: widget.controller.refreshNow,
    );
  }

  /// 分类筛选 chips（全部 + 6 类）
  Widget _buildFilterChips() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final c in ['全部', ...NoteCategory.all])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(c),
                selected: _filter == c,
                onSelected: (_) => setState(() => _filter = c),
                showCheckmark: false,
                selectedColor: NoteColor.of(
                  c == '全部' ? null : c,
                ).withValues(alpha: 0.22),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: _filter == c ? FontWeight.w800 : FontWeight.w600,
                  color: _filter == c
                      ? NoteColor.of(c == '全部' ? null : c)
                      : AppColors.textSecondary,
                ),
                side: BorderSide(
                  color: _filter == c
                      ? NoteColor.of(c == '全部' ? null : c)
                      : AppColors.border,
                ),
                backgroundColor: AppColors.surface,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          Icons.note_alt_outlined,
          size: 64,
          color: AppColors.textTertiary.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            '还没有日志记录',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            '按住底部语音按钮说话，非报数内容将自动记入日志\n也可点击右下角加号手动记录',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(Note? note) async {
    final controller = TextEditingController(text: note?.text ?? '');
    var category = note?.category ?? NoteCategory.other;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    (MediaQuery.sizeOf(ctx).height -
                            MediaQuery.of(ctx).viewInsets.bottom -
                            20)
                        .clamp(160.0, double.infinity)
                        .toDouble(),
              ),
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      note == null ? '手动记录' : '编辑日志',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _fmtFullTime(note.createdAt),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      maxLines: 4,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        hintText: '记录此刻发生了什么…',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in NoteCategory.all)
                          ChoiceChip(
                            label: Text(c),
                            selected: category == c,
                            onSelected: (_) => setSheet(() => category = c),
                            selectedColor: NoteColor.of(
                              c,
                            ).withValues(alpha: 0.22),
                            labelStyle: TextStyle(
                              fontSize: 13,
                              fontWeight: category == c
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: category == c
                                  ? NoteColor.of(c)
                                  : AppColors.textSecondary,
                            ),
                            showCheckmark: false,
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: () {
                          final text = controller.text.trim();
                          if (text.isEmpty) return;
                          Navigator.pop(ctx, {
                            'text': text,
                            'category': category,
                          });
                        },
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(note == null ? '保存到日志' : '保存修改'),
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => Navigator.pop(ctx, {'delete': true}),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('删除这条日志'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.alarm,
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    } else {
      controller.dispose();
    }
    if (result == null || !mounted) return;
    if (result['delete'] == true) {
      await _delete(note!);
      return;
    }
    final text = result['text'] as String;
    final cat = result['category'] as String;
    try {
      if (note == null) {
        await widget.controller.addNote(text, category: cat);
        if (mounted) _toast('已记入日志');
      } else {
        await widget.controller.updateNote(note.id, text: text, category: cat);
        if (mounted) _toast('已保存修改');
      }
    } catch (e) {
      if (mounted) _toast('保存失败：$e', error: true);
    }
  }

  Future<void> _delete(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除日志'),
        content: Text('确认删除这条日志？\n${note.text}'),
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
      await widget.controller.deleteNote(note.id);
      if (mounted) _toast('已删除');
    } catch (e) {
      if (mounted) _toast('删除失败：$e', error: true);
    }
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? AppColors.alarm : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  static String _fmtFullTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

/// 分类 → 颜色映射（收敛为消防高可视四色：红=异常/危险，蓝=部署/搜救/撤离等作战信息，
/// 橙=出水/注意，灰=其他；不随分类数量增加新装饰色）
class NoteColor {
  NoteColor._();
  static const Color red = AppColors.alarm;
  static const Color blue = AppColors.noteInfo;
  static const Color orange = AppColors.noteWater;
  static const Color gray = AppColors.noteNeutral;

  static Color of(String? category) => switch (category) {
    NoteCategory.abnormal => red,
    NoteCategory.deploy || NoteCategory.rescue || NoteCategory.withdraw => blue,
    NoteCategory.water => orange,
    _ => gray,
  };
}

/// 时间线卡片：左侧时间轴圆点 + 竖线，右侧卡片（分类色条 + 时间 + 内容）
class _TimelineNoteCard extends StatelessWidget {
  final Note note;
  final bool isLast;
  final VoidCallback onTap;

  const _TimelineNoteCard({
    required this.note,
    required this.isLast,
    required this.onTap,
  });

  /// 编辑过显示「改」并改用 updatedAt 时间；非今天显示日期前缀
  String get _time {
    final edited = note.updatedAt > note.createdAt;
    final ts = edited ? note.updatedAt : note.createdAt;
    final day = _isToday(ts) ? '' : '${_fmtDay(ts)} ';
    return '${edited ? '改 ' : ''}$day${_fmtTime(ts)}';
  }

  static String _fmtTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = NoteColor.of(note.category);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(top: 18),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    border: Border.all(color: AppColors.heroOnDark, width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: color.withValues(alpha: 0.25),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: AppCard(
                padding: const EdgeInsets.all(12),
                onTap: onTap,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            note.category,
                            style: TextStyle(
                              color: color,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _time,
                          style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 发布者：实名用户显示姓名，未实名显示匿名（小字）
                    Text(
                      note.author.isEmpty ? '匿名' : note.author,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      note.text,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _isToday(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  static String _fmtDay(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.month}-${two(d.day)}';
  }
}
