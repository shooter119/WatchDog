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
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s4,
                  AppSpacing.s3,
                  AppSpacing.s4,
                  AppSpacing.s2,
                ),
                child: largeText || width < 300
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('火场日志', style: AppTextStyles.h1),
                          const SizedBox(height: AppSpacing.s2),
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
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.s4,
                            AppSpacing.s3,
                            AppSpacing.s4,
                            100,
                          ),
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
          Positioned(
            right: AppSpacing.s4,
            bottom: AppSpacing.s4,
            child: _buildManualLogFab(),
          ),
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
        shape: CircleBorder(side: BorderSide(color: AppColors.border)),
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
      height: AppSpacing.s10,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
        children: [
          for (final c in ['全部', ...NoteCategory.all])
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.s2),
              child: FilterChip(
                label: Text(c),
                selected: _filter == c,
                onSelected: (_) => setState(() => _filter = c),
                showCheckmark: false,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3,
                  vertical: AppSpacing.s2,
                ),
                labelPadding: EdgeInsets.zero,
                selectedColor: AppColors.actionPrimary,
                backgroundColor: AppColors.surface,
                surfaceTintColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                labelStyle: AppTextStyles.label.copyWith(
                  color: _filter == c
                      ? AppColors.onPrimary
                      : AppColors.textPrimary,
                ),
                side: BorderSide(
                  color: _filter == c
                      ? AppColors.actionPrimary
                      : AppColors.border,
                ),
              ),
            ),
          const SizedBox(width: AppSpacing.s4),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s8),
              child: AppEmptyState(
                icon: Icons.note_alt_outlined,
                title: '还没有日志记录',
                hint: widget.controller.requiresIncident
                    ? '请先选择或新建警情，再记录火场日志'
                    : '按住底部语音按钮说话，非报数内容将自动记入日志',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(Note? note) async {
    if (note == null && widget.controller.requiresIncident) {
      widget.controller.requestIncidentSelection();
      return;
    }
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
                            AppSpacing.s5)
                        .clamp(160.0, double.infinity)
                        .toDouble(),
              ),
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(AppSpacing.s5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      note == null ? '手动记录' : '编辑日志',
                      style: AppTextStyles.h2.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: AppSpacing.s2),
                      Text(
                        _fmtFullTime(note.createdAt),
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.s4),
                    TextField(
                      controller: controller,
                      maxLines: 4,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        hintText: '记录此刻发生了什么…',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    Wrap(
                      spacing: AppSpacing.s2,
                      runSpacing: AppSpacing.s2,
                      children: [
                        for (final c in NoteCategory.all)
                          ChoiceChip(
                            label: Text(c),
                            selected: category == c,
                            onSelected: (_) => setSheet(() => category = c),
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.s3,
                              vertical: AppSpacing.s2,
                            ),
                            labelPadding: EdgeInsets.zero,
                            selectedColor: AppColors.actionPrimary,
                            backgroundColor: AppColors.surface,
                            surfaceTintColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                            ),
                            side: BorderSide(
                              color: category == c
                                  ? AppColors.actionPrimary
                                  : AppColors.border,
                            ),
                            labelStyle: AppTextStyles.label.copyWith(
                              color: category == c
                                  ? AppColors.onPrimary
                                  : AppColors.textPrimary,
                            ),
                            showCheckmark: false,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s5),
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
                      const SizedBox(height: AppSpacing.s2),
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
  static Color get red => AppColors.alarm;
  static Color get blue => AppColors.noteInfo;
  static Color get orange => AppColors.noteWater;
  static Color get gray => AppColors.noteNeutral;

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
            width: AppSpacing.s5,
            child: Column(
              children: [
                Container(
                  width: AppSpacing.s3,
                  height: AppSpacing.s3,
                  margin: const EdgeInsets.only(top: AppSpacing.s4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    border: Border.all(color: AppColors.surface, width: 2),
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
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.s3),
              child: AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s4,
                  vertical: AppSpacing.s3,
                ),
                onTap: onTap,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.s2,
                            vertical: AppSpacing.s1,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            note.category,
                            style: AppTextStyles.caption.copyWith(
                              color: color,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s2),
                        Text(
                          _time,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(width: AppSpacing.s2),
                        Flexible(
                          child: Text(
                            note.author.isEmpty ? '匿名' : note.author,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textTertiary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      note.text,
                      style: AppTextStyles.bodyMd.copyWith(
                        color: AppColors.textPrimary,
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
