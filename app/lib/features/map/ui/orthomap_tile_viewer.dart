import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// 正射影像数据访问网关（隔离旧层 `AppController` / `ApiClient`）。
class OrthomapGateway {
  final Future<List<Map<String, dynamic>>> Function() fetchMaps;
  final String Function(String id, int z, int x, int y) mapTileUrl;
  final Map<String, String> Function() mapTileHeaders;
  final bool Function() isAuthenticated;
  final int Function() sessionTokenHash;
  final Listenable? authListenable;

  const OrthomapGateway({
    required this.fetchMaps,
    required this.mapTileUrl,
    required this.mapTileHeaders,
    required this.isAuthenticated,
    required this.sessionTokenHash,
    this.authListenable,
  });
}

/// 正射影像瓦片浏览页（按需瓦片、双指缩放、恢复全图、斜纹错误占位与重试）。
class OrthomapTileViewerPage extends StatefulWidget {
  final OrthomapGateway gateway;
  final Map<String, dynamic> map;

  const OrthomapTileViewerPage({
    super.key,
    required this.gateway,
    required this.map,
  });

  @override
  State<OrthomapTileViewerPage> createState() => _OrthomapTileViewerPageState();
}

class _OrthomapTileViewerPageState extends State<OrthomapTileViewerPage> {
  final TransformationController _transform = TransformationController();
  Size? _viewport;
  double _fit = 1;
  int _retry = 0;
  bool _tileFailed = false;

  @override
  void initState() {
    super.initState();
    widget.gateway.authListenable?.addListener(_onAuthChanged);
  }

  @override
  void didUpdateWidget(covariant OrthomapTileViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway.authListenable != widget.gateway.authListenable) {
      oldWidget.gateway.authListenable?.removeListener(_onAuthChanged);
      widget.gateway.authListenable?.addListener(_onAuthChanged);
    }
  }

  @override
  void dispose() {
    widget.gateway.authListenable?.removeListener(_onAuthChanged);
    _transform.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
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
    final ds = context.ds;
    final colors = ds.colors;
    if (!widget.gateway.isAuthenticated()) {
      return CommandScaffold(
        appBar: AppBar(title: const Text('现场地图')),
        body: const StatePlaceholder.empty(
          icon: Icons.lock_outline_rounded,
          message: '认证已失效，请返回后重新认证',
        ),
      );
    }

    final isDemo = widget.map['demo'] == true;
    final mapName = widget.map['name']?.toString() ?? '正射影像';
    final cautionPair = colors.statusColors(DsStatus.caution);
    final alarmPair = colors.statusColors(DsStatus.alarm);

    return CommandScaffold(
      appBar: AppBar(
        title: Text(mapName),
        actions: [
          IconButton(
            tooltip: '恢复全图',
            constraints: const BoxConstraints(
              minWidth: DsSizes.touchTarget,
              minHeight: DsSizes.touchTarget,
            ),
            iconSize: DsSizes.iconLg,
            onPressed: _viewport == null
                ? null
                : () => setState(() => _reset(_viewport!)),
            icon: const Icon(Icons.fit_screen),
          ),
        ],
      ),
      body: Column(
        children: [
          if (isDemo)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DsSpacing.pageMargin,
                DsSpacing.sm,
                DsSpacing.pageMargin,
                0,
              ),
              child: SurfaceCard(
                accentStatus: DsStatus.caution,
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.md,
                  vertical: DsSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: DsSizes.iconMd,
                      color: cautionPair.text,
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Expanded(
                      child: Text(
                        '演示影像 · 非真实现场 · 不可用于定位',
                        style: ds.typography.caption.copyWith(
                          color: cautionPair.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.pageMargin,
              vertical: DsSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Text(
              isDemo
                  ? '演示影像（非实景） · 仅验证查看功能，不可用于定位'
                  : '图片像素坐标 · 无经纬度定位 · 双指缩放，拖动查看',
              style: ds.typography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          if (_tileFailed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DsSpacing.pageMargin,
                DsSpacing.sm,
                DsSpacing.pageMargin,
                0,
              ),
              child: SurfaceCard(
                key: const Key('orthomap-tile-error-banner'),
                accentStatus: DsStatus.alarm,
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.md,
                  vertical: DsSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.broken_image_outlined,
                      size: DsSizes.iconMd,
                      color: alarmPair.text,
                    ),
                    const SizedBox(width: DsSpacing.sm),
                    Expanded(
                      child: Text(
                        '部分影像加载失败，请检查网络；认证过期请返回重登',
                        style: ds.typography.caption.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: DsSpacing.xs),
                    TextButton(
                      key: const Key('orthomap-tile-retry'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          DsSizes.touchTarget,
                          DsSizes.touchTarget,
                        ),
                        foregroundColor: colors.brandText,
                      ),
                      onPressed: () => setState(() {
                        _tileFailed = false;
                        _retry++;
                      }),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                if (_viewport != size && !size.isEmpty) {
                  _viewport = size;
                  _reset(size);
                }
                return ClipRect(
                  child: InteractiveViewer.builder(
                    transformationController: _transform,
                    minScale: _fit * 0.8,
                    maxScale: math.max(4, _fit * 8),
                    boundaryMargin: const EdgeInsets.all(256),
                    builder: (context, viewport) => _buildTiles(size),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTiles(Size viewport) {
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
    final tokenHash = widget.gateway.sessionTokenHash();
    final headers = widget.gateway.mapTileHeaders();
    final mapId = widget.map['id'] as String;

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
                  widget.gateway.mapTileUrl(mapId, zoom, x, y),
                  key: ValueKey('$tokenHash:$_retry:$zoom:$x:$y'),
                  headers: headers,
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
                    return const OrthomapTileFailureCell();
                  },
                ),
              ),
        ],
      ),
    );
  }
}

/// 瓦片加载失败单元格：斜条纹 + 浅底 + 居中感叹号，与真实地形阴影视觉区分。
class OrthomapTileFailureCell extends StatelessWidget {
  const OrthomapTileFailureCell({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.ds.colors;
    return Container(
      color: colors.surfaceMuted,
      child: CustomPaint(
        painter: _DiagonalStripePainter(stripeColor: colors.border),
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(DsSpacing.xs),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.error_outline_rounded,
              color: colors.textSecondary,
              size: DsSizes.iconLg,
            ),
          ),
        ),
      ),
    );
  }
}

class _DiagonalStripePainter extends CustomPainter {
  final Color stripeColor;

  const _DiagonalStripePainter({required this.stripeColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = stripeColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const step = 16.0;
    final maxD = size.width + size.height;
    for (double offset = -size.height; offset <= maxD; offset += step) {
      canvas.drawLine(
        Offset(offset, 0),
        Offset(offset + size.height, size.height),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DiagonalStripePainter oldDelegate) =>
      oldDelegate.stripeColor != stripeColor;
}
