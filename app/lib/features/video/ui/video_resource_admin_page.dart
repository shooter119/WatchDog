import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/video_resource.dart';
import '../data/video_repository.dart';

/// 视频资源管理页（仅管理员可见，Design System v3.0）。
///
/// 通过同 Feature 内的 [VideoRepository] 执行视频监控源的新增、编辑与启停切换，
/// 严格校验 HTTPS 与原始 FLV 地址规则，停用只隐藏不删除。
class VideoResourceAdminPage extends StatefulWidget {
  const VideoResourceAdminPage({
    super.key,
    required this.repository,
    this.canManage = true,
    this.isOffline = false,
  });

  final VideoRepository repository;
  final bool canManage;
  final bool isOffline;

  @override
  State<VideoResourceAdminPage> createState() => _VideoResourceAdminPageState();
}

class _VideoResourceAdminPageState extends State<VideoResourceAdminPage> {
  List<VideoResource> _resources = const <VideoResource>[];
  final Set<String> _busyIds = <String>{};
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.canManage) {
      unawaited(_load());
    } else {
      _loading = false;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resources = await widget.repository.fetchVideoResources(
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
    final nameController = TextEditingController(text: resource?.name ?? '');
    final descController = TextEditingController(
      text: resource?.description ?? '',
    );
    final urlController = TextEditingController(
      text: resource?.streamUrl ?? '',
    );
    final activeNotifier = ValueNotifier<bool>(resource?.active ?? true);
    final errorNotifier = ValueNotifier<String?>(null);

    final saved = await showCommandSheet<bool>(
      context: context,
      title: resource == null ? '新增视频资源' : '编辑视频资源',
      builder: (BuildContext sheetContext) => _VideoResourceFormBody(
        nameController: nameController,
        descController: descController,
        urlController: urlController,
        activeNotifier: activeNotifier,
        errorNotifier: errorNotifier,
      ),
      actionsBuilder: (BuildContext sheetContext) => <Widget>[
        CommandButton(
          label: '取消',
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.large,
          onPressed: () => Navigator.of(sheetContext).pop(false),
        ),
        CommandButton(
          label: '保存',
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.large,
          onPressed: () {
            if (nameController.text.trim().isEmpty) {
              errorNotifier.value = '请填写资源名称';
              return;
            }
            final urlError = _validateUrl(urlController.text);
            if (urlError != null) {
              errorNotifier.value = urlError;
              return;
            }
            Navigator.of(sheetContext).pop(true);
          },
        ),
      ],
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
          await widget.repository.addVideoResource(
            name: nameController.text,
            streamUrl: urlController.text,
            description: descController.text,
            active: activeNotifier.value,
          );
        } else {
          await widget.repository.updateVideoResource(
            resource.id,
            expectedVersion: resource.version,
            name: nameController.text,
            streamUrl: urlController.text,
            description: descController.text,
            active: activeNotifier.value,
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
      nameController.dispose();
      descController.dispose();
      urlController.dispose();
      activeNotifier.dispose();
      errorNotifier.dispose();
    });
  }

  Future<void> _setActive(VideoResource resource, bool active) async {
    if (_busyIds.contains(resource.id)) return;
    setState(() => _busyIds.add(resource.id));
    try {
      final updated = await widget.repository.updateVideoResource(
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
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return CommandScaffold(
      isOffline: widget.isOffline,
      appBar: AppBar(
        title: const Text('视频资源管理'),
        actions: <Widget>[
          if (widget.canManage)
            IconButton(
              tooltip: '新增视频资源',
              constraints: const BoxConstraints(
                minWidth: DsSizes.touchTarget,
                minHeight: DsSizes.touchTarget,
              ),
              onPressed: _creating ? null : () => _edit(),
              icon: const Icon(DsIcons.add, size: DsSizes.iconLg),
            ),
        ],
      ),
      body: !widget.canManage
          ? const StatePlaceholder.empty(
              icon: DsIcons.lock,
              message: '仅管理员可维护视频资源',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  DsSpacing.pageMargin,
                  DsSpacing.md,
                  DsSpacing.pageMargin,
                  DsSpacing.xxl,
                ),
                children: <Widget>[
                  Text(
                    '仅管理员可维护；改地址后请立即测试，停用只隐藏不删除。',
                    style: typo.caption.copyWith(
                      color: colors.textTertiary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: DsSpacing.md),
                  if (_loading) ...<Widget>[
                    LinearProgressIndicator(
                      color: colors.brand,
                      backgroundColor: colors.surfaceMuted,
                    ),
                    const SizedBox(height: DsSpacing.md),
                  ],
                  if (_error != null) ...<Widget>[
                    SurfaceCard(
                      padding: EdgeInsets.zero,
                      child: StatePlaceholder.error(
                        icon: DsIcons.connOffline,
                        title: '加载失败',
                        reason: _error!,
                        retryLabel: '重新加载',
                        onRetry: _load,
                        padding: const EdgeInsets.all(DsSpacing.lg),
                      ),
                    ),
                    const SizedBox(height: DsSpacing.md),
                  ],
                  if (!_loading && _error == null && _resources.isEmpty)
                    const StatePlaceholder.empty(
                      icon: DsIcons.videoLibrary,
                      message: '尚未添加视频资源',
                    ),
                  for (final resource in _resources) ...<Widget>[
                    _AdminResourceCard(
                      resource: resource,
                      busy: _busyIds.contains(resource.id),
                      onEdit: () => _edit(resource),
                      onActiveChanged: (bool value) =>
                          _setActive(resource, value),
                    ),
                    const SizedBox(height: DsSpacing.cardGap),
                  ],
                ],
              ),
            ),
    );
  }
}

class _VideoResourceFormBody extends StatelessWidget {
  const _VideoResourceFormBody({
    required this.nameController,
    required this.descController,
    required this.urlController,
    required this.activeNotifier,
    required this.errorNotifier,
  });

  final TextEditingController nameController;
  final TextEditingController descController;
  final TextEditingController urlController;
  final ValueNotifier<bool> activeNotifier;
  final ValueNotifier<String?> errorNotifier;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final alarmPair = ds.colors.statusColors(DsStatus.alarm);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: nameController,
          maxLength: 80,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '资源名称',
            hintText: '如：营区东门监控',
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        TextField(
          controller: descController,
          maxLength: 240,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '说明（选填）',
            hintText: '如：用于观察营区东门',
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        TextField(
          controller: urlController,
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
        const SizedBox(height: DsSpacing.sm),
        ValueListenableBuilder<bool>(
          valueListenable: activeNotifier,
          builder: (BuildContext context, bool active, Widget? child) {
            return SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('向本单位成员开放'),
              subtitle: const Text('停用后普通成员不再看到该资源'),
              value: active,
              onChanged: (bool value) => activeNotifier.value = value,
            );
          },
        ),
        ValueListenableBuilder<String?>(
          valueListenable: errorNotifier,
          builder: (BuildContext context, String? error, Widget? child) {
            if (error == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: DsSpacing.sm),
              child: SurfaceCard(
                accentStatus: DsStatus.alarm,
                backgroundColor: alarmPair.pillBg,
                padding: const EdgeInsets.all(DsSpacing.md),
                child: Text(
                  error,
                  style: ds.typography.caption.copyWith(
                    color: alarmPair.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _AdminResourceCard extends StatelessWidget {
  const _AdminResourceCard({
    required this.resource,
    required this.busy,
    required this.onEdit,
    required this.onActiveChanged,
  });

  final VideoResource resource;
  final bool busy;
  final VoidCallback onEdit;
  final ValueChanged<bool> onActiveChanged;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final typo = ds.typography;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.md,
        DsSpacing.md,
        DsSpacing.sm,
        DsSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Icon(
            resource.active
                ? DsIcons.video
                : DsIcons.videoOff,
            color: resource.active ? colors.brandText : colors.textTertiary,
            size: DsSizes.iconLg,
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: InkWell(
              borderRadius: DsRadius.borderSm,
              onTap: busy ? null : onEdit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      resource.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typo.title.copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: DsSpacing.xs),
                    Wrap(
                      spacing: DsSpacing.sm,
                      runSpacing: DsSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        StatusPill(
                          status: resource.active
                              ? DsStatus.safe
                              : DsStatus.neutral,
                          icon: resource.active
                              ? DsIcons.checkCircle
                              : DsIcons.videoOff,
                          label: resource.active ? '已启用' : '已停用',
                        ),
                        Text(
                          '点击编辑',
                          style: typo.caption.copyWith(
                            color: colors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          Switch(
            value: resource.active,
            onChanged: busy ? null : onActiveChanged,
          ),
        ],
      ),
    );
  }
}
