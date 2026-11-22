import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'archived_incident_cards.dart';
import 'archived_incident_detail_page.dart';

/// 已归档警情列表页（Design System v3.0）。
///
/// 展示处置档案库统计摘要与归档列表，支持通过 [CommandSheet] 修改警情名称
/// 以及进入 [ArchivedIncidentDetailPage] 查看参战力量快照与处置时间线。
class ArchivedIncidentsPage extends StatefulWidget {
  const ArchivedIncidentsPage({
    super.key,
    required this.gateway,
    this.onOpenDetails,
    this.isOffline = false,
  });

  final ArchivedIncidentsGateway gateway;
  final Future<void> Function(
    BuildContext context,
    ArchivedIncidentView incident,
  )?
  onOpenDetails;
  final bool isOffline;

  @override
  State<ArchivedIncidentsPage> createState() => _ArchivedIncidentsPageState();
}

class _ArchivedIncidentsPageState extends State<ArchivedIncidentsPage> {
  List<ArchivedIncidentView> _incidents = const <ArchivedIncidentView>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final items = await widget.gateway.fetchArchivedIncidents();
      if (mounted) {
        setState(() {
          _incidents = items;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取归档警情失败：$error')));
      }
    }
  }

  Future<void> _rename(ArchivedIncidentView incident) async {
    final capturedTheme = Theme.of(context);
    final capturedMediaQuery = MediaQuery.of(context);
    final value = await showModalBottomSheet<String?>(
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
          child: _ArchiveIncidentRenameSheet(initialTitle: incident.title ?? ''),
        ),
      ),
    );
    if (value == null) return;
    try {
      final updated = await widget.gateway.renameIncident(incident, value);
      if (mounted) {
        setState(() {
          _incidents = _incidents
              .map((item) => item.id == updated.id ? updated : item)
              .toList();
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('修改名称失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(
        title: const Text('已归档警情'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            onPressed: _loading ? null : _load,
            icon: const Icon(DsIcons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const StatePlaceholder.loading(message: '正在加载归档警情')
          : RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: <Widget>[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        DsSpacing.pageMargin,
                        DsSpacing.md,
                        DsSpacing.pageMargin,
                        0,
                      ),
                      child: ArchiveSummaryCard(count: _incidents.length),
                    ),
                  ),
                  if (_incidents.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: StatePlaceholder.empty(
                        icon: DsIcons.archive,
                        message: '暂无归档警情',
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        DsSpacing.pageMargin,
                        DsSpacing.md,
                        DsSpacing.pageMargin,
                        DsSpacing.xxl,
                      ),
                      sliver: SliverList.separated(
                        itemCount: _incidents.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: DsSpacing.cardGap),
                        itemBuilder: (BuildContext context, int index) {
                          final incident = _incidents[index];
                          return ArchivedIncidentCard(
                            incident: incident,
                            onRename: () => _rename(incident),
                            onTap: () => Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => ArchivedIncidentDetailPage(
                                  incident: incident,
                                  gateway: widget.gateway,
                                  onOpenDetails: widget.onOpenDetails,
                                  isOffline: widget.isOffline,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ArchiveIncidentRenameSheet extends StatefulWidget {
  const _ArchiveIncidentRenameSheet({required this.initialTitle});

  final String initialTitle;

  @override
  State<_ArchiveIncidentRenameSheet> createState() =>
      _ArchiveIncidentRenameSheetState();
}

class _ArchiveIncidentRenameSheetState extends State<_ArchiveIncidentRenameSheet> {
  late final TextEditingController _input;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialTitle);
  }

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
      title: '修改警情名称',
      subtitle: '留空则显示默认警情名称',
      actions: <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => _close(),
        ),
        CommandButton(
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () => _close(_input.text.trim()),
        ),
      ],
      child: TextField(
        controller: _input,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(hintText: '留空则显示默认警情名称'),
      ),
    );
  }
}
