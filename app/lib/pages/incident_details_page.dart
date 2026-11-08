import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/phone_caller.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';
import '../widgets/phone_text.dart';
import 'incident_import_page.dart';
import 'incident_key_site_section.dart';

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
    await PhoneCaller.dial(
      context,
      rawPhone,
      launcher: widget.phoneLauncher,
    );
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
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
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

  String _formatObsTime(dynamic raw) {
    final ms = (raw as num?)?.toInt();
    if (ms == null || ms == 0) return '录像语音';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)} · 录像语音';
  }

  @override
  Widget build(BuildContext context) {
    final data = Map<String, dynamic>.from(_detail?['data'] as Map? ?? {});
    final contacts = data['contacts'] as List? ?? [];
    final observations = _detail?['observations'] as List? ?? [];
    final basicFields = [
      for (final field in incidentFieldLabels.entries)
        if (data[field.key]?.toString().isNotEmpty == true) field,
    ];
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('警情详情'),
        actions: [
          if (widget.incident.isActive)
            IconButton(
              tooltip: '编辑警情资料',
              onPressed: _busy || _detail == null ? null : _edit,
              icon: const Icon(Icons.edit_outlined, size: 24),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (widget.controller != null)
              IncidentKeySiteSection(
                controller: widget.controller!,
                incident: widget.incident,
              ),
            Text(
              widget.incident.displayName,
              style: AppTextStyles.h2.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            if (_detail?['offline'] == true) ...[
              const AppBanner(
                kind: AppBannerKind.offline,
                text: '当前显示本机缓存，联网后刷新可获取最新资料。',
              ),
              const SizedBox(height: 12),
            ],
            if (_error != null) ...[
              AppNotice(
                kind: AppNoticeKind.error,
                text: _error!,
                action: TextButton(
                  onPressed: _load,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('重试'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_detail == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_detail != null) ...[
              if (data.isEmpty && observations.isEmpty)
                Text(
                  '尚未补充警情资料，可从首页导入图片或文字。',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              if (basicFields.isNotEmpty)
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < basicFields.length; i++) ...[
                        if (i > 0) const SizedBox(height: 12),
                        _DetailField(
                          label: basicFields[i].value,
                          value: data[basicFields[i].key].toString(),
                          phoneLauncher: widget.phoneLauncher,
                        ),
                      ],
                    ],
                  ),
                ),
              if (contacts.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s4),
                const SectionTitle(text: '岗位人员与联系方式'),
                AppCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s3,
                    vertical: AppSpacing.s2,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < contacts.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _ContactRow(
                          key: ValueKey('incident-contact-$i'),
                          role: contacts[i]['role']?.toString() ?? '',
                          name: contacts[i]['name']?.toString() ?? '',
                          phone: contacts[i]['phone']?.toString() ?? '',
                          onCall: _dialPhone,
                        ),
                      ],
                    ],
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
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s3),
                    child: AppCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s4,
                        vertical: AppSpacing.s1,
                      ),
                      child: Theme(
                        data: Theme.of(
                          context,
                        ).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(
                            bottom: AppSpacing.s2,
                          ),
                          title: Text(
                            field.value,
                            style: AppTextStyles.bodyMd.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          children: [
                            for (final item in data[field.key] as List)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    item.toString(),
                                    style: AppTextStyles.bodyMd.copyWith(
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              if (observations.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s3),
                  child: AppCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s4,
                      vertical: AppSpacing.s1,
                    ),
                    child: Theme(
                      data: Theme.of(
                        context,
                      ).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(
                          bottom: AppSpacing.s2,
                        ),
                        title: Text(
                          '录像语音记录 (${observations.length})',
                          style: AppTextStyles.bodyMd.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        children: [
                          for (final obs in observations)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(
                                  '${_formatObsTime(obs['captured_at'])}\n${obs['transcript'] ?? ''}',
                                  style: AppTextStyles.bodyMd.copyWith(
                                    color: AppColors.textSecondary,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              for (final record in _detail!['imports'] as List? ?? [])
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s3),
                  child: AppCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s4,
                      vertical: AppSpacing.s1,
                    ),
                    child: Theme(
                      data: Theme.of(
                        context,
                      ).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(
                          bottom: AppSpacing.s2,
                        ),
                        title: Text(
                          record['source'] == 'images' ? '图片导入记录' : '文字导入记录',
                          style: AppTextStyles.bodyMd.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          '确认人：${record['actor_name']}',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                        children: [
                          for (final p in record['pages'] as List)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: SelectableText(
                                '第${p['index']}页\n${p['raw_text']}',
                                style: AppTextStyles.bodyMd.copyWith(
                                  color: AppColors.textSecondary,
                                  height: 1.45,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
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
  final PhoneLauncher? phoneLauncher;

  const _DetailField({
    required this.label,
    required this.value,
    this.phoneLauncher,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
      ),
      const SizedBox(height: 2),
      PhoneText(
        value,
        style: AppTextStyles.bodyMd.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        phoneLauncher: phoneLauncher,
      ),
    ],
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: normalizedPhone.isEmpty
                      ? null
                      : () => onCall(normalizedPhone),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
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
                          const SizedBox(height: 2),
                          Text(
                            normalizedPhone,
                            style: AppTextStyles.bodyMd.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppColors.actionPrimary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (normalizedPhone.isNotEmpty) ...[
                const SizedBox(width: AppSpacing.s2),
                OutlinedButton.icon(
                  onPressed: () => onCall(normalizedPhone),
                  icon: const Icon(Icons.phone_outlined, size: 20),
                  label: const Text('拨打'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
