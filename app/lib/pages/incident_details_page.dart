import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../models/models.dart';
import '../theme/app_widgets.dart';
import 'incident_import_page.dart';

class IncidentDetailsPage extends StatefulWidget {
  final ApiClient api;
  final Incident incident;
  const IncidentDetailsPage({
    super.key,
    required this.api,
    required this.incident,
  });
  @override
  State<IncidentDetailsPage> createState() => _IncidentDetailsPageState();
}

class _IncidentDetailsPageState extends State<IncidentDetailsPage> {
  late final ApiClient _api = widget.api.forIncident(widget.incident.id);
  Map<String, dynamic>? _detail;
  String? _error;
  bool _reveal = false, _busy = false;
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
    try {
      final value = await _api.fetchIncidentDetails();
      if (mounted) {
        setState(() {
          _detail = value;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _edit() async {
    final data = Map<String, dynamic>.from(_detail?['data'] as Map? ?? {});
    final controllers = {
      for (final key in incidentFieldLabels.keys)
        key: TextEditingController(text: data[key]?.toString() ?? ''),
    };
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改警情资料'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in controllers.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: c.value,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: incidentFieldLabels[c.key],
                        hintText: c.key == 'received_at'
                            ? 'YYYY-MM-DDTHH:mm:ss+08:00'
                            : null,
                      ),
                    ),
                  ),
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
    );
    if (save == true && mounted) {
      setState(() => _busy = true);
      try {
        await _api.updateIncidentDetails(
          {for (final c in controllers.entries) c.key: c.value.text.trim()},
          (_detail?['version'] as num?)?.toInt() ?? 0,
          'details-${DateTime.now().microsecondsSinceEpoch}',
        );
        await _load();
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    Future.delayed(const Duration(milliseconds: 300), () {
      for (final c in controllers.values) {
        c.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = Map<String, dynamic>.from(_detail?['data'] as Map? ?? {});
    final contacts = data['contacts'] as List? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('警情详情'),
        actions: [
          if (widget.incident.isActive)
            IconButton(
              tooltip: '编辑警情资料',
              onPressed: _busy || _detail == null ? null : _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.incident.displayName,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            if (_detail?['offline'] == true)
              const Text(
                '当前显示本机缓存，联网后刷新可获取最新资料。',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: AppColors.alarm)),
              TextButton(onPressed: _load, child: const Text('重新读取')),
            ],
            if (_detail == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_detail != null) ...[
              if (data.isEmpty) const Text('尚未补充警情资料，可从首页导入图片或文字。'),
              for (final field in incidentFieldLabels.entries)
                if (data[field.key]?.toString().isNotEmpty == true)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      field.value,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    subtitle: SelectableText(
                      data[field.key].toString(),
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
              if (contacts.isNotEmpty) ...[
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('岗位人员与联系方式'),
                  subtitle: const Text('联系方式仅用于本警情查看'),
                  value: _reveal,
                  onChanged: (v) => setState(() => _reveal = v),
                ),
                for (final c in contacts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${c['role']} · ${c['name']}'),
                    subtitle: Text(
                      _reveal
                          ? c['phone'].toString()
                          : _maskPhone(c['phone'].toString()),
                    ),
                  ),
              ],
              for (final field in {
                'risks': '风险信息',
                'to_confirm': '待核实事项',
                'vehicles': '车辆明细',
                'equipment': '通信装备',
                'channels': '通信频道',
              }.entries)
                if ((data[field.key] as List? ?? []).isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(field.value),
                    children: [
                      for (final item in data[field.key] as List)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(item.toString()),
                        ),
                    ],
                  ),
              for (final record in _detail!['imports'] as List? ?? [])
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    record['source'] == 'images' ? '图片导入记录' : '文字导入记录',
                  ),
                  subtitle: Text('确认人：${record['actor_name']}'),
                  children: [
                    for (final p in record['pages'] as List)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: SelectableText(
                          '第${p['index']}页\n${p['raw_text']}',
                        ),
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _maskPhone(String value) => value.length < 7
    ? '••••'
    : '${value.substring(0, 3)}••••${value.substring(value.length - 4)}';
