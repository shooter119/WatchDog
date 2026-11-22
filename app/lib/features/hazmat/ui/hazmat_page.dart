import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../../../services/hazmat_local_store.dart';
import '../data/models/hazmat.dart';
import '../state/hazmat_store.dart';
import 'hazmat_tactical_card.dart';
import 'hazmat_widgets.dart';

/// 危化品 UN 码与战术避险「电台复诵卡」查询页（Design System v3.0）。
///
/// 双层离线保障：内置种子库 + SQLite 本地持久化；联网认证时后台静默增量同步。
/// 本地未命中时仅提供显式「AI 应急提炼战术卡」手动按钮，严禁后台自动调用。
class HazmatPage extends StatefulWidget {
  const HazmatPage({
    super.key,
    this.store,
    this.localStore,
    this.gateway,
  });

  final HazmatStore? store;
  final HazmatLocalStore? localStore;
  final HazmatGateway? gateway;

  @override
  State<HazmatPage> createState() => _HazmatPageState();
}

class _HazmatPageState extends State<HazmatPage> {
  final TextEditingController _searchController = TextEditingController();
  late final HazmatStore _store;
  late final bool _ownsStore;

  @override
  void initState() {
    super.initState();
    if (widget.store != null) {
      _store = widget.store!;
      _ownsStore = false;
      if (_store.query.isNotEmpty) {
        _searchController.text = _store.query;
      }
      if (_store.loadingLocal) {
        _store.initialize();
      }
    } else {
      _store = HazmatStore(
        localStore: widget.localStore,
        gateway: widget.gateway,
      );
      _ownsStore = true;
      _store.initialize();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (_ownsStore) {
      _store.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _store,
      builder: (context, _) {
        final query = _store.trimmedQuery;
        final activeItem = _store.activeItem;

        return CommandScaffold(
          appBar: AppBar(
            title: const Text('危化品应急速查'),
            actions: <Widget>[
              if (_store.canSync)
                IconButton(
                  tooltip: '同步云端危化品库',
                  onPressed: _store.syncing ? null : _store.syncFromServer,
                  icon: _store.syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(DsIcons.sync),
                ),
            ],
          ),
          body: Column(
            children: <Widget>[
              _buildSearchHeader(context, query),
              Expanded(
                child: _store.loadingLocal
                    ? const StatePlaceholder.loading(
                        message: '正在加载本地离线危化品库...',
                      )
                    : activeItem != null
                    ? _buildCardView(context, activeItem)
                    : _buildListOrEmptyView(context, query),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchHeader(BuildContext context, String query) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border, width: 1)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DsSpacing.pageMargin,
          DsSpacing.sm,
          DsSpacing.pageMargin,
          DsSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('hazmat-search-input'),
              controller: _searchController,
              onChanged: _store.updateQuery,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '输入 4 位 UN 编号（如 1428）、品名或俗名',
                prefixIcon: const Icon(DsIcons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey<String>('hazmat-search-clear'),
                        tooltip: '清空检索',
                        onPressed: () {
                          _searchController.clear();
                          _store.updateQuery('');
                        },
                        icon: const Icon(DsIcons.close),
                      ),
              ),
            ),
            const SizedBox(height: DsSpacing.sm),
            Row(
              children: <Widget>[
                Icon(
                  _store.syncedFromServer
                      ? DsIcons.connOnline
                      : DsIcons.offlinePin,
                  size: DsSizes.iconSm,
                  color: _store.syncedFromServer
                      ? colors.safeText
                      : colors.textSecondary,
                ),
                const SizedBox(width: DsSpacing.xs + 2),
                Expanded(
                  child: Text(
                    _store.syncing
                        ? '正在静默校验云端增量更新 · 本地 ${_store.totalCount} 种'
                        : (_store.syncedFromServer
                              ? '离线词库已同步云端 · 共 ${_store.totalCount} 种常见危化品'
                              : '离线词库已就绪 · 内置 ${_store.totalCount} 种常见危化品'),
                    style: typo.captionTabular.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                if (_store.selected != null && _store.results.length > 1)
                  TextButton.icon(
                    onPressed: () => _store.selectItem(null),
                    icon: const Icon(DsIcons.list, size: DsSizes.iconSm),
                    label: const Text('返回列表'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: DsSpacing.sm,
                      ),
                    ),
                  ),
              ],
            ),
            if (_store.activeItem == null) ...<Widget>[
              const SizedBox(height: DsSpacing.sm),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    _buildWaterChip(context, '', '全部'),
                    const SizedBox(width: DsSpacing.sm),
                    _buildWaterChip(context, 'forbidden', '严禁用水'),
                    const SizedBox(width: DsSpacing.sm),
                    _buildWaterChip(context, 'reactive', '慎用/剧烈反应'),
                    const SizedBox(width: DsSpacing.sm),
                    _buildWaterChip(context, 'normal', '可用水控制'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWaterChip(BuildContext context, String value, String label) {
    final ds = context.ds;
    final colors = ds.colors;
    final selected = _store.waterFilter == value;
    final (Color activeBg, Color activeFg) = switch (value) {
      'forbidden' => (colors.alarmFill, colors.onAlarm),
      'reactive' => (colors.cautionFill, colors.onCaution),
      _ => (colors.brand, colors.onBrand),
    };

    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _store.setWaterFilter(value),
      selectedColor: activeBg,
      backgroundColor: colors.surfaceMuted,
      checkmarkColor: activeFg,
      labelStyle: ds.typography.caption.copyWith(
        color: selected ? activeFg : colors.textPrimary,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(color: selected ? Colors.transparent : colors.border),
    );
  }

  Widget _buildCardView(BuildContext context, HazmatItem item) {
    final isAi = _store.isActiveItemAi;
    final aiResult = _store.aiResult;
    final disclaimer = aiResult?.disclaimer ?? '';

    return ListView(
      padding: const EdgeInsets.all(DsSpacing.pageMargin),
      children: <Widget>[
        if (isAi) ...<Widget>[
          HazmatNoticeBanner(
            key: const ValueKey<String>('hazmat-ai-warning-banner'),
            status: DsStatus.caution,
            icon: DsIcons.sparkle,
            text: disclaimer.isNotEmpty
                ? disclaimer
                : 'AI 辅助提炼 · 请务必结合随车运单、SDS 与现场侦检仪器核实',
          ),
          const SizedBox(height: DsSpacing.cardGap),
        ] else if (aiResult?.found == true && aiResult?.source == 'server') ...[
          const HazmatNoticeBanner(
            status: DsStatus.safe,
            icon: DsIcons.verified,
            text: '已从云端标准危化库精确匹配',
          ),
          const SizedBox(height: DsSpacing.cardGap),
        ],
        HazmatTacticalCard(item: item, aiDisclaimer: isAi ? disclaimer : null),
        const SizedBox(height: DsSpacing.xxl),
      ],
    );
  }

  Widget _buildListOrEmptyView(BuildContext context, String query) {
    if (_store.results.isEmpty) {
      return _buildMissFallbackView(context, query);
    }

    return ListView.separated(
      padding: const EdgeInsets.all(DsSpacing.pageMargin),
      itemCount: _store.results.length,
      separatorBuilder: (_, _) => const SizedBox(height: DsSpacing.sm),
      itemBuilder: (context, index) {
        final item = _store.results[index];
        return HazmatListTile(
          item: item,
          onTap: () => _store.selectItem(item),
        );
      },
    );
  }

  Widget _buildMissFallbackView(BuildContext context, String query) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;
    final aiResult = _store.aiResult;

    return ListView(
      padding: const EdgeInsets.all(DsSpacing.pageMargin),
      children: <Widget>[
        SurfaceCard(
          level: DsSurfaceLevel.outlined,
          padding: DsSpacing.cardAll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      DsIcons.searchOff,
                      color: colors.textSecondary,
                      size: DsSizes.iconLg,
                    ),
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  Expanded(
                    child: Text(
                      query.isEmpty
                          ? '当前筛选条件下暂无匹配危化品'
                          : '本地危化库未找到「$query」',
                      style: typo.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: DsSpacing.sm),
              Text(
                '请核对槽罐车 4 位 UN 标牌、随车危险货物运单或中文俗名；也可切换上方遇水属性筛选项重试。',
                style: typo.body.copyWith(color: colors.textSecondary),
              ),
              if (query.isNotEmpty) ...<Widget>[
                const SizedBox(height: DsSpacing.lg),
                if (!_store.canGenerateAi)
                  const HazmatNoticeBanner(
                    status: DsStatus.neutral,
                    icon: DsIcons.connOffline,
                    text: '当前处于离线或未登录状态，无法调用云端 AI 应急提炼。请核对随车 SDS 或联系指挥中心。',
                  )
                else ...<Widget>[
                  CommandButton(
                    key: const ValueKey<String>('hazmat-ai-fallback-btn'),
                    label: _store.loadingAi
                        ? '正在向云端提炼「$query」...'
                        : 'AI 应急提炼战术卡',
                    icon: DsIcons.sparkle,
                    variant: CommandButtonVariant.primary,
                    size: CommandButtonSize.large,
                    expanded: true,
                    isLoading: _store.loadingAi,
                    onPressed: _store.requestAiCard,
                  ),
                  const SizedBox(height: DsSpacing.sm),
                  Text(
                    '优先查询单位云端标准库，未命中时再由 AI 提炼核心禁忌与疏散参数。',
                    style: typo.caption.copyWith(color: colors.textSecondary),
                  ),
                ],
              ],
              if (_store.aiError != null) ...<Widget>[
                const SizedBox(height: DsSpacing.md),
                HazmatNoticeBanner(
                  status: DsStatus.alarm,
                  icon: DsIcons.warning,
                  text: _store.aiError!,
                ),
              ],
              if (aiResult != null && !aiResult.found) ...<Widget>[
                const SizedBox(height: DsSpacing.md),
                HazmatNoticeBanner(
                  key: const ValueKey<String>('hazmat-ai-unverified-banner'),
                  status: DsStatus.caution,
                  icon: DsIcons.warning,
                  text: aiResult.reason.isNotEmpty
                      ? aiResult.reason
                      : '未查找到与「$query」对应的已核实危化品记录，严禁猜测处置，请核对运单与 SDS。',
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
