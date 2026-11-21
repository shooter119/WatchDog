import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../state/location_share_store.dart';
import 'location_share_cards.dart';

export '../state/location_share_store.dart';

/// 弹出「定位分享」半屏弹窗（Design System v3.0 `CommandSheet`）。
Future<void> showLocationShareSheet(
  BuildContext context, {
  required LocationShareGateway gateway,
  required String Function() readIncidentName,
  Future<String> Function()? readUnitName,
}) {
  final capturedTheme = Theme.of(context);
  final capturedMediaQuery = MediaQuery.of(context);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (routeContext) {
      return Theme(
        data: capturedTheme,
        child: MediaQuery(
          data: capturedMediaQuery.copyWith(
            viewInsets: MediaQuery.viewInsetsOf(routeContext),
            padding: MediaQuery.paddingOf(routeContext),
            viewPadding: MediaQuery.viewPaddingOf(routeContext),
          ),
          child: LocationShareSheet(
            gateway: gateway,
            readIncidentName: readIncidentName,
            readUnitName: readUnitName,
          ),
        ),
      );
    },
  );
}

/// 定位分享底部弹窗主体（基于 `CommandSheet` + `SurfaceCard`）。
class LocationShareSheet extends StatefulWidget {
  final LocationShareStore? store;
  final LocationShareGateway? gateway;
  final String Function()? readIncidentName;
  final Future<String> Function()? readUnitName;

  const LocationShareSheet({
    super.key,
    this.store,
    this.gateway,
    this.readIncidentName,
    this.readUnitName,
  }) : assert(
         store != null || gateway != null,
         'LocationShareSheet requires either store or gateway',
       );

  @override
  State<LocationShareSheet> createState() => _LocationShareSheetState();
}

class _LocationShareSheetState extends State<LocationShareSheet> {
  late final LocationShareStore _store;
  late final bool _ownsStore;

  @override
  void initState() {
    super.initState();
    _ownsStore = widget.store == null;
    _store =
        widget.store ??
        LocationShareStore(
          gateway: widget.gateway!,
          readIncidentName: widget.readIncidentName ?? () => '',
          readUnitName: widget.readUnitName,
        );
    _store.addListener(_onStoreChanged);
    unawaited(_store.loadLocation());
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    if (_ownsStore) _store.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handleCopy() async {
    final msg = await _store.copy();
    if (msg != null) _toast(msg);
  }

  Future<void> _handleShare() async {
    final msg = await _store.share();
    if (msg != null) _toast(msg);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return CommandSheet(
      key: const Key('location-share-sheet'),
      title: '定位分享',
      actions: [_buildActionBar(context)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '分享的是纯文本与单个高德位置链接，微信收到后点击可查看位置并在页面内发起驾车导航（支持时自动尝试拉起高德 App）。',
            style: ds.typography.caption.copyWith(
              height: 1.5,
              color: ds.colors.textSecondary,
            ),
          ),
          const SizedBox(height: DsSpacing.md),
          _buildPhaseBody(context),
        ],
      ),
    );
  }

  Widget _buildPhaseBody(BuildContext context) {
    switch (_store.phase) {
      case LocationSharePhase.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: DsSpacing.xl),
          child: StatePlaceholder.loading(
            message: '正在获取定位并查询地址…',
            padding: EdgeInsets.zero,
          ),
        );
      case LocationSharePhase.permissionDenied:
        return LocationShareProblemCard(
          icon: Icons.location_disabled_outlined,
          title: '定位权限未授权',
          body: '需要在系统权限中允许“火场智控”使用定位，才能生成现场位置。',
          actions: [
            CommandButton(
              key: const Key('location-share-relocate'),
              label: '重新申请定位权限',
              icon: Icons.my_location_rounded,
              expanded: true,
              onPressed: () => unawaited(_store.loadLocation()),
            ),
            CommandButton(
              key: const Key('location-share-app-settings'),
              label: '打开应用设置',
              icon: Icons.settings_outlined,
              variant: CommandButtonVariant.secondary,
              expanded: true,
              onPressed: () => unawaited(_store.gateway.openAppSettings()),
            ),
          ],
        );
      case LocationSharePhase.serviceDisabled:
        return LocationShareProblemCard(
          icon: Icons.wrong_location_outlined,
          title: '定位服务未开启',
          body: '请打开手机定位服务，再返回这里重新定位。',
          actions: [
            CommandButton(
              key: const Key('location-share-relocate'),
              label: '重新定位',
              icon: Icons.my_location_rounded,
              expanded: true,
              onPressed: () => unawaited(_store.loadLocation()),
            ),
            CommandButton(
              key: const Key('location-share-open-settings'),
              label: '打开系统定位设置',
              icon: Icons.location_searching_rounded,
              variant: CommandButtonVariant.secondary,
              expanded: true,
              onPressed: () => unawaited(_store.gateway.openLocationSettings()),
            ),
          ],
        );
      case LocationSharePhase.unavailable:
        return LocationShareProblemCard(
          icon: Icons.location_off_outlined,
          title: '未获取到定位',
          body: '可先到开阔位置重试；仍失败时检查系统定位服务和权限。',
          actions: [
            CommandButton(
              key: const Key('location-share-relocate'),
              label: '重新定位',
              icon: Icons.my_location_rounded,
              expanded: true,
              onPressed: () => unawaited(_store.loadLocation()),
            ),
            CommandButton(
              key: const Key('location-share-open-settings'),
              label: '打开定位设置',
              icon: Icons.location_searching_rounded,
              variant: CommandButtonVariant.secondary,
              expanded: true,
              onPressed: () => unawaited(_store.gateway.openLocationSettings()),
            ),
          ],
        );
      case LocationSharePhase.ready:
        return LocationShareReadyCards(
          store: _store,
          onRelocate: () => unawaited(_store.loadLocation()),
          onOpenLocationSettings: () =>
              unawaited(_store.gateway.openLocationSettings()),
        );
    }
  }

  Widget _buildActionBar(BuildContext context) {
    final enabled = _store.canShare;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.2;
        final copyBtn = CommandButton(
          key: const Key('location-share-copy'),
          label: '复制完整文案',
          icon: Icons.copy_all_outlined,
          variant: CommandButtonVariant.secondary,
          size: CommandButtonSize.standard,
          expanded: true,
          enabled: enabled,
          onPressed: enabled ? () => unawaited(_handleCopy()) : null,
        );
        final shareBtn = CommandButton(
          key: const Key('location-share-submit'),
          label: '分享位置',
          icon: Icons.ios_share_outlined,
          variant: CommandButtonVariant.primary,
          size: CommandButtonSize.standard,
          expanded: true,
          enabled: enabled,
          onPressed: enabled ? () => unawaited(_handleShare()) : null,
        );
        if (compact) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              copyBtn,
              const SizedBox(height: DsSpacing.sm),
              shareBtn,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: copyBtn),
            const SizedBox(width: DsSpacing.sm),
            Expanded(child: shareBtn),
          ],
        );
      },
    );
  }
}
