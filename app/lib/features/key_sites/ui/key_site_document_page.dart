import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../data/models/key_sites.dart';
import 'key_site_gate.dart';

/// PDF、DOCX 正式阅读版及图片均使用服务端逐页预览；不会下载私有原始上传文件。
class KeySiteDocumentPage extends StatelessWidget {
  const KeySiteDocumentPage({
    super.key,
    required this.gateway,
    required this.site,
    required this.attachment,
    this.initialPage = 1,
    this.incidentId,
    this.map = false,
  });

  final KeySiteGateway gateway;
  final KeySiteVersion site;
  final Map<String, dynamic> attachment;
  final int initialPage;
  final String? incidentId;
  final bool map;

  @override
  Widget build(BuildContext context) => KeySiteGate(
    gateway: gateway,
    builder: (_) => KeySitePublishedSnapshot(
      gateway: gateway,
      site: site,
      incidentId: incidentId,
      builder: (current) => _DocumentViewer(
        gateway: gateway,
        site: current,
        attachment: current.attachments.firstWhere(
          (a) => a['id'] == attachment['id'],
          orElse: () => attachment,
        ),
        initialPage: initialPage,
        incidentId: incidentId,
        map: map,
      ),
    ),
  );
}

class _DocumentViewer extends StatefulWidget {
  const _DocumentViewer({
    required this.gateway,
    required this.site,
    required this.attachment,
    required this.initialPage,
    required this.map,
    this.incidentId,
  });

  final KeySiteGateway gateway;
  final KeySiteVersion site;
  final Map<String, dynamic> attachment;
  final int initialPage;
  final String? incidentId;
  final bool map;

  @override
  State<_DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<_DocumentViewer> {
  late int _page;
  final TransformationController _transform = TransformationController();
  int _reset = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Widget _buildNavButton({
    required String tooltip,
    required IconData icon,
    required bool enabled,
    required VoidCallback? onPressed,
    required DsColors colors,
  }) => IconButton.outlined(
    tooltip: tooltip,
    style: IconButton.styleFrom(
      minimumSize: const Size(52, 52),
      fixedSize: const Size(52, 52),
      padding: EdgeInsets.zero,
      side: BorderSide(color: colors.border),
      shape: RoundedRectangleBorder(borderRadius: DsRadius.borderMd),
    ),
    onPressed: onPressed,
    icon: Icon(icon, color: enabled ? colors.textPrimary : colors.textTertiary),
  );

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final metadata = widget.attachment['metadata'] as Map? ?? const {};
    final count = (metadata['pages'] as num?)?.toInt() ?? 1;
    final filename = widget.attachment['filename']?.toString() ?? '附件阅读';

    return CommandScaffold(
      appBar: AppBar(title: Text(filename)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.pageMargin,
              vertical: DsSpacing.sm,
            ),
            child: Text(
              '${widget.site.name} · v${widget.site.version}'
              '${widget.map ? ' · 图片像素坐标，不提供定位导航' : ''}',
              style: ds.typography.captionTabular.copyWith(
                color: colors.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: widget.map
                ? _PixelMapCanvas(
                    key: ValueKey<String>('map-$_page-$_reset'),
                    gateway: widget.gateway,
                    site: widget.site,
                    attachmentId: widget.attachment['id'] as String,
                    page: _page,
                    metadata: Map<String, dynamic>.from(
                      (metadata['mapPages'] as Map?)?['$_page'] as Map? ??
                          const {},
                    ),
                    incidentId: widget.incidentId,
                    transform: _transform,
                  )
                : InteractiveViewer(
                    transformationController: _transform,
                    minScale: 0.2,
                    maxScale: 12,
                    child: Center(
                      child: KeySiteImage(
                        key: ValueKey<int>(_page),
                        gateway: widget.gateway,
                        site: widget.site,
                        attachmentId: widget.attachment['id'] as String,
                        resource: 'pages/$_page.jpg',
                        incidentId: widget.incidentId,
                      ),
                    ),
                  ),
          ),
          _buildBottomBar(ds, count),
        ],
      ),
    );
  }

  Widget _buildBottomBar(DsTheme ds, int count) {
    final colors = ds.colors;
    void stepPage(int delta) => setState(() {
      _page += delta;
      _transform.value = Matrix4.identity();
    });
    return Padding(
      padding: const EdgeInsets.all(DsSpacing.sm),
      child: SurfaceCard(
        level: DsSurfaceLevel.flat,
        borderColor: colors.border,
        borderRadius: DsRadius.borderMd,
        padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.md,
          vertical: DsSpacing.sm,
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: DsSpacing.md,
          runSpacing: DsSpacing.sm,
          children: <Widget>[
            _buildNavButton(
              tooltip: '上一页',
              icon: Icons.chevron_left_rounded,
              enabled: _page > 1,
              colors: colors,
              onPressed: _page > 1 ? () => stepPage(-1) : null,
            ),
            Text(
              '第 $_page / $count 页',
              style: ds.typography.bodyTabular.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
            _buildNavButton(
              tooltip: '下一页',
              icon: Icons.chevron_right_rounded,
              enabled: _page < count,
              colors: colors,
              onPressed: _page < count ? () => stepPage(1) : null,
            ),
            CommandButton(
              label: widget.map ? '恢复全图' : '恢复整页',
              icon: Icons.fit_screen_rounded,
              variant: CommandButtonVariant.secondary,
              size: CommandButtonSize.standard,
              onPressed: () => setState(() {
                _transform.value = Matrix4.identity();
                _reset++;
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// 鉴权资料图像组件：仅内存解码，销毁时主动驱逐图片缓存，不写入磁盘。
class KeySiteImage extends StatefulWidget {
  const KeySiteImage({
    super.key,
    required this.gateway,
    required this.site,
    required this.attachmentId,
    required this.resource,
    this.fit = BoxFit.contain,
    this.onResult,
    this.incidentId,
  });

  final KeySiteGateway gateway;
  final KeySiteVersion site;
  final String attachmentId;
  final String resource;
  final BoxFit fit;
  final ValueChanged<Object?>? onResult;
  final String? incidentId;

  @override
  State<KeySiteImage> createState() => _KeySiteImageState();
}

class _KeySiteImageState extends State<KeySiteImage> {
  late Future<Uint8List> _bytes;
  MemoryImage? _provider;
  bool _reportedSuccess = false;
  bool _reportedFailure = false;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  Future<Uint8List> _load() => widget.gateway.fetchKeySiteImage(
    widget.site.siteId,
    widget.site.version,
    widget.attachmentId,
    resource: widget.resource,
    incident: widget.incidentId,
  );

  @override
  void dispose() {
    _provider?.evict();
    super.dispose();
  }

  void _report(Object? error) {
    if (widget.onResult == null ||
        (error == null ? _reportedSuccess : _reportedFailure)) {
      return;
    }
    if (error == null) {
      _reportedSuccess = true;
    } else {
      _reportedFailure = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onResult?.call(error);
    });
  }

  Widget _failure(BuildContext context, Object error) {
    _report(error);
    if (widget.onResult != null) {
      return ColoredBox(color: context.ds.colors.surfaceMuted);
    }
    void retry() => setState(() {
      _provider?.evict();
      _provider = null;
      _bytes = _load();
    });
    return widget.fit == BoxFit.fill
        ? Center(
            child: IconButton(
              tooltip: '${keySiteError(error)}，点击重试',
              constraints: const BoxConstraints(
                minWidth: DsSizes.touchTarget,
                minHeight: DsSizes.touchTarget,
              ),
              onPressed: retry,
              icon: const Icon(Icons.refresh_rounded),
            ),
          )
        : KeySiteFailure(error: error, retry: retry);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) return _failure(context, snapshot.error!);
      if (!snapshot.hasData) {
        return widget.onResult == null
            ? const Center(child: CircularProgressIndicator())
            : ColoredBox(color: context.ds.colors.surfaceMuted);
      }
      _report(null);
      _provider ??= MemoryImage(snapshot.data!);
      return Image(
        image: _provider!,
        fit: widget.fit,
        errorBuilder: (ctx, error, _) => _failure(ctx, error),
      );
    },
  );
}

class _PixelMapCanvas extends StatefulWidget {
  const _PixelMapCanvas({
    super.key,
    required this.gateway,
    required this.site,
    required this.attachmentId,
    required this.page,
    required this.metadata,
    required this.incidentId,
    required this.transform,
  });

  final KeySiteGateway gateway;
  final KeySiteVersion site;
  final String attachmentId;
  final int page;
  final Map<String, dynamic> metadata;
  final String? incidentId;
  final TransformationController transform;

  @override
  State<_PixelMapCanvas> createState() => _PixelMapCanvasState();
}

class _PixelMapCanvasState extends State<_PixelMapCanvas> {
  Object? _failure;
  bool _loaded = false;
  int _retry = 0;
  Size? _viewport;
  double _fit = 1;

  void _tileResult(Object? error) {
    if (!mounted) return;
    if (error != null && _failure == null) {
      setState(() => _failure = error);
    } else if (error == null && !_loaded) {
      setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = (widget.metadata['width'] as num?)?.toDouble() ?? 0;
    final height = (widget.metadata['height'] as num?)?.toDouble() ?? 0;
    if (width <= 0 || height <= 0) {
      return const StatePlaceholder.empty(
        icon: Icons.map_outlined,
        message: '地图切片不可用，请联系资料维护人员',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_viewport != size && size.width > 0 && size.height > 0) {
          _viewport = size;
          _fit = math.min(size.width / width, size.height / height);
          widget.transform.value = Matrix4.identity()
            ..setEntry(0, 0, _fit)
            ..setEntry(1, 1, _fit)
            ..setEntry(0, 3, (size.width - width * _fit) / 2)
            ..setEntry(1, 3, (size.height - height * _fit) / 2);
        }
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ClipRect(
              child: InteractiveViewer.builder(
                transformationController: widget.transform,
                minScale: _fit * 0.8,
                maxScale: math.max(4, _fit * 8),
                boundaryMargin: const EdgeInsets.all(256),
                builder: (context, _) => _tiles(size, width, height),
              ),
            ),
            if (!_loaded && _failure == null)
              const Center(child: CircularProgressIndicator()),
            // 错误重试覆盖层位于缩放变换之外，全图缩放下依然保持清晰可读可点。
            if (_failure != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Padding(
                  padding: const EdgeInsets.all(DsSpacing.sm),
                  child: KeySiteStatusBanner(
                    key: const ValueKey<String>('key-site-map-error-banner'),
                    status: DsStatus.alarm,
                    icon: Icons.cloud_off_rounded,
                    message: '部分图纸加载失败：${keySiteError(_failure!)}',
                    actionLabel: '重试地图',
                    onAction: () => setState(() {
                      _failure = null;
                      _loaded = false;
                      _retry++;
                    }),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _tiles(Size viewport, double width, double height) {
    final maxZoom = (widget.metadata['maxZoom'] as num?)?.toInt() ?? 0;
    final scale = widget.transform.value.getMaxScaleOnAxis();
    final zoom = (maxZoom + math.log(scale) / math.ln2).ceil().clamp(
      0,
      maxZoom,
    );
    final span = 256 * math.pow(2, maxZoom - zoom).toDouble();
    final first = widget.transform.toScene(Offset.zero);
    final last = widget.transform.toScene(
      Offset(viewport.width, viewport.height),
    );
    final columns = (width / span).ceil(), rows = (height / span).ceil();
    final left = (first.dx / span).floor().clamp(0, columns - 1),
        right = (last.dx / span).floor().clamp(0, columns - 1);
    final top = (first.dy / span).floor().clamp(0, rows - 1),
        bottom = (last.dy / span).floor().clamp(0, rows - 1);

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          for (var x = left; x <= right; x++)
            for (var y = top; y <= bottom; y++)
              Positioned(
                left: x * span,
                top: y * span,
                width: span,
                height: span,
                child: KeySiteImage(
                  key: ValueKey<String>('${widget.page}:$_retry:$zoom:$x:$y'),
                  onResult: _tileResult,
                  gateway: widget.gateway,
                  site: widget.site,
                  attachmentId: widget.attachmentId,
                  resource: 'maps/${widget.page}/tiles/$zoom/$x/$y.jpg',
                  incidentId: widget.incidentId,
                  fit: BoxFit.fill,
                ),
              ),
        ],
      ),
    );
  }
}
