import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/settings.dart';
import '../data/models/external_incident.dart';
import '../data/models/incident.dart';
import '../data/models/incident_create_conflict_exception.dart';
import 'incident_picker_card.dart';
import 'sheets/incident_action_sheets.dart';
import 'sheets/incident_basic_info_sheet.dart';

/// Design System v3.0 全屏警情选择页。
///
/// 统一展示自建活跃警情与外部接警记录，支持辖区强隔离、跨区增援匹配、全文检索、
/// 冷启动单一加载不闪空态、新建警情（含名称/地点/大类建档与冷却期冲突抽屉）以及「直接进入 App」。
class IncidentPickerPage extends StatefulWidget {
  const IncidentPickerPage({
    super.key,
    required this.activeIncidents,
    this.externalIncidents = const <ExternalIncident>[],
    required this.loading,
    this.externalLoading = false,
    required this.onSelect,
    this.onCreate,
    this.onCreateWithDraft,
    this.onLocateAddress,
    this.onClaimExternal,
    this.onRefreshExternal,
    this.onEnterWithoutIncident,
    this.userUnitName,
    this.confirmCreate = false,
    this.now,
  }) : assert(onCreate != null || onCreateWithDraft != null);

  final List<Incident> activeIncidents;
  final List<ExternalIncident> externalIncidents;
  final bool loading, externalLoading, confirmCreate;
  final Future<void> Function(Incident incident) onSelect;
  final Future<void> Function()? onCreate;
  final Future<void> Function(IncidentCreateDraft draft)? onCreateWithDraft;
  final IncidentAddressLocator? onLocateAddress;
  final Future<void> Function(ExternalIncident incident)? onClaimExternal;
  final Future<void> Function({bool forceRefresh})? onRefreshExternal;
  final VoidCallback? onEnterWithoutIncident;
  final String? userUnitName;
  final DateTime? now;

  @override
  State<IncidentPickerPage> createState() => _IncidentPickerPageState();
}

class _IncidentPickerPageState extends State<IncidentPickerPage> {
  final TextEditingController _searchController = TextEditingController();
  bool _busy = false;
  String? _error, _loadedUnitName;
  String _searchKeyword = '';

  @override
  void initState() {
    super.initState();
    if (widget.userUnitName == null) _loadUserUnitName();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onRefreshExternal?.call(forceRefresh: false);
    });
  }

  Future<void> _loadUserUnitName() async {
    final name = await Settings.unitName;
    if (mounted && name.trim().isNotEmpty) {
      setState(() => _loadedUnitName = name.trim());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(Incident inc) => _runBusy(() => widget.onSelect(inc));

  Future<void> _claim(ExternalIncident ext) =>
      _runBusy(() async => widget.onClaimExternal?.call(ext));

  Future<void> _refreshExternal() async {
    if (_busy) return;
    try {
      await widget.onRefreshExternal?.call(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _handleCreate() async {
    if (_busy) return;
    IncidentCreateDraft? draft;
    final onCreateWithDraft = widget.onCreateWithDraft;
    if (onCreateWithDraft != null) {
      draft = await showIncidentCreateSheet(
        context,
        onLocateAddress: widget.onLocateAddress,
      );
      if (draft == null || !mounted) return;
    } else if (widget.confirmCreate) {
      final confirmed = await showIncidentCreateConfirmSheet(context);
      if (!confirmed || !mounted) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    IncidentCreateConflictException? conflict;
    try {
      if (onCreateWithDraft != null && draft != null) {
        await onCreateWithDraft(draft);
      } else {
        await widget.onCreate?.call();
      }
    } on IncidentCreateConflictException catch (e) {
      conflict = e;
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (conflict != null && mounted) {
      if (await showIncidentCreateConflictSheet(context, conflict) && mounted) {
        await _select(conflict.existing);
      }
    }
  }

  Widget _buildHeader(BuildContext context) {
    final colors = context.ds.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpacing.lg, DsSpacing.md, DsSpacing.lg, 10),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.brand.withValues(alpha: 0.12),
              borderRadius: DsRadius.borderMd,
            ),
            child: Icon(DsIcons.categoryFire, color: colors.brandText, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '选择警情或直接进入',
              style: context.ds.typography.headline.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final colors = context.ds.colors;
    final typo = context.ds.typography;
    final border = OutlineInputBorder(
      borderRadius: DsRadius.borderMd,
      borderSide: BorderSide(color: colors.border),
    );

    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            key: const Key('incident-picker-search-field'),
            controller: _searchController,
            onChanged: (String v) => setState(() => _searchKeyword = v),
            style: typo.body.copyWith(color: colors.textPrimary),
            cursorColor: colors.brand,
            decoration: InputDecoration(
              hintText: '搜索灾情事件、地点、出动队站或编号…',
              hintStyle: typo.body.copyWith(color: colors.textTertiary),
              prefixIcon: Icon(DsIcons.search, size: DsSizes.iconMd, color: colors.textTertiary),
              suffixIcon: _searchKeyword.isNotEmpty
                  ? IconButton(
                      tooltip: '清除搜索',
                      icon: Icon(DsIcons.closeCircle, size: 18, color: colors.textTertiary),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchKeyword = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: DsSpacing.md,
                vertical: DsSpacing.md,
              ),
              filled: true,
              fillColor: colors.surface,
              border: border,
              enabledBorder: border,
              focusedBorder: OutlineInputBorder(
                borderRadius: DsRadius.borderMd,
                borderSide: BorderSide(color: colors.brand, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: DsSpacing.sm),
        IconButton(
          key: const Key('incident-picker-refresh-btn'),
          tooltip: '刷新派警列表',
          icon: const Icon(DsIcons.refresh, size: DsSizes.iconMd),
          onPressed: (_busy || widget.externalLoading) ? null : _refreshExternal,
          style: IconButton.styleFrom(
            backgroundColor: colors.surfaceMuted,
            foregroundColor: colors.textPrimary,
            disabledBackgroundColor: colors.surfaceMuted.withValues(alpha: 0.6),
            disabledForegroundColor: colors.textTertiary,
            minimumSize: const Size(DsSizes.touchTarget, DsSizes.touchTarget),
            shape: RoundedRectangleBorder(
              borderRadius: DsRadius.borderMd,
              side: BorderSide(color: colors.border),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomActions(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 80) return const SizedBox.shrink();
    final colors = context.ds.colors;
    return Container(
      padding: const EdgeInsets.all(DsSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CommandButton(
            key: const Key('incident-picker-create-btn'),
            label: '新建警情',
            icon: DsIcons.add,
            variant: CommandButtonVariant.primary,
            size: CommandButtonSize.large,
            expanded: true,
            enabled: !_busy,
            onPressed: _handleCreate,
          ),
          if (widget.onEnterWithoutIncident != null) ...<Widget>[
            const SizedBox(height: DsSpacing.sm),
            CommandButton(
              key: const Key('incident-picker-enter-without-btn'),
              label: '直接进入 App',
              icon: DsIcons.arrowRight,
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              expanded: true,
              enabled: !_busy,
              onPressed: widget.onEnterWithoutIncident,
            ),
          ],
          const SizedBox(height: DsSpacing.sm),
          Text(
            widget.onCreateWithDraft != null
                ? '新建时可填写名称与事发地点；名称留空将自动使用时间戳编号。'
                : (widget.activeIncidents.isEmpty
                      ? '当前没有进行中的警情。新建警情会自动使用时间戳名称。'
                      : '如果列表中没有目标警情，可新建；系统会自动使用时间戳名称。'),
            textAlign: TextAlign.center,
            style: context.ds.typography.caption.copyWith(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final typo = context.ds.typography;
    final isAnyLoading = widget.loading || widget.externalLoading;
    final disableAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final loadingLabel = widget.loading && widget.externalLoading
        ? '正在拉取警情列表…'
        : widget.loading
        ? '正在同步现有警情…'
        : '正在获取已调派警情…';
    final items = buildIncidentPickerItems(
      activeIncidents: widget.activeIncidents,
      externalIncidents: widget.externalIncidents,
      userUnitName: widget.userUnitName ?? _loadedUnitName,
      searchKeyword: _searchKeyword,
      onSelectLocal: _select,
      onClaimExternal: _claim,
      now: widget.now,
    );

    return Semantics(
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: '选择警情或直接进入',
      child: Material(
        key: const Key('incident-selection-overlay'),
        color: colors.canvas,
        child: SafeArea(
          child: Stack(
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildHeader(context),
                  if (isAnyLoading)
                    Padding(
                      key: const Key('incident-selection-loading'),
                      padding: const EdgeInsets.fromLTRB(DsSpacing.lg, DsSpacing.sm, DsSpacing.lg, 0),
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              value: disableAnim ? 0.72 : null,
                              strokeWidth: 2,
                              color: colors.brand,
                            ),
                          ),
                          const SizedBox(width: DsSpacing.sm),
                          Expanded(
                            child: Text(
                              loadingLabel,
                              style: typo.caption.copyWith(color: colors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(DsSpacing.lg, DsSpacing.sm, DsSpacing.lg, 0),
                      child: SurfaceCard(
                        key: const Key('incident-selection-error'),
                        level: DsSurfaceLevel.flat,
                        backgroundColor: colors.statusColors(DsStatus.alarm).pillBg,
                        borderColor: colors.alarmFill.withValues(alpha: 0.35),
                        padding: const EdgeInsets.all(DsSpacing.md),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(DsIcons.warning, size: 18, color: colors.alarmText),
                            const SizedBox(width: DsSpacing.sm),
                            Expanded(
                              child: Text(
                                _error!,
                                style: typo.caption.copyWith(
                                  color: colors.alarmText,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Padding(
                    key: const ValueKey<String>('incident-picker-search-slot'),
                    padding: const EdgeInsets.fromLTRB(
                      DsSpacing.lg,
                      DsSpacing.md,
                      DsSpacing.lg,
                      DsSpacing.sm,
                    ),
                    child: _buildSearchBar(context),
                  ),
                  Expanded(
                    child: items.isEmpty
                        ? (isAnyLoading && _searchKeyword.trim().isEmpty
                              ? const _LoadingIncidentPlaceholder()
                              : const SingleChildScrollView(
                                  child: StatePlaceholder.empty(
                                    icon: DsIcons.archive,
                                    message: '当前没有进行中的警情',
                                    detail: '如果你是第一位到达的用户，可以新建警情；也可以直接进入 App。',
                                  ),
                                ))
                        : ListView.separated(
                            key: const Key('incident-selection-list'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: DsSpacing.lg,
                              vertical: DsSpacing.sm,
                            ),
                            itemCount: items.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 10),
                            itemBuilder: (_, int i) =>
                                IncidentPickerCard(item: items[i], enabled: !_busy),
                          ),
                  ),
                  _buildBottomActions(context),
                ],
              ),
              if (_busy)
                const Positioned.fill(
                  child: IgnorePointer(child: ColoredBox(color: Colors.transparent)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingIncidentPlaceholder extends StatelessWidget {
  const _LoadingIncidentPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    final typo = context.ds.typography;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpacing.xl),
          child: Column(
            key: const Key('incident-selection-loading-placeholder'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(DsIcons.sync, size: 48, color: colors.textTertiary),
              const SizedBox(height: DsSpacing.md),
              Text('正在拉取警情信息', style: typo.title.copyWith(color: colors.textPrimary)),
              const SizedBox(height: 6),
              Text(
                '同步完成后将自动展示最新派警与进行中警情',
                textAlign: TextAlign.center,
                style: typo.caption.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
