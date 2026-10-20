import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import 'camera_bridge.dart';

/// 现场定位分享草稿。只包含当前设备位置，不保存位置历史。
class LocationShareDraft {
  final String incidentName;
  final String unitName;
  final String address;
  final DateTime locatedAt;
  final double lat;
  final double lon;
  final double accuracyMeters;
  final AmapLocation? amapLocation;

  const LocationShareDraft({
    required this.incidentName,
    required this.unitName,
    required this.address,
    required this.locatedAt,
    required this.lat,
    required this.lon,
    required this.accuracyMeters,
    required this.amapLocation,
  });

  LocationShareDraft copyWith({
    String? address,
    AmapLocation? amapLocation,
    bool clearAmapLocation = false,
  }) {
    return LocationShareDraft(
      incidentName: incidentName,
      unitName: unitName,
      address: address ?? this.address,
      locatedAt: locatedAt,
      lat: lat,
      lon: lon,
      accuracyMeters: accuracyMeters,
      amapLocation: clearAmapLocation
          ? null
          : amapLocation ?? this.amapLocation,
    );
  }

  static const staleWarningAge = Duration(minutes: 2);
  static const staleBlockAge = Duration(minutes: 5);
  static const poorAccuracyMeters = 100.0;

  Duration ageAt(DateTime now) {
    final age = now.difference(locatedAt);
    return age.isNegative ? Duration.zero : age;
  }

  bool isStaleAt(DateTime now) => ageAt(now) > staleBlockAge;

  bool get hasPoorAccuracy =>
      accuracyMeters <= 0 || accuracyMeters > poorAccuracyMeters;

  String get displayName {
    final incident = incidentName.trim();
    if (incident.isNotEmpty) return incident;
    return '现场位置';
  }

  Uri get markerUri => Uri.https('uri.amap.com', '/marker', {
    'position': '${lon.toStringAsFixed(6)},${lat.toStringAsFixed(6)}',
    'name': displayName,
    'coordinate': 'wgs84',
    'src': 'watchdog',
    'callnative': '0',
  });

  AmapLocation? get _validAmapLocation {
    final location = amapLocation;
    if (location == null ||
        location.coordinate.toLowerCase() != 'gcj02' ||
        !location.lat.isFinite ||
        !location.lon.isFinite) {
      return null;
    }
    return location;
  }

  Uri? get navigationUri {
    final location = _validAmapLocation;
    if (location == null) return null;
    return Uri.https('uri.amap.com', '/navigation', {
      'from': '',
      'to':
          '${location.lon.toStringAsFixed(6)},${location.lat.toStringAsFixed(6)},$displayName',
      'mode': 'car',
      'policy': '0',
      'src': 'watchdog',
      'callnative': '0',
    });
  }

  String toShareText({DateTime? now}) {
    final lines = <String>[];
    void addField(String label, String value) {
      final text = value.trim();
      if (text.isNotEmpty) lines.add('$label：$text');
    }

    addField('警情', incidentName);
    addField('单位', unitName);
    addField('位置', address);
    addField('时间', formatLocationTime(locatedAt));
    if (accuracyMeters > 0) {
      addField('精度', '约 ${_formatAccuracy(accuracyMeters)} 米');
    }
    addField('WGS84', '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}');

    lines
      ..add('')
      ..add('查看位置：')
      ..add(markerUri.toString());
    final navigation = navigationUri;
    if (navigation != null) {
      lines
        ..add('')
        ..add('驾车导航：')
        ..add(navigation.toString());
    }

    final currentAge = now == null ? null : ageAt(now);
    if (currentAge != null && currentAge > staleWarningAge) {
      lines
        ..add('')
        ..add('提示：该定位获取已超过 2 分钟，请结合现场情况核实。');
    }
    return lines.join('\n');
  }
}

String formatLocationTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _formatAccuracy(double meters) {
  if (meters < 10) return meters.toStringAsFixed(1);
  return meters.toStringAsFixed(0);
}

class LocationShareGateway {
  final Future<bool> Function() requestPermission;
  final Future<bool> Function() locationServiceEnabled;
  final Future<LocationFix?> Function() currentLocation;
  final Future<WeatherInfo> Function(double lat, double lon) fetchWeather;
  final Future<void> Function() openAppSettings;
  final Future<void> Function() openLocationSettings;
  final Future<void> Function(String text) copyText;
  final Future<void> Function(String text) shareText;
  final DateTime Function() now;

  const LocationShareGateway({
    required this.requestPermission,
    required this.locationServiceEnabled,
    required this.currentLocation,
    required this.fetchWeather,
    required this.openAppSettings,
    required this.openLocationSettings,
    required this.copyText,
    required this.shareText,
    required this.now,
  });
}

class LocationShareService {
  LocationShareService._();

  @visibleForTesting
  static Future<ShareResult> Function(ShareParams params)? overrideShare;

  static Future<ShareResult> shareText(String text) {
    final params = ShareParams(text: text, subject: '现场定位分享');
    final override = overrideShare;
    if (override != null) return override(params);
    return SharePlus.instance.share(params);
  }
}
