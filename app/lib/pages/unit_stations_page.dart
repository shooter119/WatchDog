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

  @override
  Widget build(BuildContext context) => Scaffold(
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
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '本单位成员均可新增。已有队伍的名称、别名和停用由管理员维护；修改不影响历史警情。',
            style: TextStyle(color: AppColors.textSecondary, height: 1.5),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error!, style: TextStyle(color: AppColors.alarm)),
            ),
          for (final station in _stations)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(station['name'].toString()),
              subtitle: Text(
                [
                  if (station['active'] == false) '已停用',
                  ...(station['aliases'] as List? ?? []).map(
                    (s) => s.toString(),
                  ),
                ].join(' · '),
              ),
              trailing: _manage
                  ? const Icon(Icons.edit_outlined, size: 18)
                  : null,
              onTap: _manage ? () => _edit(station) : null,
            ),
          if (!_busy && _stations.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Text('暂无常用队伍，可在此新增，也可导入警情时保存。'),
            ),
        ],
      ),
    ),
  );
}
