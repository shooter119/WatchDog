import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../models/models.dart';
import '../models/key_sites.dart';
import '../state/app_controller.dart';
import 'key_sites_page.dart';

class IncidentKeySiteSection extends StatelessWidget {
  final AppController controller;
  final Incident incident;
  const IncidentKeySiteSection({
    super.key,
    required this.controller,
    required this.incident,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.canReadKeySites) return const SizedBox.shrink();
      return _IncidentLink(
        key: ValueKey('${controller.protectedDataEpoch}:${incident.id}'),
        controller: controller,
        api: controller.api!,
        incident: incident,
      );
    },
  );
}

class _IncidentLink extends StatefulWidget {
  final AppController controller;
  final ApiClient api;
  final Incident incident;
  const _IncidentLink({
    super.key,
    required this.controller,
    required this.api,
    required this.incident,
  });
  @override
  State<_IncidentLink> createState() => _IncidentLinkState();
}

class _IncidentLinkState extends State<_IncidentLink> {
  Map<String, dynamic>? _state;
  Object? _error;
  bool _busy = false;
  bool _saving = false;
  int _generation = 0;
  Timer? _refresh;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_busy && !_loading && widget.controller.canReadKeySites) _load();
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _IncidentLink oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incident.keySiteLinkRevision !=
        widget.incident.keySiteLinkRevision) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _loading = true;
    try {
      final data = await widget.api.fetchIncidentKeySite(widget.incident.id);
      if (mounted && generation == _generation) {
        setState(() {
          _state = data;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = e);
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  Future<void> _change({bool remove = false, bool update = false}) async {
    final epoch = widget.controller.protectedDataEpoch;
    setState(() => _busy = true);
    // Capture the revision being reviewed; later collaborative changes must conflict.
    final revision =
        (_state?['revision'] as num?)?.toInt() ??
        widget.incident.keySiteLinkRevision;
    try {
      KeySiteVersion? site;
      if (!remove) {
        String? id;
        if (update) {
          id = (_state?['link'] as Map?)?['siteId']?.toString();
        } else {
          final selected = await Navigator.push<KeySiteSummary>(
            context,
            MaterialPageRoute(
              builder: (_) => KeySitesPage(
                controller: widget.controller,
                selectForIncident: true,
              ),
            ),
          );
          id = selected?.id;
        }
        if (!mounted ||
            !widget.controller.canReadKeySites ||
            epoch != widget.controller.protectedDataEpoch ||
            id == null) {
          return;
        }
        site = await widget.api.fetchKeySite(id);
      }
      if (!mounted ||
          !widget.controller.canReadKeySites ||
          epoch != widget.controller.protectedDataEpoch) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) =>
              !widget.controller.canReadKeySites ||
                  epoch != widget.controller.protectedDataEpoch
              ? const AlertDialog(content: Text('认证已失效，请重新认证'))
              : AlertDialog(
                  title: Text(remove ? '解除重点单位关联' : '核对重点单位'),
                  content: SingleChildScrollView(
                    child: Text(
                      remove
                          ? '解除后仍保留警情历史引用和操作记录。'
                          : '${site!.name}\n${site.address}\n\n确认关联已发布资料 v${site.version}？新版发布后需人工核对更新。',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认'),
                    ),
                  ],
                ),
        ),
      );
      if (confirmed != true ||
          !mounted ||
          !widget.controller.canReadKeySites ||
          epoch != widget.controller.protectedDataEpoch) {
        return;
      }
      setState(() => _saving = true);
      await widget.controller.changeKeySiteLink(
        widget.incident.id,
        revision: revision,
        site: site,
        operationId:
            'site-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
      );
      await _load();
    } catch (e) {
      await _load();
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _saving = false;
        });
      }
    }
  }

  void _open(String id, int version) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => KeySitePage(
        controller: widget.controller,
        siteId: id,
        version: version,
        incidentId: widget.incident.id,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final raw = _state?['link'];
    final link = raw is Map
        ? IncidentKeySiteLink.fromJson(Map<String, dynamic>.from(raw))
        : (_state == null ? widget.incident.keySiteLink : null);
    final history = _state?['history'] as List? ?? [];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('关联重点单位', style: TextStyle(fontWeight: FontWeight.w700)),
          if (link != null) ...[
            Text(
              '${link.name}\n${link.address}\n资料 v${link.version} · ${link.linkedByName}确认',
            ),
            if (_state?['newVersionAvailable'] == true)
              const Text('已有新版资料，请人工核对后更新'),
            if (_state?['active'] == false) const Text('重点单位已停用，保留历史引用'),
          ],
          if (_error != null) Text(keySiteError(_error!)),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (link != null)
                OutlinedButton.icon(
                  onPressed: () => _open(link.siteId, link.version),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('单位资料'),
                ),
              if (widget.incident.isActive) ...[
                TextButton(
                  onPressed: _busy || _state == null ? null : _change,
                  child: Text(link == null ? '搜索并关联' : '更换'),
                ),
                if (link != null)
                  TextButton(
                    onPressed: _busy ? null : () => _change(remove: true),
                    child: const Text('解除'),
                  ),
                if (_state?['newVersionAvailable'] == true &&
                    _state?['active'] == true)
                  TextButton(
                    onPressed: _busy ? null : () => _change(update: true),
                    child: const Text('核对新版'),
                  ),
              ],
              if (_error != null)
                TextButton(
                  onPressed: _busy ? null : _load,
                  child: const Text('重试'),
                ),
            ],
          ),
          if (history.isNotEmpty)
            ExpansionTile(
              title: const Text('历史资料引用'),
              tilePadding: EdgeInsets.zero,
              children: history.map((item) {
                final row = item as Map;
                final profile = row['profile'] as Map;
                return ListTile(
                  title: Text('${profile['name']} · v${row['version']}'),
                  subtitle: Text(
                    '${profile['address']}\n${row['first_linked_by']} · ${DateTime.fromMillisecondsSinceEpoch((row['first_linked_at'] as num).toInt())}',
                  ),
                  onTap: () => _open(
                    row['site_id'] as String,
                    (row['version'] as num).toInt(),
                  ),
                );
              }).toList(),
            ),
          if (_saving) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
