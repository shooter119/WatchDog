import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/camera_bridge.dart';
import '../services/location_share_service.dart';
import '../services/screen_on.dart';
import '../services/settings.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

enum _LocationSharePhase {
  loading,
  ready,
  permissionDenied,
  serviceDisabled,
  unavailable,
}

Future<void> showLocationShareSheet(
  BuildContext context, {
  required AppController controller,
  LocationShareGateway? gateway,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        LocationShareSheet(controller: controller, gateway: gateway),
  );
}

class LocationShareSheet extends StatefulWidget {
  final AppController controller;
  final LocationShareGateway? gateway;

  const LocationShareSheet({super.key, required this.controller, this.gateway});

  @override
  State<LocationShareSheet> createState() => _LocationShareSheetState();
}

class _LocationShareSheetState extends State<LocationShareSheet> {
  late final LocationShareGateway _gateway;
  _LocationSharePhase _phase = _LocationSharePhase.loading;
  LocationShareDraft? _draft;
  bool _addressLoading = false;
  bool _addressFailed = false;
  int _generation = 0;
  Timer? _staleTimer;

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    _gateway =
        widget.gateway ??
        LocationShareGateway(
          requestPermission: CameraBridge.requestLocationPermission,
          locationServiceEnabled: CameraBridge.isLocationServiceEnabled,
          currentLocation: CameraBridge.currentLocation,
          fetchWeather: (lat, lon) async =>
              controller.api?.fetchWeather(lat: lat, lon: lon) ??
              WeatherInfo.empty,
          openAppSettings: ScreenOn.openAppSettings,
          openLocationSettings: CameraBridge.openLocationSettings,
          copyText: (text) => Clipboard.setData(ClipboardData(text: text)),
          shareText: (text) async {
            await LocationShareService.shareText(text);
          },
          now: DateTime.now,
        );
    unawaited(_loadLocation());
  }

  @override
  void dispose() {
    _generation++;
    _staleTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    final generation = ++_generation;
    _staleTimer?.cancel();
    setState(() {
      _phase = _LocationSharePhase.loading;
      _draft = null;
      _addressLoading = false;
      _addressFailed = false;
    });

    final permitted = await _gateway.requestPermission();
    if (!mounted || generation != _generation) return;
    if (!permitted) {
      setState(() => _phase = _LocationSharePhase.permissionDenied);
      return;
    }

    final serviceEnabled = await _gateway.locationServiceEnabled();
    if (!mounted || generation != _generation) return;
    if (!serviceEnabled) {
      setState(() => _phase = _LocationSharePhase.serviceDisabled);
      return;
    }

    final fix = await _gateway.currentLocation();
    if (!mounted || generation != _generation) return;
    if (fix == null) {
      setState(() => _phase = _LocationSharePhase.unavailable);
      return;
    }

    final receivedAt = _gateway.now();
    final locatedAt = receivedAt.subtract(Duration(milliseconds: fix.ageMs));
    final draft = LocationShareDraft(
      incidentName: widget.controller.currentIncident?.displayName ?? '',
      unitName: await _unitName(),
      address: '',
      locatedAt: locatedAt,
      lat: fix.lat,
      lon: fix.lon,
      accuracyMeters: fix.accuracyMeters,
      amapLocation: null,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _phase = _LocationSharePhase.ready;
      _draft = draft;
      _addressLoading = true;
      _addressFailed = false;
    });
    _scheduleStaleRefresh();

    WeatherInfo weather;
    try {
      weather = await _gateway.fetchWeather(fix.lat, fix.lon);
    } catch (_) {
      weather = WeatherInfo.empty;
    }
    if (!mounted || generation != _generation) return;
    final address = (weather.address ?? '').trim();
    setState(() {
      _draft = draft.copyWith(
        address: address,
        amapLocation: weather.amapLocation,
        clearAmapLocation: weather.amapLocation == null,
      );
      _addressLoading = false;
      _addressFailed = address.isEmpty || weather.amapLocation == null;
    });
  }

  Future<String> _unitName() async {
    try {
      return await Settings.unitName;
    } catch (_) {
      return '';
    }
  }

  void _scheduleStaleRefresh() {
    _staleTimer?.cancel();
    final draft = _draft;
    if (draft == null) return;
    final age = draft.ageAt(_gateway.now());
    Duration? next;
    if (age <= LocationShareDraft.staleWarningAge) {
      next = LocationShareDraft.staleWarningAge - age;
    } else if (age <= LocationShareDraft.staleBlockAge) {
      next = LocationShareDraft.staleBlockAge - age;
    }
    if (next != null) {
      _staleTimer = Timer(next + const Duration(milliseconds: 1), () {
        if (!mounted) return;
        setState(() {});
        _scheduleStaleRefresh();
      });
    }
  }

  bool get _canShare {
    final draft = _draft;
    return _phase == _LocationSharePhase.ready &&
        draft != null &&
        !draft.isStaleAt(_gateway.now());
  }

  Future<void> _copy() async {
    final draft = _draft;
    if (draft == null || !_canShare) return;
    try {
      await _gateway.copyText(draft.toShareText(now: _gateway.now()));
      _toast('完整文案已复制');
    } catch (_) {
      _toast('复制失败，请稍后重试');
    }
  }

  Future<void> _share() async {
    final draft = _draft;
    if (draft == null || !_canShare) return;
    try {
      await _gateway.shareText(draft.toShareText(now: _gateway.now()));
      _toast('已打开系统分享');
    } catch (_) {
      _toast('系统分享不可用');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Material(
        key: const Key('location-share-sheet'),
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _header(context),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                children: [
                  Text(
                    '分享的是纯文本和 HTTPS 高德链接。微信收到后可点击链接查看位置或驾车路线，不保证直接唤起高德 App。',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ..._body(context),
                ],
              ),
            ),
            _actionBar(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.share_location_outlined,
                color: AppColors.actionPrimary,
              ),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  '定位分享',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: '关闭定位分享',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    switch (_phase) {
      case _LocationSharePhase.loading:
        return [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在获取定位并查询地址…'),
              ],
            ),
          ),
        ];
      case _LocationSharePhase.permissionDenied:
        return [
          _problemCard(
            icon: Icons.location_disabled_outlined,
            title: '定位权限未授权',
            body: '需要在系统权限中允许“火场智控”使用定位，才能生成现场位置。',
            actions: [
              _wideAction(
                key: const Key('location-share-relocate'),
                label: '重新申请定位权限',
                icon: Icons.my_location,
                onPressed: _loadLocation,
                filled: true,
              ),
              _wideAction(
                key: const Key('location-share-app-settings'),
                label: '打开应用设置',
                icon: Icons.settings_outlined,
                onPressed: _gateway.openAppSettings,
              ),
            ],
          ),
        ];
      case _LocationSharePhase.serviceDisabled:
        return [
          _problemCard(
            icon: Icons.wrong_location_outlined,
            title: '定位服务未开启',
            body: '请打开手机定位服务，再返回这里重新定位。',
            actions: [
              _wideAction(
                key: const Key('location-share-relocate'),
                label: '重新定位',
                icon: Icons.my_location,
                onPressed: _loadLocation,
                filled: true,
              ),
              _wideAction(
                key: const Key('location-share-open-settings'),
                label: '打开系统定位设置',
                icon: Icons.location_searching,
                onPressed: _gateway.openLocationSettings,
              ),
            ],
          ),
        ];
      case _LocationSharePhase.unavailable:
        return [
          _problemCard(
            icon: Icons.location_off_outlined,
            title: '未获取到定位',
            body: '可先到开阔位置重试；仍失败时检查系统定位服务和权限。',
            actions: [
              _wideAction(
                key: const Key('location-share-relocate'),
                label: '重新定位',
                icon: Icons.my_location,
                onPressed: _loadLocation,
                filled: true,
              ),
              _wideAction(
                key: const Key('location-share-open-settings'),
                label: '打开定位设置',
                icon: Icons.location_searching,
                onPressed: _gateway.openLocationSettings,
              ),
            ],
          ),
        ];
      case _LocationSharePhase.ready:
        return _readyBody();
    }
  }

  List<Widget> _readyBody() {
    final draft = _draft!;
    final now = _gateway.now();
    final age = draft.ageAt(now);
    final blocked = age > LocationShareDraft.staleBlockAge;
    final stale = age > LocationShareDraft.staleWarningAge;
    final text = draft.toShareText(now: now);
    return [
      AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            _infoRow(
              '警情',
              draft.incidentName.isEmpty ? '未选择警情' : draft.incidentName,
            ),
            _infoRow('单位', draft.unitName.isEmpty ? '未填写单位' : draft.unitName),
            _infoRow(
              '地址',
              _addressLoading
                  ? '正在查询地址…'
                  : (draft.address.isEmpty ? '地址暂不可用' : draft.address),
            ),
            _infoRow('定位时间', formatLocationTime(draft.locatedAt)),
            _infoRow(
              '精度',
              draft.accuracyMeters > 0
                  ? '约 ${draft.accuracyMeters.toStringAsFixed(0)} 米'
                  : '未提供',
            ),
            _infoRow(
              'WGS84',
              '${draft.lat.toStringAsFixed(6)}, ${draft.lon.toStringAsFixed(6)}',
              last: true,
            ),
          ],
        ),
      ),
      if (blocked) ...[
        const SizedBox(height: 12),
        _warningCard(
          icon: Icons.timer_off_outlined,
          color: AppColors.alarm,
          text: '定位已超过 5 分钟，不能直接分享。请重新定位后再发送。',
        ),
      ] else if (stale) ...[
        const SizedBox(height: 12),
        _warningCard(
          icon: Icons.schedule,
          color: AppColors.caution,
          text: '定位已超过 2 分钟，位置可能已变化，请结合现场情况核实。',
        ),
      ],
      if (draft.hasPoorAccuracy) ...[
        const SizedBox(height: 12),
        _warningCard(
          icon: Icons.gps_off_outlined,
          color: AppColors.caution,
          text: '定位精度较差或未提供精度，接收方可能看到明显偏移。',
        ),
      ],
      if (_addressFailed) ...[
        const SizedBox(height: 12),
        _warningCard(
          icon: Icons.info_outline,
          color: AppColors.caution,
          text: draft.navigationUri == null
              ? '地址或坐标转换未完成，仍可分享 WGS84 查看位置；驾车导航已隐藏。'
              : '地址查询未完成，但高德驾车导航仍可用。',
        ),
      ],
      const SizedBox(height: 12),
      Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '分享文案预览',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                text,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('location-share-relocate'),
            onPressed: _loadLocation,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            icon: const Icon(Icons.my_location),
            label: const Text('重新定位'),
          ),
          OutlinedButton.icon(
            key: const Key('location-share-open-settings'),
            onPressed: _gateway.openLocationSettings,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            icon: const Icon(Icons.location_searching),
            label: const Text('打开定位设置'),
          ),
        ],
      ),
    ];
  }

  Widget _infoRow(String label, String value, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _problemCard({
    required IconData icon,
    required String title,
    required String body,
    required List<Widget> actions,
  }) {
    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Icon(icon, size: 38, color: AppColors.caution),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.55,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            actions[i],
          ],
        ],
      ),
    );
  }

  Widget _wideAction({
    required Key key,
    required String label,
    required IconData icon,
    required Future<void> Function() onPressed,
    bool filled = false,
  }) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
    );
    if (filled) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: key,
          onPressed: onPressed,
          style: style,
          icon: Icon(icon),
          label: Text(label),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: key,
        onPressed: onPressed,
        style: style,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }

  Widget _warningCard({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar(BuildContext context) {
    final enabled = _canShare;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 380 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.2;
            final width = compact
                ? constraints.maxWidth
                : (constraints.maxWidth - 10) / 2;
            final copy = OutlinedButton.icon(
              key: const Key('location-share-copy'),
              onPressed: enabled ? _copy : null,
              style: OutlinedButton.styleFrom(minimumSize: Size(width, 52)),
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('复制完整文案'),
            );
            final share = FilledButton.icon(
              key: const Key('location-share-submit'),
              onPressed: enabled ? _share : null,
              style: FilledButton.styleFrom(minimumSize: Size(width, 52)),
              icon: const Icon(Icons.ios_share_outlined),
              label: const Text('分享位置'),
            );
            if (compact) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [copy, const SizedBox(height: 8), share],
              );
            }
            return Row(children: [copy, const SizedBox(width: 10), share]);
          },
        ),
      ),
    );
  }
}
