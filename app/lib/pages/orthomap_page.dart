import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

class OrthomapPage extends StatefulWidget {
  final AppController controller;
  const OrthomapPage({super.key, required this.controller});

  @override
  State<OrthomapPage> createState() => _OrthomapPageState();
}

class _OrthomapPageState extends State<OrthomapPage> {
  late Future<List<Map<String, dynamic>>> _maps;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = widget.controller.api;
    _maps = api == null ? Future.error('请先完成单位认证后查看地图') : api.fetchMaps();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(title: const Text('现场地图')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _maps,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '地图暂时无法加载，请检查网络或重新认证',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyMd.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  FilledButton(
                    onPressed: () => setState(_load),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final maps = snapshot.data!;
        if (maps.isEmpty) {
          return const Center(
            child: AppEmptyState(
              icon: Icons.map_outlined,
              title: '本单位暂无地图，请联系管理员导入影像',
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: maps.length,
          itemBuilder: (context, index) {
            final map = maps[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3,
                  vertical: AppSpacing.s2,
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        _MapViewer(controller: widget.controller, map: map),
                  ),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSubtle,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(
                          Icons.map_outlined,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              map['name'] as String,
                              style: AppTextStyles.bodyMd.copyWith(
                                height: 1.3,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.s1),
                            Text(
                              map['demo'] == true
                                  ? '演示影像 · 非真实现场，不可用于定位'
                                  : '正射影像 · 图片坐标，支持缩放和拖动',
                              style: AppTextStyles.caption.copyWith(
                                height: 1.3,
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: AppColors.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class _MapViewer extends StatefulWidget {
  final AppController controller;
  final Map<String, dynamic> map;
  const _MapViewer({required this.controller, required this.map});

  @override
  State<_MapViewer> createState() => _MapViewerState();
}

class _MapViewerState extends State<_MapViewer> {
  final _transform = TransformationController();
  Size? _viewport;
  double _fit = 1;
  int _retry = 0;
  bool _tileFailed = false;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _reset(Size size) {
    final width = (widget.map['width'] as num).toDouble();
    final height = (widget.map['height'] as num).toDouble();
    _fit = math.min(size.width / width, size.height / height);
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, _fit)
      ..setEntry(1, 1, _fit)
      ..setEntry(0, 3, (size.width - width * _fit) / 2)
      ..setEntry(1, 3, (size.height - height * _fit) / 2);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final api = widget.controller.api;
        if (api == null) {
          return Scaffold(
            backgroundColor: AppColors.background,
            appBar: AppBar(title: const Text('现场地图')),
            body: Center(
              child: Text(
                '认证已失效，请返回后重新认证',
                style: AppTextStyles.bodyMd.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          );
        }
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: Text(widget.map['name'] as String),
            actions: [
              IconButton(
                tooltip: '恢复全图',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => setState(() => _reset(_viewport!)),
                icon: const Icon(Icons.fit_screen),
              ),
            ],
          ),
          body: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s4,
                  vertical: AppSpacing.s2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSubtle,
                  border: Border(
                    bottom: BorderSide(color: AppColors.border),
                  ),
                ),
                child: Text(
                  widget.map['demo'] == true
                      ? '演示影像（非实景） · 仅验证查看功能，不可用于定位'
                      : '图片像素坐标 · 无经纬度定位 · 双指缩放，拖动查看',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              if (_tileFailed)
                MaterialBanner(
                  content: const Text('部分影像加载失败，请检查网络；认证过期请返回重登'),
                  actions: [
                    TextButton(
                      onPressed: () => setState(() {
                        _tileFailed = false;
                        _retry++;
                      }),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    if (_viewport != size) {
                      _viewport = size;
                      _reset(size);
                    }
                    return ClipRect(
                      child: InteractiveViewer.builder(
                        transformationController: _transform,
                        minScale: _fit * 0.8,
                        maxScale: math.max(4, _fit * 8),
                        boundaryMargin: const EdgeInsets.all(256),
                        builder: (context, viewport) => _tiles(api, size),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tiles(ApiClient api, Size viewport) {
    final width = (widget.map['width'] as num).toDouble();
    final height = (widget.map['height'] as num).toDouble();
    final maxZoom = widget.map['maxZoom'] as int;
    final scale = _transform.value.getMaxScaleOnAxis();
    final zoom = (maxZoom + math.log(scale) / math.ln2).ceil().clamp(
      0,
      maxZoom,
    );
    final factor = math.pow(2, maxZoom - zoom).toDouble();
    final span = 256 * factor;
    final topLeft = _transform.toScene(Offset.zero);
    final bottomRight = _transform.toScene(
      Offset(viewport.width, viewport.height),
    );
    final columns = (width / span).ceil();
    final rows = (height / span).ceil();
    final left = (topLeft.dx / span).floor().clamp(0, columns - 1);
    final right = (bottomRight.dx / span).floor().clamp(0, columns - 1);
    final top = (topLeft.dy / span).floor().clamp(0, rows - 1);
    final bottom = (bottomRight.dy / span).floor().clamp(0, rows - 1);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (var x = left; x <= right; x++)
            for (var y = top; y <= bottom; y++)
              Positioned(
                left: x * span,
                top: y * span,
                width: span,
                height: span,
                child: Image.network(
                  api.mapTileUrl(widget.map['id'] as String, zoom, x, y),
                  key: ValueKey(
                    '${api.sessionToken.hashCode}:$_retry:$zoom:$x:$y',
                  ),
                  headers: api.mapTileHeaders(),
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stack) {
                    if (!_tileFailed) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && !_tileFailed) {
                          setState(() => _tileFailed = true);
                        }
                      });
                    }
                    return ColoredBox(
                      color: AppColors.surfaceSubtle,
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    );
                  },
                ),
              ),
        ],
      ),
    );
  }
}
