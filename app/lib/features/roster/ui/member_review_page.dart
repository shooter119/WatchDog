import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_exceptions.dart';
import '../../../design_system/design_system.dart';
import 'member_review_cards.dart';

export 'member_review_cards.dart'
    show PendingMemberView, MemberReviewHistoryItem, MemberReviewGateway;

/// 入队审批页（Design System v3.0）。
///
/// 以服务端审批能力为准，支持待处理/已处理双 Tab、驳回 [CommandSheet] 二次确认、
/// 已处理分页加载，以及权限撤销或会话纪元变化时的即时清空。
class MemberReviewPage extends StatefulWidget {
  const MemberReviewPage({
    super.key,
    required this.gateway,
    this.isOffline = false,
  });

  final MemberReviewGateway gateway;
  final bool isOffline;

  @override
  State<MemberReviewPage> createState() => _MemberReviewPageState();
}

class _MemberReviewPageState extends State<MemberReviewPage> {
  final Set<String> _busy = <String>{};
  bool _loadingMore = false;
  bool _more = true;
  late int _epoch;

  @override
  void initState() {
    super.initState();
    _epoch = widget.gateway.protectedDataEpoch;
    widget.gateway.changes?.addListener(_onChanged);
    unawaited(widget.gateway.refresh());
  }

  @override
  void didUpdateWidget(covariant MemberReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway) {
      oldWidget.gateway.changes?.removeListener(_onChanged);
      _epoch = widget.gateway.protectedDataEpoch;
      widget.gateway.changes?.addListener(_onChanged);
      unawaited(widget.gateway.refresh());
    }
  }

  @override
  void dispose() {
    widget.gateway.changes?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String _formatTime(dynamic value) {
    final millis = value is num ? value.toInt() : int.tryParse('$value');
    if (millis == null || millis == 0) return '时间未知';
    final d = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    String pad(int v) => '$v'.padLeft(2, '0');
    return '${d.year}-${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}';
  }

  Future<void> _review(PendingMemberView member, bool approve) async {
    final gw = widget.gateway;
    final epoch = gw.protectedDataEpoch;
    if (_busy.contains(member.id) || !gw.canReviewMembers) return;

    if (!approve) {
      final confirmed = await showCommandSheet<bool>(
        context: context,
        title: '驳回入队申请',
        builder: (BuildContext sheetContext) => Text(
          '确认驳回「${member.realName}」的申请？对方核实后可重新申请。',
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
            label: '确认驳回',
            variant: CommandButtonVariant.danger,
            size: CommandButtonSize.large,
            requireConfirmation: false,
            onPressed: () => Navigator.of(sheetContext).pop(true),
          ),
        ],
      );
      if (confirmed != true ||
          !mounted ||
          epoch != gw.protectedDataEpoch ||
          !gw.canReviewMembers) {
        return;
      }
    }

    setState(() => _busy.add(member.id));
    String message;
    try {
      if (approve) {
        await gw.approveMember(member.id);
      } else {
        await gw.rejectMember(member.id);
      }
      message = approve
          ? '已同意「${member.realName}」入队'
          : '已驳回「${member.realName}」的申请';
    } catch (error) {
      message = '处理失败：$error';
    }

    if (epoch == gw.protectedDataEpoch) {
      await gw.refresh();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
    if (mounted) setState(() => _busy.remove(member.id));
  }

  Future<void> _loadMore() async {
    final gw = widget.gateway;
    final epoch = gw.protectedDataEpoch;
    if (_loadingMore || !gw.canReviewMembers) return;
    final previousLength = gw.reviewHistory.length;
    setState(() => _loadingMore = true);
    try {
      final rows = await gw.fetchHistoryPage(offset: previousLength);
      if (mounted &&
          epoch == gw.protectedDataEpoch &&
          gw.canReviewMembers &&
          gw.reviewHistory.length == previousLength) {
        gw.appendHistoryPage(rows);
        setState(() => _more = rows.length == 50);
      }
    } catch (error) {
      if (error is ApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        await gw.refresh();
      }
      if (mounted && epoch == gw.protectedDataEpoch) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('记录加载失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gw = widget.gateway;
    final colors = context.ds.colors;
    final revoked =
        gw.protectedDataRevoked ||
        gw.needsAuthentication ||
        _epoch != gw.protectedDataEpoch;
    final allowed = !revoked && gw.canReviewMembers;

    Widget buildTabList(List<Widget> children) => RefreshIndicator(
      onRefresh: () async {
        _more = true;
        await gw.refresh();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          DsSpacing.pageMargin,
          DsSpacing.md,
          DsSpacing.pageMargin,
          DsSpacing.xxl,
        ),
        children: children,
      ),
    );

    return DefaultTabController(
      length: 2,
      child: CommandScaffold(
        isOffline: widget.isOffline,
        appBar: AppBar(
          title: const Text('入队审批'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: '待处理'),
              Tab(text: '已处理'),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            if (gw.isLoading)
              LinearProgressIndicator(
                color: colors.brand,
                backgroundColor: colors.surfaceMuted,
              ),
            if (!revoked && gw.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DsSpacing.pageMargin,
                  DsSpacing.md,
                  DsSpacing.pageMargin,
                  0,
                ),
                child: MemberReviewErrorBanner(
                  message: '审批信息加载失败：${gw.error}',
                  onRetry: () => unawaited(gw.refresh()),
                ),
              ),
            if (!allowed && !gw.isLoading && gw.error == null)
              const Expanded(
                child: StatePlaceholder.empty(
                  icon: DsIcons.lock,
                  message: '无本单位审批权限，请重新认证或联系管理员',
                ),
              ),
            if (allowed)
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    buildTabList(<Widget>[
                      if (gw.pendingMembers.isEmpty &&
                          !gw.isLoading &&
                          gw.error == null)
                        const StatePlaceholder.empty(
                          icon: DsIcons.inbox,
                          message: '暂无待审批申请',
                        ),
                      for (final member in gw.pendingMembers)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: DsSpacing.cardGap,
                          ),
                          child: PendingMemberCard(
                            member: member,
                            unitName: gw.unitName,
                            appliedAtText: _formatTime(member.createdAt),
                            busy: _busy.contains(member.id),
                            onReject: () => _review(member, false),
                            onApprove: () => _review(member, true),
                          ),
                        ),
                    ]),
                    buildTabList(<Widget>[
                      if (gw.reviewHistory.isEmpty &&
                          !gw.isLoading &&
                          gw.error == null)
                        const StatePlaceholder.empty(
                          icon: DsIcons.clipboard,
                          message: '暂无已处理记录',
                        ),
                      for (final item in gw.reviewHistory)
                        Padding(
                          padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                          child: ReviewHistoryCard(
                            item: item,
                            reviewedAtText: _formatTime(item.reviewedAt),
                          ),
                        ),
                      if (_more && gw.reviewHistory.length >= 50)
                        Padding(
                          padding: const EdgeInsets.only(top: DsSpacing.sm),
                          child: CommandButton(
                            label: _loadingMore ? '加载中' : '加载更多',
                            variant: CommandButtonVariant.ghost,
                            size: CommandButtonSize.standard,
                            isLoading: _loadingMore,
                            expanded: true,
                            onPressed: _loadingMore ? null : _loadMore,
                          ),
                        ),
                    ]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
