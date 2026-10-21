import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/video_resources.dart';
import '../theme/app_widgets.dart';

class VideoResourceAdminPage extends StatefulWidget {
  final ApiClient api;

  const VideoResourceAdminPage({super.key, required this.api});

  @override
  State<VideoResourceAdminPage> createState() => _VideoResourceAdminPageState();
}

class _VideoResourceAdminPageState extends State<VideoResourceAdminPage> {
  List<VideoResource> _resources = const [];
  final Set<String> _busyIds = {};
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resources = await widget.api.fetchVideoResources(
        includeInactive: true,
      );
      if (mounted) setState(() => _resources = resources);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _validateUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) return '请输入完整的视频地址';
    if (uri.scheme != 'https') return '视频地址必须使用 HTTPS';
    if (uri.userInfo.isNotEmpty) return '视频地址不能包含用户名或密码';
    if (uri.hasFragment) return '视频地址不能包含 # 片段';
    return null;
  }

  Future<void> _edit([VideoResource? resource]) async {
    final name = TextEditingController(text: resource?.name ?? '');
    final description = TextEditingController(
      text: resource?.description ?? '',
    );
    final url = TextEditingController(text: resource?.streamUrl ?? '');
    var active = resource?.active ?? true;
    String? validationError;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(resource == null ? '新增视频资源' : '编辑视频资源'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    maxLength: 80,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '资源名称',
                      hintText: '如：营区东门监控',
                    ),
                  ),
                  TextField(
                    controller: description,
                    maxLength: 240,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '说明（选填）',
                      hintText: '如：用于观察营区东门',
                    ),
                  ),
                  TextField(
                    controller: url,
                    maxLength: 2048,
                    minLines: 2,
                    maxLines: 4,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'HTTP-FLV 视频地址',
                      hintText: 'https://…/live.flv',
                      helperText: '必须使用原始 FLV 地址，不能改为 m3u8',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('向本单位成员开放'),
                    subtitle: const Text('停用后普通成员不再看到该资源'),
                    value: active,
                    onChanged: (value) => setDialog(() => active = value),
                  ),
                  if (validationError != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        validationError!,
                        style: TextStyle(
                          color: AppColors.alarm,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
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
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setDialog(() => validationError = '请填写资源名称');
                  return;
                }
                final urlError = _validateUrl(url.text);
                if (urlError != null) {
                  setDialog(() => validationError = urlError);
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() {
        if (resource == null) {
          _creating = true;
        } else {
          _busyIds.add(resource.id);
        }
      });
      try {
        if (resource == null) {
          await widget.api.addVideoResource(
            name: name.text,
            streamUrl: url.text,
            description: description.text,
            active: active,
          );
        } else {
          await widget.api.updateVideoResource(
            resource.id,
            expectedVersion: resource.version,
            name: name.text,
            streamUrl: url.text,
            description: description.text,
            active: active,
          );
        }
        await _load();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
        }
      } finally {
        if (mounted) {
          setState(() {
            _creating = false;
            _busyIds.remove(resource?.id);
          });
        }
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      name.dispose();
      description.dispose();
      url.dispose();
    });
  }

  Future<void> _setActive(VideoResource resource, bool active) async {
    if (_busyIds.contains(resource.id)) return;
    setState(() => _busyIds.add(resource.id));
    try {
      final updated = await widget.api.updateVideoResource(
        resource.id,
        expectedVersion: resource.version,
        active: active,
      );
      if (!mounted) return;
      setState(() {
        _resources = _resources
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('状态更新失败：$error')));
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(resource.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('视频资源管理'),
        actions: [
          IconButton(
            tooltip: '新增视频资源',
            onPressed: _creating ? null : () => _edit(),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
          children: [
            Text(
              '仅管理员可维护；改地址后请立即测试，停用只隐藏不删除。',
              style: AppTextStyles.caption.copyWith(
                fontSize: 12.5,
                color: AppColors.textTertiary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              AppCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      '加载失败：$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(height: 1.5),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(onPressed: _load, child: const Text('重新加载')),
                  ],
                ),
              ),
            ],
            if (!_loading && _error == null && _resources.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 44),
                child: Column(
                  children: [
                    Icon(
                      Icons.video_library_outlined,
                      size: 46,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '尚未添加视频资源',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            for (final resource in _resources) ...[
              _AdminResourceCard(
                resource: resource,
                busy: _busyIds.contains(resource.id),
                onEdit: () => _edit(resource),
                onActiveChanged: (value) => _setActive(resource, value),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

class _AdminResourceCard extends StatelessWidget {
  final VideoResource resource;
  final bool busy;
  final VoidCallback onEdit;
  final ValueChanged<bool> onActiveChanged;

  const _AdminResourceCard({
    required this.resource,
    required this.busy,
    required this.onEdit,
    required this.onActiveChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Icon(
            resource.active
                ? Icons.videocam_rounded
                : Icons.videocam_off_outlined,
            color: resource.active
                ? AppColors.actionPrimary
                : AppColors.textTertiary,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: busy ? null : onEdit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resource.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      resource.active ? '已启用 · 点击编辑' : '已停用 · 点击编辑',
                      style: TextStyle(
                        fontSize: 12,
                        color: resource.active
                            ? AppColors.textSecondary
                            : AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Switch(
            value: resource.active,
            onChanged: busy ? null : onActiveChanged,
          ),
        ],
      ),
    );
  }
}
