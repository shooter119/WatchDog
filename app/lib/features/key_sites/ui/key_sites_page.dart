import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/key_sites.dart';
import 'key_site_detail_page.dart';
import 'key_site_gate.dart';

/// 重点单位库主列表页（支持浏览模式与警情绑定选择模式）。
class KeySitesPage extends StatelessWidget {
  const KeySitesPage({
    super.key,
    required this.gateway,
    this.selectForIncident = false,
  });

  final KeySiteGateway gateway;
  final bool selectForIncident;

  @override
  Widget build(BuildContext context) {
    return KeySiteGate(
      gateway: gateway,
      builder: (scope) => _KeySiteListBody(
        gateway: gateway,
        scope: scope,
        selecting: selectForIncident,
      ),
    );
  }
}

class _KeySiteListBody extends StatefulWidget {
  const _KeySiteListBody({
    required this.gateway,
    required this.scope,
    required this.selecting,
  });

  final KeySiteGateway gateway;
  final String scope;
  final bool selecting;

  @override
  State<_KeySiteListBody> createState() => _KeySiteListBodyState();
}

class _KeySiteListBodyState extends State<_KeySiteListBody> {
  final TextEditingController _search = TextEditingController();
  List<KeySiteSummary> _items = const [];
  List<KeySiteSummary> _recent = const [];
  List<String> _districts = const [];
  List<String> _types = const [];
  String _district = '';
  String _type = '';
  bool _loading = true;
  bool _more = false;
  Object? _error;
  Timer? _debounce;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!append) _items = const [];
    });
    try {
      final result = await widget.gateway.fetchKeySites(
        search: _search.text.trim(),
        district: _district,
        type: _type,
        offset: append ? _items.length : 0,
      );
      final filters = await widget.gateway.keySiteFilters();
      final ids = await widget.gateway.recents.read(widget.scope);
      final recent = ids.isEmpty
          ? <KeySiteSummary>[]
          : await widget.gateway.fetchRecentKeySites(ids);
      if (!mounted || generation != _generation) return;
      final incoming = (result['sites'] as List? ?? const [])
          .whereType<Map>()
          .map((s) => KeySiteSummary.fromJson(Map<String, dynamic>.from(s)))
          .toList();
      setState(() {
        _items = <KeySiteSummary>[..._items, ...incoming];
        _more = result['hasMore'] == true;
        _districts = (filters['districts'] as List? ?? const [])
            .map((e) => e.toString())
            .toList();
        _types = (filters['types'] as List? ?? const [])
            .map((e) => e.toString())
            .toList();
        _recent = recent;
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _open(KeySiteSummary site) async {
    if (widget.selecting) {
      Navigator.pop(context, site);
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            KeySiteDetailPage(gateway: widget.gateway, siteId: site.id),
      ),
    );
    if (mounted) _load();
  }

  Widget _buildRow(BuildContext context, KeySiteSummary site) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final versionLabel = site.version > 0 ? 'v${site.version}' : '';
    final metaParts = <String>[
      site.district,
      site.type,
      versionLabel,
    ].where((s) => s.isNotEmpty).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.sm),
      child: SurfaceCard(
        key: ValueKey<String>('key-site-row-${site.id}'),
        level: DsSurfaceLevel.outlined,
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.md,
          vertical: DsSpacing.sm + 2,
        ),
        onTap: () => _open(site),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: DsRadius.borderSm,
                ),
                child: Icon(
                  DsIcons.toolKeySites,
                  size: DsSizes.iconMd,
                  color: colors.brandText,
                ),
              ),
              const SizedBox(width: DsSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      site.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.title.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                    if (site.address.isNotEmpty) ...<Widget>[
                      const SizedBox(height: DsSpacing.xs),
                      Text(
                        site.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    if (metaParts.isNotEmpty) ...<Widget>[
                      const SizedBox(height: DsSpacing.xs),
                      Text(
                        metaParts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.captionTabular.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: DsSpacing.sm),
              Icon(
                DsIcons.chevronRight,
                size: DsSizes.iconMd,
                color: colors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupedItems(BuildContext context) {
    final ds = context.ds;
    if (_district.isNotEmpty) {
      return _items.map((site) => _buildRow(context, site)).toList();
    }
    const unlabeled = '未标注辖区';
    final groups = <String, List<KeySiteSummary>>{};
    final unlabeledItems = <KeySiteSummary>[];
    for (final site in _items) {
      final d = site.district.trim();
      if (d.isEmpty) {
        unlabeledItems.add(site);
      } else {
        groups.putIfAbsent(d, () => <KeySiteSummary>[]).add(site);
      }
    }
    if (unlabeledItems.isNotEmpty) {
      groups
          .putIfAbsent(unlabeled, () => <KeySiteSummary>[])
          .addAll(unlabeledItems);
    }
    final widgets = <Widget>[];
    for (final entry in groups.entries) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: DsSpacing.sm));
      }
      widgets.add(
        Padding(
          key: ValueKey<String>('site-group-${entry.key}'),
          padding: const EdgeInsets.only(bottom: DsSpacing.sm),
          child: Text(
            entry.key,
            style: ds.typography.title.copyWith(
              color: ds.colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
      widgets.addAll(entry.value.map((site) => _buildRow(context, site)));
    }
    return widgets;
  }

  Widget _buildFilterDropdown(
    BuildContext context, {
    required String title,
    required String value,
    required List<String> values,
    required ValueChanged<String> onChanged,
  }) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final effectiveValue = values.contains(value) ? value : '';

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: DsSizes.touchTarget),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: DsSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: DsRadius.borderMd,
          border: Border.all(color: colors.border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            dropdownColor: colors.surface,
            style: typo.body.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
            icon: Icon(
              DsIcons.chevronDown,
              size: DsSizes.iconMd,
              color: colors.textSecondary,
            ),
            value: effectiveValue,
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: '',
                child: Text(
                  '全部$title',
                  overflow: TextOverflow.ellipsis,
                  style: typo.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              ...values.map(
                (v) => DropdownMenuItem<String>(
                  value: v,
                  child: Text(
                    v,
                    overflow: TextOverflow.ellipsis,
                    style: typo.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final showRecent =
        _recent.isNotEmpty &&
        _search.text.trim().isEmpty &&
        _district.isEmpty &&
        _type.isEmpty;

    return CommandScaffold(
      appBar: AppBar(title: Text(widget.selecting ? '绑定重点单位' : '重点单位库')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            DsSpacing.pageMargin,
            DsSpacing.md,
            DsSpacing.pageMargin,
            DsSpacing.xxl,
          ),
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('key-site-list-search'),
              controller: _search,
              decoration: InputDecoration(
                labelText: '名称、简称或地址',
                prefixIcon: const Icon(DsIcons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: () {
                          _search.clear();
                          _debounce?.cancel();
                          _load();
                        },
                        icon: const Icon(DsIcons.close),
                      ),
              ),
              onChanged: (_) {
                setState(() {});
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
            ),
            const SizedBox(height: DsSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: _buildFilterDropdown(
                    context,
                    title: '辖区',
                    value: _district,
                    values: _districts,
                    onChanged: (value) {
                      _district = value;
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: DsSpacing.sm),
                Expanded(
                  child: _buildFilterDropdown(
                    context,
                    title: '类型',
                    value: _type,
                    values: _types,
                    onChanged: (value) {
                      _type = value;
                      _load();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: DsSpacing.md),
            if (showRecent) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                child: Text(
                  '本机最近查看',
                  style: ds.typography.title.copyWith(
                    color: ds.colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ..._recent.map((site) => _buildRow(context, site)),
              const SizedBox(height: DsSpacing.md),
            ],
            ..._buildGroupedItems(context),
            if (_error != null)
              KeySiteFailure(
                error: _error!,
                retry: () => _load(append: _items.isNotEmpty),
              ),
            if (_loading)
              const StatePlaceholder.loading(message: '正在加载重点单位列表...'),
            if (!_loading && _error == null && _items.isEmpty)
              const StatePlaceholder.empty(
                icon: DsIcons.toolKeySites,
                message: '暂无资料',
              ),
            if (!_loading && _more && _error == null)
              Padding(
                padding: const EdgeInsets.only(top: DsSpacing.sm),
                child: CommandButton(
                  label: '加载更多',
                  variant: CommandButtonVariant.secondary,
                  size: CommandButtonSize.standard,
                  expanded: true,
                  onPressed: () => _load(append: true),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
