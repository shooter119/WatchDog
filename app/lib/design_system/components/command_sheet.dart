import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/ds_theme.dart';
import '../tokens/ds_icons.dart';
import '../tokens/ds_motion.dart';
import '../tokens/ds_radius.dart';
import '../tokens/ds_sizes.dart';
import '../tokens/ds_spacing.dart';

/// 在模态底部弹出 [CommandSheet]，并显式转发调用方的 [ThemeData] 与关键 [MediaQueryData]
/// （如 `textScaler`、`disableAnimations`），同时保留模态路由自身的实时键盘 `viewInsets` 与安全区边距。
Future<T?> showCommandSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required WidgetBuilder builder,
  List<Widget>? actions,
  List<Widget> Function(BuildContext sheetContext)? actionsBuilder,
  bool showCloseButton = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    builder: (BuildContext routeContext) {
      return Theme(
        data: capturedTheme,
        child: MediaQuery(
          data: capturedMediaQuery.copyWith(
            viewInsets: MediaQuery.viewInsetsOf(routeContext),
            padding: MediaQuery.paddingOf(routeContext),
            viewPadding: MediaQuery.viewPaddingOf(routeContext),
          ),
          child: Builder(
            builder: (BuildContext sheetContext) => CommandSheet(
              title: title,
              subtitle: subtitle,
              showCloseButton: showCloseButton,
              actions: actionsBuilder?.call(sheetContext) ?? actions,
              child: builder(sheetContext),
            ),
          ),
        ),
      );
    },
  );
}

/// Design System v3.0 标准半屏底部弹窗容器。
///
/// 包含顶部拖拽手柄、标题/副标题与关闭按钮、自适应可滚动内容区、固定底部操作栏，
/// 以及键盘弹出时的底部 `viewInsets` 避让与安全区处理。
///
/// 说明：[child] 由内部 [SingleChildScrollView] 包裹；若传入 [ListView] 或
/// [GridView] 等可滚动组件，请设置 `shrinkWrap: true` 与
/// `physics: const NeverScrollableScrollPhysics()`。
class CommandSheet extends StatelessWidget {
  const CommandSheet({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions,
    this.showCloseButton = true,
    this.contentPadding,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget>? actions;
  final bool showCloseButton;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final colors = ds.colors;
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;

    final Color shadowColor = ds.brightness == Brightness.dark
        ? const Color(0x40000000)
        : const Color(0x1F000000);

    final bool hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    final bool hasActions = actions != null && actions!.isNotEmpty;
    final EdgeInsetsGeometry resolvedContentPadding =
        contentPadding ?? const EdgeInsets.all(DsSpacing.lg);

    final Widget dragHandle = Center(
      child: Padding(
        padding: const EdgeInsets.only(
          top: DsSpacing.sm + 2,
          bottom: DsSpacing.xs,
        ),
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: colors.border,
            borderRadius: DsRadius.borderPill,
          ),
        ),
      ),
    );

    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.xs,
        showCloseButton ? DsSpacing.sm : DsSpacing.lg,
        DsSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: ds.typography.headline.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (hasSubtitle) ...<Widget>[
                  const SizedBox(height: DsSpacing.xs),
                  Text(
                    subtitle!,
                    style: ds.typography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showCloseButton)
            IconButton(
              icon: const Icon(DsIcons.close),
              tooltip: '关闭',
              color: colors.textSecondary,
              constraints: const BoxConstraints(
                minWidth: DsSizes.touchTarget,
                minHeight: DsSizes.touchTarget,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
    );

    final Widget divider = Divider(height: 1, thickness: 1, color: colors.border);

    final Widget actionsBar = Padding(
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.md,
        DsSpacing.lg,
        DsSpacing.lg,
      ),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < (actions?.length ?? 0); i++) ...<Widget>[
            if (i > 0) const SizedBox(width: DsSpacing.md),
            Expanded(child: actions![i]),
          ],
        ],
      ),
    );

    return AnimatedPadding(
      duration: DsMotion.resolve(context, DsMotion.fast),
      curve: DsMotion.enter,
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints outerConstraints) {
          final double boundedOuter = outerConstraints.hasBoundedHeight
              ? outerConstraints.maxHeight
              : math.max(0.0, screenHeight - viewInsetsBottom);
          final double maxSheetHeight = math.max(
            0.0,
            math.min(boundedOuter, screenHeight * 0.88),
          );

          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxSheetHeight),
            child: Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(DsRadius.xl),
                ),
                border: Border(
                  top: BorderSide(color: colors.border, width: 1),
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(DsRadius.xl),
                ),
                child: SafeArea(
                  top: false,
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: (ScrollUpdateNotification notification) {
                      final FocusScopeNode currentScope = FocusScope.of(context);
                      if (notification.dragDetails != null &&
                          !currentScope.hasPrimaryFocus &&
                          currentScope.hasFocus) {
                        FocusManager.instance.primaryFocus?.unfocus();
                      }
                      return false;
                    },
                    child: Scrollable(
                      axisDirection: AxisDirection.down,
                      physics: const _TightOnlyScrollPhysics(),
                      viewportBuilder:
                          (BuildContext context, ViewportOffset position) {
                        return _CommandSheetViewport(
                          offset: position,
                          top: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              dragHandle,
                              header,
                              divider,
                            ],
                          ),
                          body: SingleChildScrollView(
                            primary: false,
                            physics: const _TightOnlyScrollPhysics(),
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: resolvedContentPadding,
                            child: child,
                          ),
                          bottom: hasActions
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    divider,
                                    actionsBar,
                                  ],
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 仅在存在可滚动余量或偏移尚未归零时接管手势的滚动物理规则，
/// 避免在 iOS/macOS 等默认注入 `AlwaysScrollableScrollPhysics` 的平台上
/// 抢占外层 [ModalBottomSheet] 的下拉关闭或紧致模式下的整表滚动手势。
class _TightOnlyScrollPhysics extends ClampingScrollPhysics {
  const _TightOnlyScrollPhysics({super.parent});

  @override
  _TightOnlyScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TightOnlyScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    return position.pixels != 0.0 ||
        position.minScrollExtent < position.maxScrollExtent;
  }
}

enum _CommandSheetSlot { top, body, bottom }

class _CommandSheetViewport
    extends SlottedMultiChildRenderObjectWidget<_CommandSheetSlot, RenderBox> {
  const _CommandSheetViewport({
    required this.offset,
    required this.top,
    required this.body,
    this.bottom,
  });

  final ViewportOffset offset;
  final Widget top;
  final Widget body;
  final Widget? bottom;

  @override
  Iterable<_CommandSheetSlot> get slots => _CommandSheetSlot.values;

  @override
  Widget? childForSlot(_CommandSheetSlot slot) {
    return switch (slot) {
      _CommandSheetSlot.top => top,
      _CommandSheetSlot.body => body,
      _CommandSheetSlot.bottom => bottom,
    };
  }

  @override
  _RenderCommandSheetViewport createRenderObject(BuildContext context) {
    return _RenderCommandSheetViewport(offset: offset);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCommandSheetViewport renderObject,
  ) {
    renderObject.offset = offset;
  }

  @override
  SlottedRenderObjectElement<_CommandSheetSlot, RenderBox> createElement() {
    return _CommandSheetViewportElement(this);
  }
}

class _CommandSheetViewportElement
    extends SlottedRenderObjectElement<_CommandSheetSlot, RenderBox>
    with NotifiableElementMixin, ViewportElementMixin {
  _CommandSheetViewportElement(_CommandSheetViewport super.widget);
}

class _RenderCommandSheetViewport extends RenderBox
    with SlottedContainerRenderObjectMixin<_CommandSheetSlot, RenderBox>
    implements RenderAbstractViewport {
  _RenderCommandSheetViewport({required ViewportOffset offset})
      : _offset = offset;

  static const double _minPinnedBodyHeight = DsSizes.touchTarget;

  ViewportOffset get offset => _offset;
  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) {
      return;
    }
    if (attached) {
      _offset.removeListener(_hasScrolled);
    }
    _offset = value;
    if (attached) {
      _offset.addListener(_hasScrolled);
    }
    markNeedsLayout();
  }

  double _topY = 0.0;
  double _bodyY = 0.0;
  double _bottomY = 0.0;
  double _contentHeight = 0.0;
  double _maxScrollExtent = 0.0;

  final LayerHandle<ClipRectLayer> _clipRectLayer =
      LayerHandle<ClipRectLayer>();

  double get _scrollY => _offset.hasPixels ? _offset.pixels : 0.0;

  bool get _needsClip =>
      _maxScrollExtent > 0.0 ||
      _scrollY != 0.0 ||
      _contentHeight > size.height;

  void _hasScrolled() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  Iterable<RenderBox> get children sync* {
    final RenderBox? top = childForSlot(_CommandSheetSlot.top);
    if (top != null) yield top;
    final RenderBox? body = childForSlot(_CommandSheetSlot.body);
    if (body != null) yield body;
    final RenderBox? bottom = childForSlot(_CommandSheetSlot.bottom);
    if (bottom != null) yield bottom;
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! ParentData) {
      child.parentData = ParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_hasScrolled);
  }

  @override
  void detach() {
    _offset.removeListener(_hasScrolled);
    super.detach();
  }

  @override
  void dispose() {
    _clipRectLayer.layer = null;
    super.dispose();
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final double topW =
        childForSlot(_CommandSheetSlot.top)?.getMinIntrinsicWidth(height) ??
            0.0;
    final double bodyW =
        childForSlot(_CommandSheetSlot.body)?.getMinIntrinsicWidth(height) ??
            0.0;
    final double bottomW =
        childForSlot(_CommandSheetSlot.bottom)?.getMinIntrinsicWidth(height) ??
            0.0;
    return math.max(topW, math.max(bodyW, bottomW));
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final double topW =
        childForSlot(_CommandSheetSlot.top)?.getMaxIntrinsicWidth(height) ??
            0.0;
    final double bodyW =
        childForSlot(_CommandSheetSlot.body)?.getMaxIntrinsicWidth(height) ??
            0.0;
    final double bottomW =
        childForSlot(_CommandSheetSlot.bottom)?.getMaxIntrinsicWidth(height) ??
            0.0;
    return math.max(topW, math.max(bodyW, bottomW));
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    final double topH =
        childForSlot(_CommandSheetSlot.top)?.getMinIntrinsicHeight(width) ??
            0.0;
    final double bodyH =
        childForSlot(_CommandSheetSlot.body)?.getMinIntrinsicHeight(width) ??
            0.0;
    final double bottomH =
        childForSlot(_CommandSheetSlot.bottom)?.getMinIntrinsicHeight(width) ??
            0.0;
    return topH + bodyH + bottomH;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    final double topH =
        childForSlot(_CommandSheetSlot.top)?.getMaxIntrinsicHeight(width) ??
            0.0;
    final double bodyH =
        childForSlot(_CommandSheetSlot.body)?.getMaxIntrinsicHeight(width) ??
            0.0;
    final double bottomH =
        childForSlot(_CommandSheetSlot.bottom)?.getMaxIntrinsicHeight(width) ??
            0.0;
    return topH + bodyH + bottomH;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? top = childForSlot(_CommandSheetSlot.top);
    final RenderBox? body = childForSlot(_CommandSheetSlot.body);
    final RenderBox? bottom = childForSlot(_CommandSheetSlot.bottom);

    final BoxConstraints chromeConstraints = constraints.hasBoundedWidth
        ? BoxConstraints(
            minWidth: constraints.maxWidth,
            maxWidth: constraints.maxWidth,
          )
        : constraints.widthConstraints();

    final Size topSize = top?.getDryLayout(chromeConstraints) ?? Size.zero;
    final Size bottomSize =
        bottom?.getDryLayout(chromeConstraints) ?? Size.zero;

    final double availableForBody = constraints.hasBoundedHeight
        ? math.max(
            0.0,
            constraints.maxHeight - topSize.height - bottomSize.height,
          )
        : double.infinity;
    final bool isTight = constraints.hasBoundedHeight &&
        availableForBody < _minPinnedBodyHeight;

    final BoxConstraints bodyConstraints = isTight
        ? chromeConstraints
        : chromeConstraints.copyWith(
            minHeight: 0.0,
            maxHeight: availableForBody,
          );
    final Size bodySize = body?.getDryLayout(bodyConstraints) ?? Size.zero;

    final double sheetWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : math.max(
            topSize.width,
            math.max(bodySize.width, bottomSize.width),
          );
    final double totalHeight =
        topSize.height + bodySize.height + bottomSize.height;
    final double targetHeight = constraints.hasBoundedHeight
        ? math.min(totalHeight, constraints.maxHeight)
        : totalHeight;
    return constraints.constrain(Size(sheetWidth, targetHeight));
  }

  @override
  void performLayout() {
    final RenderBox? top = childForSlot(_CommandSheetSlot.top);
    final RenderBox? body = childForSlot(_CommandSheetSlot.body);
    final RenderBox? bottom = childForSlot(_CommandSheetSlot.bottom);

    final BoxConstraints chromeConstraints = constraints.hasBoundedWidth
        ? BoxConstraints(
            minWidth: constraints.maxWidth,
            maxWidth: constraints.maxWidth,
          )
        : constraints.widthConstraints();

    double topH = 0.0;
    double topW = 0.0;
    if (top != null) {
      top.layout(chromeConstraints, parentUsesSize: true);
      topH = top.size.height;
      topW = top.size.width;
    }

    double bottomH = 0.0;
    double bottomW = 0.0;
    if (bottom != null) {
      bottom.layout(chromeConstraints, parentUsesSize: true);
      bottomH = bottom.size.height;
      bottomW = bottom.size.width;
    }

    final double availableForBody = constraints.hasBoundedHeight
        ? math.max(0.0, constraints.maxHeight - topH - bottomH)
        : double.infinity;
    final bool isTight = constraints.hasBoundedHeight &&
        availableForBody < _minPinnedBodyHeight;

    final BoxConstraints bodyConstraints = isTight
        ? chromeConstraints
        : chromeConstraints.copyWith(
            minHeight: 0.0,
            maxHeight: availableForBody,
          );

    double bodyH = 0.0;
    double bodyW = 0.0;
    if (body != null) {
      body.layout(bodyConstraints, parentUsesSize: true);
      bodyH = body.size.height;
      bodyW = body.size.width;
    }

    final double sheetWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : math.max(topW, math.max(bodyW, bottomW));
    final double totalHeight = topH + bodyH + bottomH;
    final double targetHeight = constraints.hasBoundedHeight
        ? math.min(totalHeight, constraints.maxHeight)
        : totalHeight;

    size = constraints.constrain(Size(sheetWidth, targetHeight));
    _contentHeight = totalHeight;
    _maxScrollExtent = math.max(0.0, totalHeight - size.height);

    _topY = 0.0;
    _bodyY = topH;
    _bottomY = totalHeight > size.height
        ? topH + bodyH
        : math.max(topH + bodyH, size.height - bottomH);

    if (_offset.hasPixels) {
      if (_offset.pixels > _maxScrollExtent) {
        _offset.correctBy(_maxScrollExtent - _offset.pixels);
      } else if (_offset.pixels < 0.0) {
        _offset.correctBy(-_offset.pixels);
      }
    }

    _offset.applyViewportDimension(size.height);
    _offset.applyContentDimensions(0.0, _maxScrollExtent);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    void paintChildren(PaintingContext context, Offset offset) {
      final double dy = -_scrollY;
      final RenderBox? body = childForSlot(_CommandSheetSlot.body);
      final RenderBox? top = childForSlot(_CommandSheetSlot.top);
      final RenderBox? bottom = childForSlot(_CommandSheetSlot.bottom);
      if (body != null) {
        context.paintChild(body, offset + Offset(0.0, _bodyY + dy));
      }
      if (top != null) {
        context.paintChild(top, offset + Offset(0.0, _topY + dy));
      }
      if (bottom != null) {
        context.paintChild(bottom, offset + Offset(0.0, _bottomY + dy));
      }
    }

    if (_needsClip) {
      _clipRectLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        paintChildren,
        clipBehavior: Clip.hardEdge,
        oldLayer: _clipRectLayer.layer,
      );
    } else {
      _clipRectLayer.layer = null;
      paintChildren(context, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_needsClip && !(Offset.zero & size).contains(position)) {
      return false;
    }
    final double dy = -_scrollY;
    final List<(RenderBox?, double)> ordered = <(RenderBox?, double)>[
      (childForSlot(_CommandSheetSlot.bottom), _bottomY + dy),
      (childForSlot(_CommandSheetSlot.top), _topY + dy),
      (childForSlot(_CommandSheetSlot.body), _bodyY + dy),
    ];
    for (final (RenderBox? child, double y) in ordered) {
      if (child == null) continue;
      final Offset childOffset = Offset(0.0, y);
      final bool hit = result.addWithPaintOffset(
        offset: childOffset,
        position: position,
        hitTest: (BoxHitTestResult result, Offset transformed) {
          assert(transformed == position - childOffset);
          return child.hitTest(result, position: transformed);
        },
      );
      if (hit) {
        return true;
      }
    }
    return false;
  }

  double _childOffsetY(RenderBox child) {
    final double dy = -_scrollY;
    if (identical(child, childForSlot(_CommandSheetSlot.top))) {
      return _topY + dy;
    }
    if (identical(child, childForSlot(_CommandSheetSlot.body))) {
      return _bodyY + dy;
    }
    if (identical(child, childForSlot(_CommandSheetSlot.bottom))) {
      return _bottomY + dy;
    }
    return 0.0;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final double y = _childOffsetY(child);
    transform.translateByDouble(0.0, y, 0.0, 1.0);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject? child) {
    if (child != null && _needsClip) {
      return Offset.zero & size;
    }
    return null;
  }

  @override
  Rect describeSemanticsClip(RenderObject child) {
    final double remainingOffset = math.max(0.0, _maxScrollExtent - _scrollY);
    return Rect.fromLTRB(
      semanticBounds.left,
      semanticBounds.top - _scrollY,
      semanticBounds.right,
      semanticBounds.bottom + remainingOffset,
    );
  }

  @override
  RevealedOffset getOffsetToReveal(
    RenderObject target,
    double alignment, {
    Rect? rect,
    Axis? axis,
  }) {
    rect ??= target.paintBounds;
    if (target is! RenderBox) {
      return RevealedOffset(offset: _scrollY, rect: rect);
    }

    RenderObject? slotChild = target;
    while (slotChild != null && slotChild.parent != this) {
      slotChild = slotChild.parent;
    }
    if (slotChild is! RenderBox) {
      return RevealedOffset(offset: _scrollY, rect: rect);
    }

    final double baseY;
    if (identical(slotChild, childForSlot(_CommandSheetSlot.top))) {
      baseY = _topY;
    } else if (identical(slotChild, childForSlot(_CommandSheetSlot.body))) {
      baseY = _bodyY;
    } else if (identical(slotChild, childForSlot(_CommandSheetSlot.bottom))) {
      baseY = _bottomY;
    } else {
      return RevealedOffset(offset: _scrollY, rect: rect);
    }

    final Matrix4 transform = target.getTransformTo(slotChild);
    final Rect boundsInSlot = MatrixUtils.transformRect(transform, rect);
    final Rect bounds = boundsInSlot.shift(Offset(0.0, baseY));
    final double targetOffset =
        bounds.top - (size.height - bounds.height) * alignment;
    final Rect targetRect = bounds.shift(Offset(0.0, -targetOffset));
    return RevealedOffset(offset: targetOffset, rect: targetRect);
  }

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!_offset.allowImplicitScrolling) {
      return super.showOnScreen(
        descendant: descendant,
        rect: rect,
        duration: duration,
        curve: curve,
      );
    }

    final Rect? newRect = RenderViewportBase.showInViewport(
      descendant: descendant,
      viewport: this,
      offset: _offset,
      rect: rect,
      duration: duration,
      curve: curve,
    );
    super.showOnScreen(rect: newRect, duration: duration, curve: curve);
  }
}
