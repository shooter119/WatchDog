import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import 'incident_import_page.dart';
import 'incident_key_site_section.dart';

typedef PhoneLauncher = Future<bool> Function(Uri uri);

class IncidentDetailsPage extends StatefulWidget {
  final AppController? controller;
  final ApiClient api;
  final Incident incident;
  final PhoneLauncher? phoneLauncher;
  const IncidentDetailsPage({
    super.key,
    this.controller,
    required this.api,
    required this.incident,
    this.phoneLauncher,
  });
  @override
  State<IncidentDetailsPage> createState() => _IncidentDetailsPageState();
}

class _IncidentDetailsPageState extends State<IncidentDetailsPage> {
  late final ApiClient _api = widget.api.forIncident(widget.incident.id);
  Map<String, dynamic>? _detail;
  String? _error;
  bool _busy = false;
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

  Future<void> _dialPhone(String rawPhone) async {
    final phone = rawPhone.trim();
    if (phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    final launcher =
        widget.phoneLauncher ??
        (value) => launchUrl(value, mode: LaunchMode.externalApplication);
    try {
      if (await launcher(uri)) return;
    } catch (_) {
      // Fall through to the same user-visible error for unsupported devices.
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开拨号界面')));
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
            if (widget.controller != null)
              IncidentKeySiteSection(
                controller: widget.controller!,
                incident: widget.incident,
              ),
            Text(
              widget.incident.displayName,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (_detail?['offline'] == true)
              Text(
                '当前显示本机缓存，联网后刷新可获取最新资料。',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: AppColors.alarm)),
              TextButton(onPressed: _load, child: const Text('重新读取')),
            ],
            if (_detail == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_detail != null) ...[
              if (data.isEmpty) const Text('尚未补充警情资料，可从首页导入图片或文字。'),
              for (final field in incidentFieldLabels.entries)
                if (data[field.key]?.toString().isNotEmpty == true)
                  _DetailField(
                    label: field.value,
                    value: data[field.key].toString(),
                  ),
              if (contacts.isNotEmpty) ...[
                const Divider(height: 20),
                const Padding(
                  padding: EdgeInsets.only(bottom: 2),
                  child: Text(
                    '岗位人员与联系方式',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                for (var i = 0; i < contacts.length; i++)
                  _ContactRow(
                    key: ValueKey('incident-contact-$i'),
                    role: contacts[i]['role']?.toString() ?? '',
                    name: contacts[i]['name']?.toString() ?? '',
                    phone: contacts[i]['phone']?.toString() ?? '',
                    onCall: _dialPhone,
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
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(item.toString()),
                          ),
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

class _DetailField extends StatelessWidget {
  final String label;
  final String value;

  const _DetailField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 1),
        SelectableText(
          value,
          style: TextStyle(
            fontSize: 15,
            height: 1.35,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    ),
  );
}

class _ContactRow extends StatelessWidget {
  final String role;
  final String name;
  final String phone;
  final ValueChanged<String> onCall;

  const _ContactRow({
    super.key,
    required this.role,
    required this.name,
    required this.phone,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedPhone = phone.trim();
    final label = [
      role,
      name,
    ].where((value) => value.trim().isNotEmpty).join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: normalizedPhone.isEmpty ? null : () => onCall(normalizedPhone),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (label.isNotEmpty)
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (normalizedPhone.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          normalizedPhone,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: AppColors.actionPrimary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (normalizedPhone.isNotEmpty)
                  Icon(
                    Icons.call_outlined,
                    size: 20,
                    color: AppColors.actionPrimary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
