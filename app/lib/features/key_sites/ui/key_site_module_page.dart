import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/key_site_schema.dart';
import '../data/models/key_sites.dart';
import 'key_site_document_page.dart';
import 'key_site_gate.dart';

/// 重点单位模块详情页（作战信息卡 / 地图 / 应急预案 / 组织架构 / 危险品信息）。
///
/// 始终经由 [KeySiteGate] 与 [KeySitePublishedSnapshot] 校验成员权限并锁定已发布版本。
class KeySiteModulePage extends StatelessWidget {
  const KeySiteModulePage({
    super.key,
    required this.gateway,
    required this.site,
    required this.module,
    this.incidentId,
  });

  final KeySiteGateway gateway;
  final KeySiteVersion site;
  final String module;
  final String? incidentId;

  @override
  Widget build(BuildContext context) {
    return KeySiteGate(
      gateway: gateway,
      builder: (_) => KeySitePublishedSnapshot(
        gateway: gateway,
        site: site,
        incidentId: incidentId,
        builder: (current) => _KeySiteModuleBody(
          gateway: gateway,
          site: current,
          module: module,
          incidentId: incidentId,
        ),
      ),
    );
  }
}

class _KeySiteModuleBody extends StatefulWidget {
  const _KeySiteModuleBody({
    required this.gateway,
    required this.site,
    required this.module,
    this.incidentId,
  });

  final KeySiteGateway gateway;
  final KeySiteVersion site;
  final String module;
  final String? incidentId;

  @override
  State<_KeySiteModuleBody> createState() => _KeySiteModuleBodyState();
}

class _KeySiteModuleBodyState extends State<_KeySiteModuleBody> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matchesQuery(KeySiteEntry entry) {
    if (widget.module != 'hazards' || _query.trim().isEmpty) return true;
    final needle = _query.trim().toLowerCase();
    final haystack =
        '${entry.title} '
        '${entry.fields['location'] ?? ''} '
        '${entry.fields['warehouseName'] ?? ''} '
        '${entry.fields['tankNumber'] ?? ''}'
            .toLowerCase();
    return haystack.contains(needle);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final entries = (widget.site.content[widget.module] ?? const [])
        .where(_matchesQuery)
        .toList();

    return CommandScaffold(
      appBar: AppBar(title: Text(keySiteModules[widget.module] ?? '资料')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          DsSpacing.pageMargin,
          DsSpacing.md,
          DsSpacing.pageMargin,
          DsSpacing.xxl,
        ),
        children: <Widget>[
          Text(
            '${widget.site.name} · v${widget.site.version}',
            style: typo.captionTabular.copyWith(color: colors.textTertiary),
          ),
          const SizedBox(height: DsSpacing.sm),
          if (widget.module == 'hazards') ...<Widget>[
            TextField(
              key: const ValueKey<String>('key-site-hazard-search'),
              controller: _searchController,
              decoration: InputDecoration(
                labelText: '搜索危险品名称、位置、仓库或储罐编号',
                prefixIcon: const Icon(DsIcons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(DsIcons.close),
                      ),
              ),
              onChanged: (q) => setState(() => _query = q),
            ),
            const SizedBox(height: DsSpacing.md),
          ],
          if (entries.isEmpty)
            StatePlaceholder.empty(
              icon: keySiteModuleIcon(widget.module),
              message: '暂无资料',
            ),
          if (widget.module == 'plans' && entries.isNotEmpty) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: DsSpacing.sm),
              child: Text(
                '预案目录',
                style: typo.title.copyWith(color: colors.textPrimary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: DsSpacing.md),
              child: SurfaceCard(
                level: DsSurfaceLevel.outlined,
                padding: const EdgeInsets.all(DsSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final e in entries.asMap().entries)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: e.key == entries.length - 1
                              ? 0
                              : DsSpacing.xs + 2,
                        ),
                        child: Text(
                          '${e.key + 1}. ${e.value.title}',
                          style: typo.bodyTabular.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          ...entries.map((entry) => _buildEntryCard(context, entry)),
        ],
      ),
    );
  }

  Widget _buildEntryCard(BuildContext context, KeySiteEntry entry) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final nonEmptyFields = entry.fields.entries
        .where((f) => f.value.isNotEmpty)
        .toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: SurfaceCard(
        level: DsSurfaceLevel.outlined,
        padding: DsSpacing.cardAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (entry.kind.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.sm),
                child: StatusPill(
                  status: DsStatus.neutral,
                  icon: DsIcons.tag,
                  label: keySiteRecordLabels[entry.kind] ?? '标准记录',
                ),
              ),
            Text(
              entry.title,
              style: typo.title.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            if (entry.body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: DsSpacing.sm),
                child: SelectableText(
                  entry.body,
                  style: typo.body.copyWith(
                    color: colors.textPrimary,
                    height: 1.52,
                  ),
                ),
              ),
            if (nonEmptyFields.isNotEmpty) const SizedBox(height: DsSpacing.sm),
            for (final field in nonEmptyFields)
              Padding(
                padding: const EdgeInsets.only(bottom: DsSpacing.xs + 2),
                child: SelectableText.rich(
                  TextSpan(
                    style: typo.bodyTabular.copyWith(
                      height: 1.5,
                      color: colors.textPrimary,
                    ),
                    children: <InlineSpan>[
                      TextSpan(
                        text: '${keySiteFieldLabels[field.key] ?? field.key}：',
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: field.value,
                        style: TextStyle(color: colors.textPrimary),
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.module == 'maps')
              ...entry.sources.map((source) {
                final attachments = widget.site.attachments.where(
                  (a) => a['id'] == source.attachmentId,
                );
                final attachment = attachments.isEmpty
                    ? null
                    : attachments.first;
                return Padding(
                  padding: const EdgeInsets.only(top: DsSpacing.sm),
                  child: CommandButton(
                    label: '查看地图',
                    icon: DsIcons.toolSceneMap,
                    variant: CommandButtonVariant.secondary,
                    size: CommandButtonSize.standard,
                    enabled: attachment != null,
                    onPressed: attachment == null
                        ? null
                        : () => Navigator.push<void>(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => KeySiteDocumentPage(
                                gateway: widget.gateway,
                                site: widget.site,
                                attachment: attachment,
                                initialPage: source.page,
                                incidentId: widget.incidentId,
                                map: true,
                              ),
                            ),
                          ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
