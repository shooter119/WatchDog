import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/firefighter.dart';
import '../data/models/hotword.dart';
import 'roster_batch_import_sheet.dart';

/// 名单与热词页面的数据与操作网关。
///
/// 由外壳/协调层实现，避免 `features/roster/ui/` 逆向依赖旧状态层或跨 Feature 依赖。
abstract class RosterPageGateway {
  /// 当名单、热词或待审人数变化时发出通知（可选）。
  Listenable? get changes => null;

  List<Firefighter> get firefighters;
  List<Hotword> get hotwords;
  bool get canReviewMembers;
  int get pendingMemberCount;

  Future<void> loadRoster();
  Future<void> refreshPendingMembersCount();
  Future<bool> addFirefighter(String name);
  Future<void> removeFirefighter(String id);
  Future<void> addHotword(String word);
  Future<void> removeHotword(String id);
}

/// 名单与热词管理页（Design System v3.0）。
///
/// 承接消防员姓名与专业术语双 Tab、单条新增、批量粘贴导入、入队审批提示入口
/// 与 [CommandSheet] 删除二次确认。
class RosterPage extends StatefulWidget {
  const RosterPage({
    super.key,
    required this.gateway,
    this.onOpenMemberReview,
    this.isOffline = false,
  });

  final RosterPageGateway gateway;
  final Future<void> Function(BuildContext context)? onOpenMemberReview;
  final bool isOffline;

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
    widget.gateway.changes?.addListener(_onGatewayChanged);
    _tab.addListener(_onTabChanged);
    unawaited(_initialLoad());
  }

  @override
  void didUpdateWidget(covariant RosterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway) {
      oldWidget.gateway.changes?.removeListener(_onGatewayChanged);
      widget.gateway.changes?.addListener(_onGatewayChanged);
      unawaited(_initialLoad());
    }
  }

  @override
  void dispose() {
    widget.gateway.changes?.removeListener(_onGatewayChanged);
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _initialLoad() async {
    try {
      await widget.gateway.loadRoster();
    } catch (_) {}
    try {
      await widget.gateway.refreshPendingMembersCount();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _onGatewayChanged() {
    if (mounted) setState(() {});
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _input.clear());
    try {
      if (_tab.index == 0) {
        await widget.gateway.addFirefighter(text);
      } else {
        await widget.gateway.addHotword(text);
      }
      await widget.gateway.loadRoster();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _batchImport() async {
    final raw = await showRosterBatchImportSheet(context);
    if (raw == null || raw.trim().isEmpty) return;

    final existing = widget.gateway.firefighters.map((f) => f.name).toSet();
    final seen = <String>{};
    var dup = 0;
    for (final name in extractNamesFromPaste(raw)) {
      if (existing.contains(name) || !seen.add(name)) dup++;
    }
    final toAdd = seen.toList();
    if (toAdd.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('未发现可导入的姓名（已有 $dup 个重复）')),
        );
      }
      return;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: <Widget>[
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: DsSpacing.lg),
            Expanded(child: Text('正在导入姓名…')),
          ],
        ),
      ),
    );
    var added = 0;
    var failed = 0;
    for (final name in toAdd) {
      try {
        if (await widget.gateway.addFirefighter(name)) {
          added++;
        } else {
          dup++;
        }
      } catch (_) {
        failed++;
      }
    }
    try {
      await widget.gateway.loadRoster();
    } catch (_) {}
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      setState(() {});
      final suffix = failed > 0 ? '，失败 $failed 个（可重试）' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入完成：新增 $added 人，跳过重复 $dup 个$suffix')),
      );
    }
  }

  Future<void> _remove(String id, bool isFirefighter, String label) async {
    final confirmed = await showCommandSheet<bool>(
      context: context,
      title: '删除「$label」？',
      builder: (BuildContext sheetContext) => Text(
        isFirefighter ? '删除后无法恢复，语音识别时将不再匹配该姓名' : '删除后无法恢复，该术语将不再作为识别热词',
        style: sheetContext.ds.typography.body.copyWith(
          color: sheetContext.ds.colors.textSecondary,
        ),
      ),
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          label: '删除',
          variant: CommandButtonVariant.danger,
          size: CommandButtonSize.large,
          requireConfirmation: false,
          onPressed: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    );
    if (confirmed != true) return;
    try {
      if (isFirefighter) {
        await widget.gateway.removeFirefighter(id);
      } else {
        await widget.gateway.removeHotword(id);
      }
      await widget.gateway.loadRoster();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;

    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(
        title: const Text('名单与热词'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: DsSpacing.xs),
            child: TextButton.icon(
              onPressed: _batchImport,
              style: TextButton.styleFrom(
                minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
                padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md),
                foregroundColor: colors.brandText,
                textStyle: ds.typography.body.copyWith(fontWeight: FontWeight.w600),
              ),
              icon: const Icon(Icons.paste_rounded, size: DsSizes.iconMd),
              label: const Text('批量导入'),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.pageMargin,
              DsSpacing.md,
              DsSpacing.pageMargin,
              DsSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _add(),
                    decoration: InputDecoration(
                      hintText: _tab.index == 0 ? '输入消防员姓名…' : '输入专业术语…',
                      prefixIcon: Icon(
                        _tab.index == 0
                            ? Icons.person_add_outlined
                            : Icons.tag_rounded,
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                  ),
                ),
                const SizedBox(width: DsSpacing.sm),
                CommandButton(
                  label: '添加',
                  icon: Icons.add_rounded,
                  variant: CommandButtonVariant.primary,
                  size: CommandButtonSize.standard,
                  onPressed: _add,
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tab,
            tabs: <Widget>[
              Tab(child: _RosterTabLabel(text: '消防员', count: widget.gateway.firefighters.length)),
              Tab(child: _RosterTabLabel(text: '专业术语', count: widget.gateway.hotwords.length)),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: <Widget>[
                _buildTabList(context, isFirefighter: true),
                _buildTabList(context, isFirefighter: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotice(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DsSpacing.md),
    child: Text(
      '本名单只用于提升语音识别准确率，不授予登录权限；成员能否登录由『我的 → 入队审批』批准决定。',
      style: context.ds.typography.caption.copyWith(
        color: context.ds.colors.textTertiary,
        height: 1.45,
      ),
    ),
  );

  Widget _buildPendingBanner(BuildContext context) {
    final hasPending = widget.gateway.pendingMemberCount > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: CommandButton(
        label: '入队审批 (${widget.gateway.pendingMemberCount})',
        icon: Icons.how_to_reg_outlined,
        variant: hasPending
            ? CommandButtonVariant.primary
            : CommandButtonVariant.secondary,
        size: hasPending ? CommandButtonSize.large : CommandButtonSize.standard,
        expanded: true,
        onPressed: widget.onOpenMemberReview == null
            ? null
            : () => unawaited(widget.onOpenMemberReview!(context)),
      ),
    );
  }

  Widget _buildTabList(BuildContext context, {required bool isFirefighter}) {
    final firefighters = widget.gateway.firefighters;
    final hotwords = widget.gateway.hotwords;
    final itemCount = isFirefighter ? firefighters.length : hotwords.length;
    final showPending = isFirefighter && widget.gateway.canReviewMembers;

    const listPadding = EdgeInsets.fromLTRB(
      DsSpacing.pageMargin,
      DsSpacing.md,
      DsSpacing.pageMargin,
      DsSpacing.xxl,
    );
    if (itemCount == 0 && !showPending) {
      return ListView(
        padding: listPadding,
        children: <Widget>[
          _buildNotice(context),
          StatePlaceholder.empty(
            icon: isFirefighter
                ? Icons.group_outlined
                : Icons.interpreter_mode_outlined,
            message: isFirefighter ? '暂无消防员，先添加几人吧' : '暂无专业术语',
          ),
        ],
      );
    }

    final headerCount = 1 + (showPending ? 1 : 0);
    return ListView.builder(
      padding: listPadding,
      itemCount: itemCount + headerCount,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) return _buildNotice(context);
        if (showPending && index == 1) return _buildPendingBanner(context);

        final dataIndex = index - headerCount;
        final id = isFirefighter
            ? firefighters[dataIndex].id
            : hotwords[dataIndex].id;
        final label = isFirefighter
            ? firefighters[dataIndex].name
            : hotwords[dataIndex].word;
        final source = isFirefighter
            ? firefighters[dataIndex].source
            : hotwords[dataIndex].source;

        return Padding(
          padding: const EdgeInsets.only(bottom: DsSpacing.sm),
          child: _RosterItemCard(
            label: label,
            isFirefighter: isFirefighter,
            deletable: source != 'builtin',
            onDelete: () => _remove(id, isFirefighter, label),
          ),
        );
      },
    );
  }
}

class _RosterTabLabel extends StatelessWidget {
  const _RosterTabLabel({required this.text, required this.count});

  final String text;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: DsSpacing.xs),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: DsSpacing.sm, vertical: 2),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: DsRadius.borderPill,
          ),
          child: Text(
            '$count',
            style: ds.typography.captionTabular.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _RosterItemCard extends StatelessWidget {
  const _RosterItemCard({
    required this.label,
    required this.isFirefighter,
    required this.deletable,
    required this.onDelete,
  });

  final String label;
  final bool isFirefighter;
  final bool deletable;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(DsSpacing.lg, DsSpacing.sm, DsSpacing.sm, DsSpacing.sm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(shape: BoxShape.circle, color: colors.surfaceMuted),
              child: Icon(
                isFirefighter ? Icons.person_outline_rounded : Icons.tag_rounded,
                size: DsSizes.iconMd,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: DsSpacing.md),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ds.typography.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (deletable)
              IconButton(
                constraints: const BoxConstraints(
                  minWidth: DsSizes.touchTarget,
                  minHeight: DsSizes.touchTarget,
                ),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: colors.textSecondary,
                  size: DsSizes.iconLg,
                ),
                onPressed: onDelete,
                tooltip: '删除',
              ),
          ],
        ),
      ),
    );
  }
}
