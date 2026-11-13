import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/hazmat.dart';
import '../services/hazmat_local_store.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 危化品 UN 码与战术避险「电台复诵卡」查询页
///
/// 双层离线保障：内置种子库 + SQLite 本地持久化；联网认证时后台静默增量同步。
/// 本地未命中时提供显式「AI 应急提炼战术卡」兜底，不自动后台扣费。
class HazmatPage extends StatefulWidget {
  final AppController? controller;
  final HazmatLocalStore? store;

  const HazmatPage({super.key, this.controller, this.store});

  @override
  State<HazmatPage> createState() => _HazmatPageState();
}

class _HazmatPageState extends State<HazmatPage> {
  final TextEditingController _searchController = TextEditingController();
  late final HazmatLocalStore _store;

  List<HazmatItem> _results = const [];
  HazmatItem? _selected;
  HazmatAiResult? _aiResult;
  bool _loadingLocal = true;
  bool _syncing = false;
  bool _syncedFromServer = false;
  bool _loadingAi = false;
  String? _aiError;
  String _waterFilter = ''; // '' | 'forbidden' | 'reactive' | 'normal'
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? HazmatLocalStore.instance;
    _initAndSync();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initAndSync() async {
    await _loadLocal();
    final api = widget.controller?.api;
    if (api == null) return;
    if (!mounted) return;
    setState(() => _syncing = true);
    try {
      await _store.syncFromServer(api);
      if (!mounted) return;
      _syncedFromServer = true;
      await _loadLocal();
    } catch (_) {
      // 现场网络不稳时静默保留本地离线词库，不弹出阻塞提示
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _loadLocal() async {
    final query = _searchController.text;
    final items = await _store.search(
      query: query,
      water: _waterFilter,
      limit: 80,
    );
    final total = await _store.countAll();
    if (!mounted) return;
    setState(() {
      _results = items;
      _totalCount = total;
      _loadingLocal = false;
      _selected = _resolveAutoSelected(query, items);
    });
  }

  /// 输入完整 4 位 UN 号精确命中（或仅命中 1 条记录）时直出战术卡
  HazmatItem? _resolveAutoSelected(String rawQuery, List<HazmatItem> items) {
    if (items.isEmpty) return null;
    final stripped = rawQuery
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^un[\s-]*', caseSensitive: false), '')
        .trim();
    if (stripped.isEmpty) return null;
    if (RegExp(r'^\d{4}$').hasMatch(stripped)) {
      for (final item in items) {
        if (item.unNumber.toLowerCase() == stripped) {
          return item;
        }
      }
    }
    if (items.length == 1) {
      return items.first;
    }
    return null;
  }

  Future<void> _requestAiCard() async {
    final api = widget.controller?.api;
    final query = _searchController.text.trim();
    if (api == null || query.isEmpty || _loadingAi) return;

    setState(() {
      _loadingAi = true;
      _aiError = null;
      _aiResult = null;
    });

    try {
      final result = await api.generateHazmatAiCard(query);
      if (!mounted) return;
      setState(() {
        _aiResult = result;
        _loadingAi = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiError = e.toString().replaceFirst('Exception: ', '');
        _loadingAi = false;
      });
    }
  }

  void _onQueryChanged(String value) {
    setState(() {
      _aiResult = null;
      _aiError = null;
    });
    _loadLocal();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim();
    final activeItem =
        _selected ?? (_aiResult?.found == true ? _aiResult!.item : null);

    return Scaffold(
      appBar: AppBar(
        title: const Text('危化品应急速查'),
        actions: [
          if (widget.controller?.api != null)
            IconButton(
              tooltip: '同步云端危化品库',
              onPressed: _syncing ? null : _initAndSync,
              icon: _syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchHeader(context, query),
            Expanded(
              child: _loadingLocal
                  ? const Center(child: CircularProgressIndicator())
                  : activeItem != null
                  ? _buildCardView(context, activeItem)
                  : _buildListOrEmptyView(context, query),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchHeader(BuildContext context, String query) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.s2,
        AppSpacing.pageMargin,
        AppSpacing.s3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('hazmat-search-input'),
            controller: _searchController,
            onChanged: _onQueryChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '输入 4 位 UN 编号（如 1428）、品名或俗名',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('hazmat-search-clear'),
                      tooltip: '清空检索',
                      onPressed: () {
                        _searchController.clear();
                        _onQueryChanged('');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              fillColor: AppColors.surfaceSubtle,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3,
                vertical: AppSpacing.s3,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(color: AppColors.border),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Icon(
                _syncedFromServer
                    ? Icons.cloud_done_outlined
                    : Icons.offline_pin_outlined,
                size: 14,
                color: _syncedFromServer
                    ? AppColors.safeText
                    : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _syncing
                      ? '正在静默校验云端增量更新 · 本地 $_totalCount 种'
                      : (_syncedFromServer
                            ? '离线词库已同步云端 · 共 $_totalCount 种常见危化品'
                            : '离线词库已就绪 · 内置 $_totalCount 种常见危化品'),
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              if (_selected != null && _results.length > 1)
                TextButton.icon(
                  onPressed: () => setState(() => _selected = null),
                  icon: const Icon(Icons.list_rounded, size: 16),
                  label: const Text('返回列表'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ],
          ),
          if (_selected == null && _aiResult?.found != true) ...[
            const SizedBox(height: AppSpacing.s2),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildWaterChip('', '全部'),
                  const SizedBox(width: AppSpacing.s2),
                  _buildWaterChip('forbidden', '严禁用水'),
                  const SizedBox(width: AppSpacing.s2),
                  _buildWaterChip('reactive', '慎用/剧烈反应'),
                  const SizedBox(width: AppSpacing.s2),
                  _buildWaterChip('normal', '可用水控制'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWaterChip(String value, String label) {
    final selected = _waterFilter == value;
    final Color activeBg;
    final Color activeFg;
    if (value == 'forbidden') {
      activeBg = AppColors.alarm;
      activeFg = AppColors.onStatus;
    } else if (value == 'reactive') {
      activeBg = AppColors.caution;
      activeFg = AppColors.onStatus;
    } else {
      activeBg = AppColors.actionPrimary;
      activeFg = AppColors.onPrimary;
    }
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        setState(() {
          _waterFilter = value;
          _selected = null;
          _aiResult = null;
          _aiError = null;
        });
        _loadLocal();
      },
      selectedColor: activeBg,
      backgroundColor: AppColors.surfaceSubtle,
      labelStyle: AppTextStyles.label.copyWith(
        color: selected ? activeFg : AppColors.textPrimary,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(
        color: selected ? Colors.transparent : AppColors.border,
      ),
    );
  }

  Widget _buildCardView(BuildContext context, HazmatItem item) {
    final isAi = item.isAiGenerated || _aiResult?.source == 'ai';
    final disclaimer = _aiResult?.disclaimer ?? '';
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.pageMargin),
      children: [
        if (isAi) ...[
          AppBanner(
            text: disclaimer.isNotEmpty
                ? disclaimer
                : 'AI 辅助提炼 · 请务必结合随车运单、SDS 与现场侦检仪器核实',
            kind: AppBannerKind.warning,
            icon: Icons.auto_awesome_rounded,
          ),
          const SizedBox(height: AppSpacing.s3),
        ] else if (_aiResult?.found == true && _aiResult?.source == 'server') ...[
          AppBanner(
            text: '已从云端标准危化库精确匹配',
            kind: AppBannerKind.offline,
            icon: Icons.verified_outlined,
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
        HazmatTacticalCard(
          item: item,
          aiDisclaimer: isAi ? disclaimer : null,
        ),
        const SizedBox(height: AppSpacing.s6),
      ],
    );
  }

  Widget _buildListOrEmptyView(BuildContext context, String query) {
    if (_results.isEmpty) {
      return _buildMissFallbackView(context, query);
    }

    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.pageMargin),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s2),
      itemBuilder: (context, index) {
        final item = _results[index];
        return _HazmatListTile(
          item: item,
          onTap: () => setState(() => _selected = item),
        );
      },
    );
  }

  Widget _buildMissFallbackView(BuildContext context, String query) {
    final hasApi = widget.controller?.api != null;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.pageMargin),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.search_off_rounded,
                    color: AppColors.textSecondary,
                    size: 22,
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      query.isEmpty
                          ? '当前筛选条件下暂无匹配危化品'
                          : '本地危化库未找到「$query」',
                      style: AppTextStyles.title.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(
                '请核对槽罐车 4 位 UN 标牌、随车危险货物运单或中文俗名；也可切换上方遇水属性筛选项重试。',
                style: AppTextStyles.bodyMd.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              if (query.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s4),
                if (!hasApi)
                  const AppBanner(
                    text: '当前处于离线或未登录状态，无法调用云端 AI 应急提炼。请核对随车 SDS 或联系指挥中心。',
                    kind: AppBannerKind.offline,
                  )
                else ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('hazmat-ai-fallback-btn'),
                      onPressed: _loadingAi ? null : _requestAiCard,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      icon: _loadingAi
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.onPrimary,
                              ),
                            )
                          : const Icon(Icons.auto_awesome_rounded),
                      label: Text(
                        _loadingAi
                            ? '正在向云端提炼「$query」...'
                            : 'AI 应急提炼战术卡',
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    '优先查询单位云端标准库，未命中时再由 AI 提炼核心禁忌与疏散参数。',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
              if (_aiError != null) ...[
                const SizedBox(height: AppSpacing.s3),
                AppBanner(
                  text: _aiError!,
                  kind: AppBannerKind.warning,
                ),
              ],
              if (_aiResult != null && !_aiResult!.found) ...[
                const SizedBox(height: AppSpacing.s3),
                AppBanner(
                  key: const ValueKey('hazmat-ai-unverified-banner'),
                  text: _aiResult!.reason.isNotEmpty
                      ? _aiResult!.reason
                      : '未查找到与「$query」对应的已核实危化品记录，严禁猜测处置，请核对运单与 SDS。',
                  kind: AppBannerKind.warning,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _HazmatListTile extends StatelessWidget {
  final HazmatItem item;
  final VoidCallback onTap;

  const _HazmatListTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final waterColor = item.isWaterForbidden
        ? AppColors.alarmText
        : (item.isWaterReactive
              ? AppColors.cautionText
              : AppColors.safeText);
    final waterBg = item.isWaterForbidden
        ? AppColors.alarmSurface
        : (item.isWaterReactive
              ? AppColors.cautionSurface
              : AppColors.safeSurface);

    return AppCard(
      key: ValueKey('hazmat-list-item-${item.id}'),
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (item.unNumber.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.actionPrimary,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    'UN ${item.unNumber}',
                    style: AppTextStyles.label.copyWith(
                      color: AppColors.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: waterBg,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  item.waterLabel,
                  style: AppTextStyles.label.copyWith(
                    color: waterColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (item.dangerCategory.isNotEmpty)
                Text(
                  item.dangerCategory,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Expanded(
                child: Text(
                  item.nameCn,
                  style: AppTextStyles.title.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textTertiary,
              ),
            ],
          ),
          if (item.aliases.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '别名：${item.aliases.join('、')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ],
          if (item.forbiddenAgents.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '禁忌：${item.forbiddenAgents}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.caption.copyWith(
                color: item.isWaterForbidden
                    ? AppColors.alarmText
                    : AppColors.textSecondary,
                fontWeight: item.isWaterForbidden
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 高对比度「电台战术复诵卡」组件
///
/// 信息优先级：身份标识/遇水红线 -> 绝对禁忌 -> 灭火防护对策 -> 隔离疏散 -> 折叠详注。
class HazmatTacticalCard extends StatelessWidget {
  final HazmatItem item;
  final String? aiDisclaimer;

  const HazmatTacticalCard({
    super.key,
    required this.item,
    this.aiDisclaimer,
  });

  Future<void> _copyToClipboard(BuildContext context) async {
    final text = item.formatShareText(aiDisclaimer: aiDisclaimer);
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已复制电台处置要点，可粘贴至救援调度群'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final signBg = _resolveCategoryBg(item);
    final signFg = _resolveCategoryFg(item);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 物质身份头卡 + 复制按钮
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: AppSpacing.s2,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.actionPrimary,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      item.unNumber.isNotEmpty
                          ? 'UN ${item.unNumber}'
                          : '未列 UN 编号',
                      style: AppTextStyles.label.copyWith(
                        color: AppColors.onPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (item.dangerCategory.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: signBg,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                          color: signFg.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        item.dangerCategory,
                        style: AppTextStyles.label.copyWith(
                          color: signFg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                item.nameCn,
                style: AppTextStyles.h1.copyWith(
                  color: AppColors.textPrimary,
                ),
              ),
              if (item.nameEn.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  item.nameEn,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              if (item.aliases.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '俗名/别名：${item.aliases.join('、')}',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.s3),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('hazmat-copy-btn'),
                  onPressed: () => _copyToClipboard(context),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.copy_all_rounded, size: 18),
                  label: const Text('复制处置要点'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s3),

        // 2. 双通道遇水警示横幅
        _buildWaterBanner(),
        const SizedBox(height: AppSpacing.s3),

        // 3. 致命禁忌（绝对保命红线）
        if (item.forbiddenAgents.isNotEmpty) ...[
          AppCard(
            color: AppColors.alarmSurface,
            side: BorderSide(color: AppColors.alarm, width: 1.2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.block_rounded,
                      color: AppColors.alarmText,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Text(
                      '绝对禁忌 · 严禁动作',
                      style: AppTextStyles.title.copyWith(
                        color: AppColors.alarmText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  item.forbiddenAgents,
                  style: AppTextStyles.bodyMd.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
        ],

        // 4. 核心灭火与战术对策
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(text: '核心灭火与战术对策'),
              const SizedBox(height: AppSpacing.s2),
              _InfoBlock(
                icon: Icons.local_fire_department_outlined,
                label: '推荐灭火/抑蒸介质',
                value: item.extinguishingAgents,
                highlightColor: AppColors.safeText,
              ),
              if (item.firefightingTips.isNotEmpty) ...[
                const Divider(height: AppSpacing.s4),
                _InfoBlock(
                  icon: Icons.shield_outlined,
                  label: '战术处置要点',
                  value: item.firefightingTips,
                ),
              ],
              if (item.protectiveLevel.isNotEmpty) ...[
                const Divider(height: AppSpacing.s4),
                _InfoBlock(
                  icon: Icons.health_and_safety_outlined,
                  label: '个体防护等级',
                  value: item.protectiveLevel,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s3),

        // 5. 隔离疏散与关键参数
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(text: '隔离疏散与危情评估'),
              const SizedBox(height: AppSpacing.s2),
              if (item.isolationDistance.isNotEmpty)
                _InfoBlock(
                  icon: Icons.social_distance_rounded,
                  label: '初期隔离与下风向疏散',
                  value: item.isolationDistance,
                  highlightColor: AppColors.cautionText,
                ),
              if (item.dangerSummary.isNotEmpty) ...[
                if (item.isolationDistance.isNotEmpty)
                  const Divider(height: AppSpacing.s4),
                _InfoBlock(
                  icon: Icons.warning_amber_rounded,
                  label: '核心危险性',
                  value: item.dangerSummary,
                ),
              ],
              if (item.vaporDensityHint.isNotEmpty) ...[
                const Divider(height: AppSpacing.s4),
                _InfoBlock(
                  icon: Icons.air_rounded,
                  label: '蒸气密度与积聚方位',
                  value: item.vaporDensityHint,
                ),
              ],
              if (item.flashPoint.isNotEmpty ||
                  item.explosionLimit.isNotEmpty) ...[
                const Divider(height: AppSpacing.s4),
                Wrap(
                  spacing: AppSpacing.s4,
                  runSpacing: AppSpacing.s2,
                  children: [
                    if (item.flashPoint.isNotEmpty)
                      _MetricPill(label: '闪点', value: item.flashPoint),
                    if (item.explosionLimit.isNotEmpty)
                      _MetricPill(label: '爆炸极限', value: item.explosionLimit),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s3),

        // 6. 泄漏堵漏、急救与理化详注（折叠面板）
        if (_hasSecondaryDetails)
          AppCard(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const ValueKey('hazmat-secondary-expansion'),
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.cardInner,
                  vertical: AppSpacing.s1,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(
                  AppSpacing.cardInner,
                  0,
                  AppSpacing.cardInner,
                  AppSpacing.cardInner,
                ),
                title: Text(
                  '泄漏堵漏、现场急救与理化详注',
                  style: AppTextStyles.title.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
                children: [
                  if (item.leakHandling.isNotEmpty) ...[
                    _InfoBlock(
                      icon: Icons.water_damage_outlined,
                      label: '泄漏围堵与洗消',
                      value: item.leakHandling,
                    ),
                    const Divider(height: AppSpacing.s4),
                  ],
                  if (item.firstAid.isNotEmpty) ...[
                    _InfoBlock(
                      icon: Icons.medical_services_outlined,
                      label: '现场急救措施',
                      value: item.firstAid,
                    ),
                    const Divider(height: AppSpacing.s4),
                  ],
                  if (item.appearance.isNotEmpty) ...[
                    _InfoBlock(
                      icon: Icons.visibility_outlined,
                      label: '外观与气味识别',
                      value: item.appearance,
                    ),
                    const Divider(height: AppSpacing.s4),
                  ],
                  if (item.casNumber.isNotEmpty) ...[
                    _InfoBlock(
                      icon: Icons.tag_rounded,
                      label: 'CAS 登记号',
                      value: item.casNumber,
                    ),
                    if (item.notes.isNotEmpty) const Divider(height: AppSpacing.s4),
                  ],
                  if (item.notes.isNotEmpty)
                    _InfoBlock(
                      icon: Icons.menu_book_outlined,
                      label: '战术速记口诀',
                      value: item.notes,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  bool get _hasSecondaryDetails =>
      item.leakHandling.isNotEmpty ||
      item.firstAid.isNotEmpty ||
      item.appearance.isNotEmpty ||
      item.casNumber.isNotEmpty ||
      item.notes.isNotEmpty;

  Widget _buildWaterBanner() {
    if (item.isWaterForbidden) {
      return const AppBanner(
        text: '遇水属性：严禁用水（遇水可能剧烈反应、燃爆或释放有毒/易燃气体）',
        kind: AppBannerKind.danger,
        icon: Icons.no_drinks_rounded,
      );
    }
    if (item.isWaterReactive) {
      return const AppBanner(
        text: '遇水属性：慎用/剧烈反应（遇水热反应或放气，严格按战术规程控水）',
        kind: AppBannerKind.warning,
        icon: Icons.warning_amber_rounded,
      );
    }
    return AppCard(
      color: AppColors.safeSurface,
      side: BorderSide(color: AppColors.safe.withValues(alpha: 0.65)),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      child: Row(
        children: [
          Icon(Icons.water_drop_outlined, color: AppColors.safeText, size: 18),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              '遇水属性：可用水冷却或稀释控制（注意防流淌污染）',
              style: AppTextStyles.label.copyWith(
                color: AppColors.safeText,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _resolveCategoryBg(HazmatItem item) {
    switch (item.dangerSignColor) {
      case 'red':
        return AppColors.alarmSurface;
      case 'blue':
        return AppColors.noteInfo.withValues(alpha: 0.14);
      case 'yellow':
        return AppColors.cautionSurface;
      default:
        return AppColors.surfaceSubtle;
    }
  }

  Color _resolveCategoryFg(HazmatItem item) {
    switch (item.dangerSignColor) {
      case 'red':
        return AppColors.alarmText;
      case 'blue':
        return AppColors.noteInfo;
      case 'yellow':
        return AppColors.cautionText;
      default:
        return AppColors.textPrimary;
    }
  }
}

class _InfoBlock extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? highlightColor;

  const _InfoBlock({
    required this.icon,
    required this.label,
    required this.value,
    this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    final textValue = value.trim().isEmpty ? '暂无记录' : value.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: highlightColor ?? AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppTextStyles.label.copyWith(
                color: highlightColor ?? AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          textValue,
          style: AppTextStyles.bodyMd.copyWith(
            color: AppColors.textPrimary,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _MetricPill extends StatelessWidget {
  final String label;
  final String value;

  const _MetricPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        '$label：$value',
        style: AppTextStyles.caption.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
