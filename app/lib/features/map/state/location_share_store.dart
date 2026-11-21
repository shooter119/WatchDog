import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../services/location_share_service.dart';
import '../../../services/settings.dart';

export '../../../services/location_share_service.dart'
    show LocationShareDraft, LocationShareGateway, formatLocationTime;

/// 位置分享定位阶段机。
enum LocationSharePhase {
  loading,
  ready,
  permissionDenied,
  serviceDisabled,
  unavailable,
}

/// 位置分享状态容器（保留定位阶段机、2 分钟告警 / 5 分钟过期刷新、文案复制与系统分享）。
class LocationShareStore extends ChangeNotifier {
  final LocationShareGateway gateway;
  final String Function() readIncidentName;
  final Future<String> Function() readUnitName;

  LocationShareStore({
    required this.gateway,
    required this.readIncidentName,
    Future<String> Function()? readUnitName,
  }) : readUnitName = readUnitName ?? _defaultReadUnitName;

  static Future<String> _defaultReadUnitName() async {
    try {
      return await Settings.unitName;
    } catch (_) {
      return '';
    }
  }

  LocationSharePhase _phase = LocationSharePhase.loading;
  LocationShareDraft? _draft;
  bool _addressLoading = false;
  bool _addressFailed = false;
  int _generation = 0;
  Timer? _staleTimer;
  bool _disposed = false;

  LocationSharePhase get phase => _phase;
  LocationShareDraft? get draft => _draft;
  bool get addressLoading => _addressLoading;
  bool get addressFailed => _addressFailed;

  DateTime get now => gateway.now();

  bool get canShare {
    final current = _draft;
    return _phase == LocationSharePhase.ready &&
        current != null &&
        !current.isStaleAt(gateway.now());
  }

  bool get isStaleBlocked {
    final current = _draft;
    if (current == null) return false;
    return current.ageAt(gateway.now()) > LocationShareDraft.staleBlockAge;
  }

  bool get isStaleWarning {
    final current = _draft;
    if (current == null) return false;
    return current.ageAt(gateway.now()) > LocationShareDraft.staleWarningAge;
  }

  String? get previewText {
    final current = _draft;
    if (current == null) return null;
    return current.toShareText(now: gateway.now());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadLocation() async {
    final generation = ++_generation;
    _staleTimer?.cancel();
    _phase = LocationSharePhase.loading;
    _draft = null;
    _addressLoading = false;
    _addressFailed = false;
    _notify();

    final permitted = await gateway.requestPermission();
    if (_disposed || generation != _generation) return;
    if (!permitted) {
      _phase = LocationSharePhase.permissionDenied;
      _notify();
      return;
    }

    final serviceEnabled = await gateway.locationServiceEnabled();
    if (_disposed || generation != _generation) return;
    if (!serviceEnabled) {
      _phase = LocationSharePhase.serviceDisabled;
      _notify();
      return;
    }

    final fix = await gateway.currentLocation();
    if (_disposed || generation != _generation) return;
    if (fix == null) {
      _phase = LocationSharePhase.unavailable;
      _notify();
      return;
    }

    final receivedAt = gateway.now();
    final locatedAt = receivedAt.subtract(Duration(milliseconds: fix.ageMs));
    final unitName = await _safeUnitName();
    if (_disposed || generation != _generation) return;

    final draft = LocationShareDraft(
      incidentName: readIncidentName(),
      unitName: unitName,
      address: '',
      locatedAt: locatedAt,
      lat: fix.lat,
      lon: fix.lon,
      accuracyMeters: fix.accuracyMeters,
      amapLocation: null,
    );

    _phase = LocationSharePhase.ready;
    _draft = draft;
    _addressLoading = true;
    _addressFailed = false;
    _notify();
    _scheduleStaleRefresh();

    var address = '';
    var amapLocation = draft.amapLocation;
    try {
      final weather = await gateway.fetchWeather(fix.lat, fix.lon);
      address = (weather.address ?? '').trim();
      amapLocation = weather.amapLocation;
    } catch (_) {
      address = '';
      amapLocation = null;
    }
    if (_disposed || generation != _generation) return;
    _draft = draft.copyWith(
      address: address,
      amapLocation: amapLocation,
      clearAmapLocation: amapLocation == null,
    );
    _addressLoading = false;
    _addressFailed = address.isEmpty || amapLocation == null;
    _notify();
  }

  Future<String> _safeUnitName() async {
    try {
      return await readUnitName();
    } catch (_) {
      return '';
    }
  }

  void _scheduleStaleRefresh() {
    _staleTimer?.cancel();
    final current = _draft;
    if (current == null) return;
    final age = current.ageAt(gateway.now());
    Duration? next;
    if (age <= LocationShareDraft.staleWarningAge) {
      next = LocationShareDraft.staleWarningAge - age;
    } else if (age <= LocationShareDraft.staleBlockAge) {
      next = LocationShareDraft.staleBlockAge - age;
    }
    if (next != null) {
      _staleTimer = Timer(next + const Duration(milliseconds: 1), () {
        if (_disposed) return;
        _notify();
        _scheduleStaleRefresh();
      });
    }
  }

  Future<String?> copy() async {
    final current = _draft;
    if (current == null || !canShare) return null;
    try {
      await gateway.copyText(current.toShareText(now: gateway.now()));
      return '完整文案已复制';
    } catch (_) {
      return '复制失败，请稍后重试';
    }
  }

  Future<String?> share() async {
    final current = _draft;
    if (current == null || !canShare) return null;
    try {
      await gateway.shareText(current.toShareText(now: gateway.now()));
      return '已打开系统分享';
    } catch (_) {
      return '系统分享不可用';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _staleTimer?.cancel();
    super.dispose();
  }
}
