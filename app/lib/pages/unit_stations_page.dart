import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../theme/app_widgets.dart';

class UnitStationsPage extends StatefulWidget {
  final ApiClient api;
  const UnitStationsPage({super.key, required this.api});
  @override
  State<UnitStationsPage> createState() => _UnitStationsPageState();
}

class _UnitStationsPageState extends State<UnitStationsPage> {
  late final ApiClient _api = widget.api.forIncident(widget.api.incidentId);
  List<Map<String, dynamic>> _stations = [];
  String? _error;
  bool _manage = false, _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final list = await _api.fetchUnitStations(includeInactive: true);
      Map<String, dynamic> access = {};
      try {
        access = await _api.unitStationAccess();
      } catch (_) {
        /* Cached directory remains readable offline; management is disabled. */
      }
      if (mounted) {
        setState(() {
          _stations = list;
          _manage = access['can_manage'] == true;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? station]) async {
    final name = TextEditingController(
      text: station?['name']?.toString() ?? '',
    );
    final aliases = TextEditingController(
      text: (station?['aliases'] as List? ?? []).join('\n'),
    );
    bool active = station?['active'] != false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(station == null ? '新增常用队伍' : '维护常用队伍'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    maxLength: 80,
                    decoration: const InputDecoration(labelText: '队伍名称'),
                  ),
                  if (station != null) ...[
                    TextField(
                      controller: aliases,
                      minLines: 2,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: '别名，每行一项',
                        helperText: '仅填写确认属于同一队伍的简称',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('可用于后续登记'),
                      value: active,
                      onChanged: (v) => setDialog(() => active = v),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      try {
        if (station == null) {
          await _api.addUnitStation(name.text.trim());
        } else {
          await _api.updateUnitStation(station['id'].toString(), {
            'name': name.text.trim(),
            'aliases': aliases.text
                .split('\n')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
            'active': active,
            'expected_version': station['version'],
          });
        }
        await _load();
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
    }
    Future.delayed(const Duration(milliseconds: 300), () {
      name.dispose();
      aliases.dispose();
    });
  }

  Widget _buildStationRow(Map<String, dynamic> station) {
    final isInactive = station['active'] == false;
    final aliases = (station['aliases'] as List? ?? [])
        .map((s) => s.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: _manage ? () => _edit(station) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      station['name'].toString(),
                      style: AppTextStyles.bodyMd.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (isInactive || aliases.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (isInactive)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.caution.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.pill,
                                ),
                              ),
                              child: Text(
                                '已停用',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.caution,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          for (final alias in aliases)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceSubtle,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.pill,
                                ),
                              ),
                              child: Text(
                                alias,
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (_manage) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: const Text('单位常用队伍'),
      actions: [
        IconButton(
          tooltip: '新增常用队伍',
          onPressed: _busy ? null : () => _edit(),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceSubtle,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              '仅管理员可编辑；修改不影响历史警情',
              style: AppTextStyles.caption.copyWith(
                fontSize: 12.5,
                color: AppColors.textTertiary,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _error!,
                style: AppTextStyles.bodyMd.copyWith(color: AppColors.alarm),
              ),
            ),
          for (final station in _stations) _buildStationRow(station),
          if (!_busy && _stations.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Icon(
                      Icons.groups_outlined,
                      size: 40,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '暂无常用队伍，可在此新增，也可导入警情时保存。',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyMd.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
