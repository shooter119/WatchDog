import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

class MemberReviewPage extends StatefulWidget {
  final AppController controller;
  const MemberReviewPage({super.key, required this.controller});
  @override
  State<MemberReviewPage> createState() => _MemberReviewPageState();
}

class _MemberReviewPageState extends State<MemberReviewPage> {
  final Set<String> _busy = {};
  bool _loadingMore = false;
  bool _more = true;
  late final int _epoch;
  @override
  void initState() {
    super.initState();
    _epoch = widget.controller.protectedDataEpoch;
    widget.controller.addListener(_changed);
    widget.controller.refreshPendingMembersCount();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  String _time(dynamic value) {
    final millis = value is num ? value.toInt() : int.tryParse('$value');
    if (millis == null || millis == 0) return '时间未知';
    final d = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    String pad(int v) => '$v'.padLeft(2, '0');
    return '${d.year}-${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}';
  }

  Future<void> _review(UnitMember member, bool approve) async {
    final c = widget.controller;
    final api = c.api;
    final epoch = c.protectedDataEpoch;
    if (_busy.contains(member.id) || api == null || !c.canReviewMembers) return;
    if (!approve) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('驳回入队申请'),
          content: Text('确认驳回「${member.realName}」的申请？对方核实后可重新申请。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认驳回'),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          api != c.api ||
          epoch != c.protectedDataEpoch ||
          !c.canReviewMembers) {
        return;
      }
    }
    setState(() => _busy.add(member.id));
    String message;
    try {
      if (approve) {
        await api.approveMember(member.id);
        if (epoch == c.protectedDataEpoch) await c.loadRoster();
      } else {
        await api.rejectMember(member.id);
      }
      message = approve
          ? '已同意「${member.realName}」入队'
          : '已驳回「${member.realName}」的申请';
    } catch (error) {
      message = '处理失败：$error';
    }
    if (epoch == c.protectedDataEpoch && api == c.api) {
      await c.refreshPendingMembersCount();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
    if (mounted) setState(() => _busy.remove(member.id));
  }

  Future<void> _loadMore() async {
    final c = widget.controller;
    final api = c.api;
    final epoch = c.protectedDataEpoch;
    if (_loadingMore || api == null || !c.canReviewMembers) return;
    final history = c.memberReviewHistory;
    setState(() => _loadingMore = true);
    try {
      final rows = await api.fetchMemberReviewHistory(offset: history.length);
      if (mounted &&
          epoch == c.protectedDataEpoch &&
          api == c.api &&
          c.canReviewMembers &&
          identical(history, c.memberReviewHistory)) {
        setState(() {
          c.memberReviewHistory = [...history, ...rows];
          _more = rows.length == 50;
        });
      }
    } catch (error) {
      if (error is ApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        await c.refreshPendingMembersCount();
      }
      if (mounted && epoch == c.protectedDataEpoch) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('记录加载失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Widget _pending(UnitMember member) {
    final c = widget.controller;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              member.realName,
              style: AppTextStyles.bodyLg.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text('申请单位：${c.memberReviewUnitName}'),
            if (member.stationName.isNotEmpty)
              Text('所属站：${member.stationName}'),
            Text('申请时间：${_time(member.createdAt)}'),
            if (member.applyReason.isNotEmpty)
              Text('申请说明：${member.applyReason}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(88, 48),
                  ),
                  onPressed: _busy.contains(member.id)
                      ? null
                      : () => _review(member, false),
                  child: const Text('驳回'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(88, 48),
                  ),
                  onPressed: _busy.contains(member.id)
                      ? null
                      : () => _review(member, true),
                  child: Text(_busy.contains(member.id) ? '处理中' : '同意入队'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final revoked =
        c.protectedDataRevoked ||
        c.needsAuthentication ||
        _epoch != c.protectedDataEpoch;
    final allowed = !revoked && c.canReviewMembers;
    Widget list(List<Widget> children) => RefreshIndicator(
      onRefresh: () async {
        _more = true;
        await c.refreshPendingMembersCount();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: children,
      ),
    );
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('入队审批'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '待处理'),
              Tab(text: '已处理'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (c.memberReviewLoading) const LinearProgressIndicator(),
            if (!revoked && c.memberReviewError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('审批信息加载失败：${c.memberReviewError}'),
                    TextButton(
                      onPressed: c.refreshPendingMembersCount,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (!allowed &&
                !c.memberReviewLoading &&
                c.memberReviewError == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('无本单位审批权限，请重新认证或联系管理员'),
              ),
            if (allowed)
              Expanded(
                child: TabBarView(
                  children: [
                    list([
                      const Text('本单位管理员共同待办，任一管理员处理后将同步更新。'),
                      const SizedBox(height: 12),
                      if (c.pendingMembers.isEmpty &&
                          !c.memberReviewLoading &&
                          c.memberReviewError == null)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('暂无待审批申请'),
                        ),
                      ...c.pendingMembers.map(_pending),
                    ]),
                    list([
                      if (c.memberReviewHistory.isEmpty &&
                          !c.memberReviewLoading &&
                          c.memberReviewError == null)
                        const Text('暂无已处理记录'),
                      for (final row in c.memberReviewHistory)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: AppCard(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 48),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${row['real_name']} · ${row['review_status'] == 'approved' ? '已同意' : '已驳回'}',
                                    style: AppTextStyles.bodyMd.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '处理人：${row['reviewer_name'] == '' ? '历史记录未保存' : row['reviewer_name']}\n${_time(row['reviewed_at'])}',
                                    style: AppTextStyles.caption.copyWith(
                                      color: AppColors.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (_more && c.memberReviewHistory.length >= 50)
                        TextButton(
                          onPressed: _loadingMore ? null : _loadMore,
                          child: Text(_loadingMore ? '加载中' : '加载更多'),
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
