import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/camera_bridge.dart';
import '../services/china_coord.dart';
import '../services/screen_on.dart';
import '../state/app_controller.dart';
import '../theme/app_widgets.dart';

/// 现场卫星地图图层模式（默认：卫星+路网）。
enum SceneMapLayerMode {
  hybrid('hybrid', '卫星+路网'),
  satellite('satellite', '纯卫星'),
  standard('standard', '标准图');

  final String jsValue;
  final String label;
  const SceneMapLayerMode(this.jsValue, this.label);
}

/// 地图交互桥接控制器（方便测试观察脚本注入与图层/视角指令下发）。
class SceneMapSurfaceController {
  String? lastLoadedHtml;
  String? lastBaseUrl;
  final List<String> evaluatedScripts = [];
  Future<void> Function(String baseUrl, String html)? _onLoadHtml;
  Future<void> Function(String script)? _onEvalJs;

  void attach({
    required Future<void> Function(String baseUrl, String html) onLoadHtml,
    required Future<void> Function(String script) onEvalJs,
  }) {
    _onLoadHtml = onLoadHtml;
    _onEvalJs = onEvalJs;
  }

  void detach() {
    _onLoadHtml = null;
    _onEvalJs = null;
  }

  Future<void> loadHtml(String baseUrl, String html) async {
    lastBaseUrl = baseUrl;
    lastLoadedHtml = html;
    final fn = _onLoadHtml;
    if (fn != null) {
      await fn(baseUrl, html);
    }
  }

  Future<void> evalJs(String script) async {
    evaluatedScripts.add(script);
    final fn = _onEvalJs;
    if (fn != null) {
      await fn(script);
    }
  }
}

/// 测试可注入网关，隔离原生定位流、后端引导/逆地理/导航与外部跳转。
class SceneMapGateway {
  final Future<bool> Function() requestPermission;
  final Future<bool> Function() locationServiceEnabled;
  final Future<LocationFix?> Function() currentLocation;
  final Stream<LocationFix> Function() watchLocation;
  final Future<SceneMapBootstrap> Function() fetchMapBootstrap;
  final Future<WeatherInfo> Function(double lat, double lon) fetchWeather;
  final Future<RouteTrafficInfo> Function({
    required String address,
    String? city,
    double? destLat,
    double? destLon,
  })
  fetchIncidentRouteInfo;
  final Future<Map<String, dynamic>> Function(String incidentId)?
  fetchIncidentDetails;
  final Future<void> Function() openAppSettings;
  final Future<void> Function() openLocationSettings;
  final Future<bool> Function(Uri uri) launchNavigation;
  final DateTime Function() now;
  final Widget Function(
    BuildContext context,
    SceneMapSurfaceController surfaceController,
    void Function(String eventType, Map<String, dynamic> data) onBridgeEvent,
  )?
  mapSurfaceBuilder;

  const SceneMapGateway({
    required this.requestPermission,
    required this.locationServiceEnabled,
    required this.currentLocation,
    required this.watchLocation,
    required this.fetchMapBootstrap,
    required this.fetchWeather,
    required this.fetchIncidentRouteInfo,
    this.fetchIncidentDetails,
    required this.openAppSettings,
    required this.openLocationSettings,
    required this.launchNavigation,
    required this.now,
    this.mapSurfaceBuilder,
  });
}

String _safeJsonEncode(Object? value) =>
    jsonEncode(value).replaceAll('</', '<\\/');

/// 生成现场卫星地图 HTML（当服务端配置 `jsKey` 时走高德 JS API 2.0；未配置 Key 时自动降级内置高德瓦片引擎）。
@visibleForTesting
String buildSceneMapHtml({
  required String jsKey,
  String? serviceHost,
  SceneMapLayerMode initialLayer = SceneMapLayerMode.hybrid,
  ({double lat, double lon, double accuracy, double? bearing})? initialMyGcj,
  ({double lat, double lon, String title})? initialIncidentGcj,
}) {
  final trimmedKey = jsKey.trim();
  if (trimmedKey.isEmpty) {
    return _buildRasterFallbackMapHtml(
      initialLayer: initialLayer,
      initialMyGcj: initialMyGcj,
      initialIncidentGcj: initialIncidentGcj,
    );
  }
  final encodedKey = Uri.encodeQueryComponent(trimmedKey);
  final securityBlock = (serviceHost != null && serviceHost.trim().isNotEmpty)
      ? '''
<script>
window._AMapSecurityConfig = {
  serviceHost: ${_safeJsonEncode(serviceHost.trim())}
};
</script>'''
      : '';

  final initialCenter = initialMyGcj != null
      ? '[${initialMyGcj.lon.toStringAsFixed(6)}, ${initialMyGcj.lat.toStringAsFixed(6)}]'
      : initialIncidentGcj != null
      ? '[${initialIncidentGcj.lon.toStringAsFixed(6)}, ${initialIncidentGcj.lat.toStringAsFixed(6)}]'
      : '[116.397428, 39.90923]';
  final initialZoom = (initialMyGcj != null || initialIncidentGcj != null)
      ? 17
      : 5;

  final myJson = initialMyGcj == null
      ? 'null'
      : _safeJsonEncode({
          'lon': initialMyGcj.lon,
          'lat': initialMyGcj.lat,
          'accuracy': initialMyGcj.accuracy,
          'bearing': initialMyGcj.bearing,
        });
  final incidentJson = initialIncidentGcj == null
      ? 'null'
      : _safeJsonEncode({
          'lon': initialIncidentGcj.lon,
          'lat': initialIncidentGcj.lat,
          'title': initialIncidentGcj.title,
        });

  return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body, #map-container {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #0F172A;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
    }
    .wd-my-wrap {
      position: relative;
      width: 30px;
      height: 30px;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .wd-my-heading {
      position: absolute;
      top: 0;
      left: 50%;
      width: 0;
      height: 0;
      margin-left: -5px;
      border-left: 5px solid transparent;
      border-right: 5px solid transparent;
      border-bottom: 9px solid #2563EB;
      transform-origin: 5px 15px;
      display: none;
    }
    .wd-my-dot {
      width: 16px;
      height: 16px;
      border-radius: 50%;
      background: #2563EB;
      border: 3px solid #FFFFFF;
      box-shadow: 0 1px 6px rgba(0, 0, 0, 0.45);
    }
    .wd-incident-pin {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 4px 9px;
      border-radius: 999px;
      background: #DC2626;
      color: #FFFFFF;
      border: 2px solid #FFFFFF;
      font-size: 12px;
      font-weight: 700;
      white-space: nowrap;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35);
    }
    .wd-incident-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #FFFFFF;
      flex-shrink: 0;
    }
  </style>
</head>
<body>
  <div id="map-container"></div>
  $securityBlock
  <script>
    function notifyBridge(type, data) {
      try {
        if (window.WatchdogMapBridge && window.WatchdogMapBridge.postMessage) {
          window.WatchdogMapBridge.postMessage(JSON.stringify({ type: type, data: data || {} }));
        }
      } catch (_) {}
    }

    window.onAmapScriptError = function() {
      notifyBridge('scriptError', { message: '高德地图脚本加载失败，请检查网络连接' });
    };
  </script>
  <script
    src="https://webapi.amap.com/maps?v=2.0&key=$encodedKey&plugin=AMap.Scale"
    onerror="window.onAmapScriptError()"
  ></script>
  <script>
    (function() {
      if (typeof AMap === 'undefined') {
        notifyBridge('scriptError', { message: '高德地图引擎未就绪，请检查网络后重试' });
        return;
      }

      var state = {
        layerMode: ${_safeJsonEncode(initialLayer.jsValue)},
        my: $myJson,
        incident: $incidentJson,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };

      var map = new AMap.Map('map-container', {
        zoom: $initialZoom,
        center: $initialCenter,
        viewMode: '2D',
        rotateEnable: false,
        pitchEnable: false,
        resizeEnable: true
      });

      var satelliteLayer = new AMap.TileLayer.Satellite({ zIndex: 1 });
      var roadNetLayer = new AMap.TileLayer.RoadNet({ zIndex: 2 });
      map.addControl(new AMap.Scale());

      var myMarker = null;
      var myCircle = null;
      var incidentMarker = null;
      var linkLine = null;

      function applyLayerMode(mode) {
        state.layerMode = mode || 'hybrid';
        if (state.layerMode === 'hybrid') {
          satelliteLayer.setMap(map);
          roadNetLayer.setMap(map);
        } else if (state.layerMode === 'satellite') {
          satelliteLayer.setMap(map);
          roadNetLayer.setMap(null);
        } else {
          satelliteLayer.setMap(null);
          roadNetLayer.setMap(null);
        }
      }

      function escapeHtml(text) {
        return String(text || '')
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;');
      }

      function createMyDom(bearing) {
        var wrap = document.createElement('div');
        wrap.className = 'wd-my-wrap';
        var arrow = document.createElement('div');
        arrow.className = 'wd-my-heading';
        if (typeof bearing === 'number' && isFinite(bearing)) {
          arrow.style.display = 'block';
          arrow.style.transform = 'rotate(' + bearing.toFixed(1) + 'deg)';
        }
        var dot = document.createElement('div');
        dot.className = 'wd-my-dot';
        wrap.appendChild(arrow);
        wrap.appendChild(dot);
        return wrap;
      }

      function syncLinkLine() {
        if (!state.my || !state.incident) {
          if (linkLine) {
            linkLine.setMap(null);
            linkLine = null;
          }
          return;
        }
        var path = [
          [state.my.lon, state.my.lat],
          [state.incident.lon, state.incident.lat]
        ];
        if (!linkLine) {
          linkLine = new AMap.Polyline({
            path: path,
            strokeColor: '#DC2626',
            strokeWeight: 3,
            strokeOpacity: 0.85,
            strokeStyle: 'dashed',
            strokeDasharray: [10, 6],
            zIndex: 50
          });
          linkLine.setMap(map);
        } else {
          linkLine.setPath(path);
        }
      }

      function renderMy(shouldCenter) {
        if (!state.my) return;
        var pos = [state.my.lon, state.my.lat];
        var radius = typeof state.my.accuracy === 'number' && state.my.accuracy > 0
          ? state.my.accuracy
          : 0;
        if (!myCircle) {
          myCircle = new AMap.Circle({
            center: pos,
            radius: radius,
            strokeColor: '#2563EB',
            strokeOpacity: 0.45,
            strokeWeight: 1,
            fillColor: '#2563EB',
            fillOpacity: 0.14,
            zIndex: 40
          });
          myCircle.setMap(map);
        } else {
          myCircle.setCenter(pos);
          myCircle.setRadius(radius);
        }

        if (!myMarker) {
          myMarker = new AMap.Marker({
            position: pos,
            content: createMyDom(state.my.bearing),
            offset: new AMap.Pixel(-15, -15),
            zIndex: 120
          });
          myMarker.setMap(map);
        } else {
          myMarker.setPosition(pos);
          myMarker.setContent(createMyDom(state.my.bearing));
        }

        if (shouldCenter || !state.hasCenteredMy) {
          state.hasCenteredMy = true;
          if (map.getZoom() < 15) {
            map.setZoomAndCenter(17, pos, false);
          } else {
            map.setCenter(pos, false);
          }
        }
        syncLinkLine();
      }

      function renderIncident() {
        if (!state.incident) {
          if (incidentMarker) {
            incidentMarker.setMap(null);
            incidentMarker = null;
          }
          syncLinkLine();
          return;
        }
        var pos = [state.incident.lon, state.incident.lat];
        var label = escapeHtml(state.incident.title || '事发地点');
        var html = '<div class="wd-incident-pin"><span class="wd-incident-dot"></span><span>' + label + '</span></div>';
        if (!incidentMarker) {
          incidentMarker = new AMap.Marker({
            position: pos,
            content: html,
            anchor: 'bottom-center',
            zIndex: 110
          });
          incidentMarker.setMap(map);
        } else {
          incidentMarker.setPosition(pos);
          incidentMarker.setContent(html);
        }
        syncLinkLine();
      }

      applyLayerMode(state.layerMode);
      if (state.my) renderMy(false);
      if (state.incident) renderIncident();

      map.on('dragstart', function() {
        notifyBridge('userDragged', {});
      });
      map.on('complete', function() {
        notifyBridge('mapReady', {});
      });

      window.watchdogMap = {
        setLayerMode: function(mode) {
          applyLayerMode(mode);
        },
        updateMyLocation: function(lon, lat, accuracy, bearing, shouldCenter) {
          state.my = { lon: lon, lat: lat, accuracy: accuracy || 0, bearing: bearing };
          renderMy(Boolean(shouldCenter));
        },
        updateIncident: function(lon, lat, title) {
          state.incident = { lon: lon, lat: lat, title: title || '事发地点' };
          renderIncident();
        },
        focusMyLocation: function() {
          if (!state.my) return;
          var pos = [state.my.lon, state.my.lat];
          if (map.getZoom() < 16) {
            map.setZoomAndCenter(17, pos, false);
          } else {
            map.setCenter(pos, false);
          }
        },
        focusIncident: function() {
          if (!state.incident) return;
          var pos = [state.incident.lon, state.incident.lat];
          if (map.getZoom() < 15) {
            map.setZoomAndCenter(16, pos, false);
          } else {
            map.setCenter(pos, false);
          }
        },
        fitBoth: function() {
          var targets = [];
          if (myMarker) targets.push(myMarker);
          if (incidentMarker) targets.push(incidentMarker);
          if (targets.length >= 2) {
            map.setFitView(targets, false, [140, 180, 60, 60], 17);
          } else if (state.my) {
            window.watchdogMap.focusMyLocation();
          } else if (state.incident) {
            window.watchdogMap.focusIncident();
          }
        }
      };
    })();
  </script>
</body>
</html>
''';
}

String _buildRasterFallbackMapHtml({
  required SceneMapLayerMode initialLayer,
  ({double lat, double lon, double accuracy, double? bearing})? initialMyGcj,
  ({double lat, double lon, String title})? initialIncidentGcj,
}) {
  final initialLat = initialMyGcj?.lat ?? initialIncidentGcj?.lat ?? 39.90923;
  final initialLon = initialMyGcj?.lon ?? initialIncidentGcj?.lon ?? 116.397428;
  final initialZoom = (initialMyGcj != null || initialIncidentGcj != null)
      ? 17
      : 5;

  final myJson = initialMyGcj == null
      ? 'null'
      : _safeJsonEncode({
          'lon': initialMyGcj.lon,
          'lat': initialMyGcj.lat,
          'accuracy': initialMyGcj.accuracy,
          'bearing': initialMyGcj.bearing,
        });
  final incidentJson = initialIncidentGcj == null
      ? 'null'
      : _safeJsonEncode({
          'lon': initialIncidentGcj.lon,
          'lat': initialIncidentGcj.lat,
          'title': initialIncidentGcj.title,
        });

  return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body, #map-container {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #0F172A;
      touch-action: none;
      user-select: none;
      -webkit-user-select: none;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
    }
    #tile-layer, #overlay-svg, #marker-layer {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      pointer-events: none;
      overflow: hidden;
    }
    .wd-tile {
      position: absolute;
      image-rendering: auto;
      pointer-events: none;
      border: 0;
    }
    #wd-scale-wrap {
      position: absolute;
      left: 12px;
      top: 76px;
      z-index: 200;
      pointer-events: none;
      display: inline-flex;
      flex-direction: column;
      align-items: flex-start;
      padding: 4px 8px;
      border-radius: 8px;
      background: rgba(15, 23, 42, 0.72);
      color: #F8FAFC;
      font-size: 11px;
      font-weight: 700;
    }
    #wd-scale-line {
      height: 5px;
      margin-top: 2px;
      border: 1.5px solid #F8FAFC;
      border-top: 0;
      box-sizing: border-box;
    }
    .wd-my-wrap {
      position: absolute;
      width: 30px;
      height: 30px;
      margin-left: -15px;
      margin-top: -15px;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .wd-my-heading {
      position: absolute;
      top: 0;
      left: 50%;
      width: 0;
      height: 0;
      margin-left: -5px;
      border-left: 5px solid transparent;
      border-right: 5px solid transparent;
      border-bottom: 9px solid #2563EB;
      transform-origin: 5px 15px;
      display: none;
    }
    .wd-my-dot {
      width: 16px;
      height: 16px;
      border-radius: 50%;
      background: #2563EB;
      border: 3px solid #FFFFFF;
      box-shadow: 0 1px 6px rgba(0, 0, 0, 0.45);
    }
    .wd-incident-pin {
      position: absolute;
      transform: translate(-50%, -100%);
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 4px 9px;
      border-radius: 999px;
      background: #DC2626;
      color: #FFFFFF;
      border: 2px solid #FFFFFF;
      font-size: 12px;
      font-weight: 700;
      white-space: nowrap;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35);
    }
    .wd-incident-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #FFFFFF;
      flex-shrink: 0;
    }
  </style>
</head>
<body>
  <div id="map-container">
    <div id="tile-layer"></div>
    <svg id="overlay-svg"></svg>
    <div id="marker-layer"></div>
    <div id="wd-scale-wrap">
      <span id="wd-scale-label">100 m</span>
      <div id="wd-scale-line" style="width: 64px;"></div>
    </div>
  </div>
  <script>
    function notifyBridge(type, data) {
      try {
        if (window.WatchdogMapBridge && window.WatchdogMapBridge.postMessage) {
          window.WatchdogMapBridge.postMessage(JSON.stringify({ type: type, data: data || {} }));
        }
      } catch (_) {}
    }

    (function() {
      var container = document.getElementById('map-container');
      var tileLayer = document.getElementById('tile-layer');
      var overlaySvg = document.getElementById('overlay-svg');
      var markerLayer = document.getElementById('marker-layer');
      var scaleLabel = document.getElementById('wd-scale-label');
      var scaleLine = document.getElementById('wd-scale-line');

      var state = {
        layerMode: ${_safeJsonEncode(initialLayer.jsValue)},
        centerLon: ${initialLon.toStringAsFixed(6)},
        centerLat: ${initialLat.toStringAsFixed(6)},
        zoom: $initialZoom,
        my: $myJson,
        incident: $incidentJson,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };

      var tileCache = Object.create(null);
      var tileOrder = [];
      var maxCacheSize = 140;
      var renderScheduled = false;

      function clampLat(lat) {
        return Math.max(-85.05112878, Math.min(85.05112878, lat));
      }

      function wrapLon(lon) {
        while (lon < -180) lon += 360;
        while (lon > 180) lon -= 360;
        return lon;
      }

      function lonLatToWorld(lon, lat, zoom) {
        var scale = 256 * Math.pow(2, zoom);
        var rad = clampLat(lat) * Math.PI / 180;
        var s = Math.sin(rad);
        var x = ((lon + 180) / 360) * scale;
        var y = (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * scale;
        return { x: x, y: y };
      }

      function worldToLonLat(wx, wy, zoom) {
        var scale = 256 * Math.pow(2, zoom);
        var lon = wrapLon((wx / scale) * 360 - 180);
        var n = Math.PI - (2 * Math.PI * wy) / scale;
        var lat = clampLat((180 / Math.PI) * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n))));
        return { lon: lon, lat: lat };
      }

      function toScreen(lon, lat) {
        var w = container.clientWidth || 360;
        var h = container.clientHeight || 640;
        var c = lonLatToWorld(state.centerLon, state.centerLat, state.zoom);
        var p = lonLatToWorld(lon, lat, state.zoom);
        return { x: w / 2 + (p.x - c.x), y: h / 2 + (p.y - c.y) };
      }

      function buildTileUrl(kind, x, y, z) {
        var sub = (Math.abs(x + y) % 4) + 1;
        if (kind === 'sat') {
          return 'https://webst0' + sub + '.is.autonavi.com/appmaptile?style=6&x=' + x + '&y=' + y + '&z=' + z;
        }
        if (kind === 'road') {
          return 'https://webst0' + sub + '.is.autonavi.com/appmaptile?style=8&x=' + x + '&y=' + y + '&z=' + z;
        }
        return 'https://webrd0' + sub + '.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x=' + x + '&y=' + y + '&z=' + z;
      }

      function acquireTile(kind, wrappedX, ty, tz) {
        var key = kind + ':' + tz + ':' + wrappedX + ':' + ty;
        var img = tileCache[key];
        if (!img) {
          img = document.createElement('img');
          img.className = 'wd-tile';
          img.decoding = 'async';
          img.referrerPolicy = 'no-referrer';
          img.draggable = false;
          img.alt = '';
          img.src = buildTileUrl(kind, wrappedX, ty, tz);
          tileCache[key] = img;
          tileOrder.push(key);
          while (tileOrder.length > maxCacheSize) {
            var oldKey = tileOrder.shift();
            var oldImg = tileCache[oldKey];
            if (oldImg && oldImg.parentNode === tileLayer) {
              tileLayer.removeChild(oldImg);
            }
            delete tileCache[oldKey];
          }
        }
        return img;
      }

      function renderTiles() {
        var w = container.clientWidth || 360;
        var h = container.clientHeight || 640;
        var tz = Math.max(3, Math.min(18, Math.round(state.zoom)));
        var factor = Math.pow(2, state.zoom - tz);
        var tilePx = 256 * factor;
        var maxIndex = Math.pow(2, tz);
        var c = lonLatToWorld(state.centerLon, state.centerLat, tz);

        var leftWorld = c.x - (w / 2) / factor;
        var rightWorld = c.x + (w / 2) / factor;
        var topWorld = c.y - (h / 2) / factor;
        var bottomWorld = c.y + (h / 2) / factor;

        var minTx = Math.floor(leftWorld / 256) - 1;
        var maxTx = Math.floor(rightWorld / 256) + 1;
        var minTy = Math.max(0, Math.floor(topWorld / 256) - 1);
        var maxTy = Math.min(maxIndex - 1, Math.floor(bottomWorld / 256) + 1);

        var kinds = state.layerMode === 'hybrid'
          ? ['sat', 'road']
          : (state.layerMode === 'satellite' ? ['sat'] : ['std']);

        var activeSet = Object.create(null);
        for (var ki = 0; ki < kinds.length; ki++) {
          var kind = kinds[ki];
          var zIndex = ki + 1;
          for (var tx = minTx; tx <= maxTx; tx++) {
            var wrappedX = ((tx % maxIndex) + maxIndex) % maxIndex;
            var left = Math.round((w / 2) + (tx * 256 - c.x) * factor);
            var nextLeft = Math.round((w / 2) + ((tx + 1) * 256 - c.x) * factor);
            var widthPx = Math.max(1, nextLeft - left);
            for (var ty = minTy; ty <= maxTy; ty++) {
              var top = Math.round((h / 2) + (ty * 256 - c.y) * factor);
              var nextTop = Math.round((h / 2) + ((ty + 1) * 256 - c.y) * factor);
              var heightPx = Math.max(1, nextTop - top);
              var key = kind + ':' + tz + ':' + wrappedX + ':' + ty;
              activeSet[key] = true;
              var img = acquireTile(kind, wrappedX, ty, tz);
              img.style.left = left + 'px';
              img.style.top = top + 'px';
              img.style.width = widthPx + 'px';
              img.style.height = heightPx + 'px';
              img.style.zIndex = String(zIndex);
              if (img.parentNode !== tileLayer) {
                tileLayer.appendChild(img);
              }
            }
          }
        }

        var existing = tileLayer.children;
        for (var i = existing.length - 1; i >= 0; i--) {
          var node = existing[i];
          var found = false;
          for (var k in activeSet) {
            if (tileCache[k] === node) {
              found = true;
              break;
            }
          }
          if (!found) {
            tileLayer.removeChild(node);
          }
        }
      }

      function renderOverlays() {
        var mpp = 156543.03392 * Math.cos(clampLat(state.centerLat) * Math.PI / 180) / Math.pow(2, state.zoom);
        var svgHtml = '';
        var myScreen = state.my ? toScreen(state.my.lon, state.my.lat) : null;
        var incScreen = state.incident ? toScreen(state.incident.lon, state.incident.lat) : null;

        if (myScreen && state.my.accuracy > 0 && mpp > 0) {
          var radiusPx = Math.max(8, Math.min(240, state.my.accuracy / mpp));
          svgHtml += '<circle cx="' + myScreen.x.toFixed(1) + '" cy="' + myScreen.y.toFixed(1) + '" r="' + radiusPx.toFixed(1) + '" fill="rgba(37,99,235,0.14)" stroke="rgba(37,99,235,0.45)" stroke-width="1"/>';
        }
        if (myScreen && incScreen) {
          svgHtml += '<line x1="' + myScreen.x.toFixed(1) + '" y1="' + myScreen.y.toFixed(1) + '" x2="' + incScreen.x.toFixed(1) + '" y2="' + incScreen.y.toFixed(1) + '" stroke="#DC2626" stroke-width="3" stroke-opacity="0.88" stroke-dasharray="10,6" stroke-linecap="round"/>';
        }
        overlaySvg.innerHTML = svgHtml;

        markerLayer.innerHTML = '';
        if (incScreen) {
          var incEl = document.createElement('div');
          incEl.className = 'wd-incident-pin';
          incEl.style.left = incScreen.x.toFixed(1) + 'px';
          incEl.style.top = incScreen.y.toFixed(1) + 'px';
          incEl.style.zIndex = '110';
          var incDot = document.createElement('span');
          incDot.className = 'wd-incident-dot';
          var incTxt = document.createElement('span');
          incTxt.textContent = (state.incident && state.incident.title) || '事发地点';
          incEl.appendChild(incDot);
          incEl.appendChild(incTxt);
          markerLayer.appendChild(incEl);
        }
        if (myScreen) {
          var myEl = document.createElement('div');
          myEl.className = 'wd-my-wrap';
          myEl.style.left = myScreen.x.toFixed(1) + 'px';
          myEl.style.top = myScreen.y.toFixed(1) + 'px';
          myEl.style.zIndex = '120';
          var arrow = document.createElement('div');
          arrow.className = 'wd-my-heading';
          if (typeof state.my.bearing === 'number' && isFinite(state.my.bearing)) {
            arrow.style.display = 'block';
            arrow.style.transform = 'rotate(' + state.my.bearing.toFixed(1) + 'deg)';
          }
          var dot = document.createElement('div');
          dot.className = 'wd-my-dot';
          myEl.appendChild(arrow);
          myEl.appendChild(dot);
          markerLayer.appendChild(myEl);
        }

        var steps = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000];
        var chosen = steps[0];
        var pxWidth = 60;
        for (var i = 0; i < steps.length; i++) {
          var candidatePx = mpp > 0 ? (steps[i] / mpp) : 60;
          chosen = steps[i];
          pxWidth = candidatePx;
          if (candidatePx >= 52) break;
        }
        pxWidth = Math.max(36, Math.min(120, Math.round(pxWidth)));
        scaleLabel.textContent = chosen >= 1000 ? (chosen / 1000) + ' km' : chosen + ' m';
        scaleLine.style.width = pxWidth + 'px';
      }

      function renderNow() {
        renderScheduled = false;
        renderTiles();
        renderOverlays();
      }

      function scheduleRender() {
        if (renderScheduled) return;
        renderScheduled = true;
        requestAnimationFrame(renderNow);
      }

      function panByPixels(dx, dy) {
        var c = lonLatToWorld(state.centerLon, state.centerLat, state.zoom);
        var next = worldToLonLat(c.x - dx, c.y - dy, state.zoom);
        state.centerLon = next.lon;
        state.centerLat = next.lat;
      }

      var touchMode = 'none';
      var lastTouchX = 0;
      var lastTouchY = 0;
      var totalPanPx = 0;
      var draggedNotified = false;
      var pinchStartDist = 0;
      var pinchStartZoom = state.zoom;
      var lastPinchMidX = 0;
      var lastPinchMidY = 0;
      var lastTapAt = 0;
      var lastTapX = 0;
      var lastTapY = 0;

      function touchDist(t1, t2) {
        var dx = t2.clientX - t1.clientX;
        var dy = t2.clientY - t1.clientY;
        return Math.sqrt(dx * dx + dy * dy);
      }

      container.addEventListener('touchstart', function(e) {
        if (e.touches.length === 1) {
          var t = e.touches[0];
          touchMode = 'pan';
          lastTouchX = t.clientX;
          lastTouchY = t.clientY;
          totalPanPx = 0;
          draggedNotified = false;
        } else if (e.touches.length >= 2) {
          touchMode = 'pinch';
          pinchStartDist = Math.max(10, touchDist(e.touches[0], e.touches[1]));
          pinchStartZoom = state.zoom;
          lastPinchMidX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
          lastPinchMidY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
          if (!draggedNotified) {
            draggedNotified = true;
            notifyBridge('userDragged', {});
          }
        }
      }, { passive: true });

      container.addEventListener('touchmove', function(e) {
        if (touchMode === 'pan' && e.touches.length === 1) {
          var t = e.touches[0];
          var dx = t.clientX - lastTouchX;
          var dy = t.clientY - lastTouchY;
          lastTouchX = t.clientX;
          lastTouchY = t.clientY;
          totalPanPx += Math.abs(dx) + Math.abs(dy);
          if (!draggedNotified && totalPanPx > 6) {
            draggedNotified = true;
            notifyBridge('userDragged', {});
          }
          panByPixels(dx, dy);
          scheduleRender();
        } else if (e.touches.length >= 2) {
          var midX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
          var midY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
          var dist = Math.max(10, touchDist(e.touches[0], e.touches[1]));
          if (touchMode !== 'pinch') {
            touchMode = 'pinch';
            pinchStartDist = dist;
            pinchStartZoom = state.zoom;
          } else {
            panByPixels(midX - lastPinchMidX, midY - lastPinchMidY);
            var deltaZoom = Math.log(dist / pinchStartDist) / Math.LN2;
            state.zoom = Math.max(3, Math.min(18, pinchStartZoom + deltaZoom));
          }
          lastPinchMidX = midX;
          lastPinchMidY = midY;
          scheduleRender();
        }
      }, { passive: true });

      container.addEventListener('touchend', function(e) {
        if (touchMode === 'pan' && e.touches.length === 0 && totalPanPx < 10) {
          var nowMs = Date.now();
          if (
            nowMs - lastTapAt < 280 &&
            Math.abs(lastTouchX - lastTapX) < 32 &&
            Math.abs(lastTouchY - lastTapY) < 32
          ) {
            state.zoom = Math.min(18, Math.round(state.zoom) + 1);
            scheduleRender();
            lastTapAt = 0;
          } else {
            lastTapAt = nowMs;
            lastTapX = lastTouchX;
            lastTapY = lastTouchY;
          }
        }
        if (e.touches.length === 1) {
          touchMode = 'pan';
          lastTouchX = e.touches[0].clientX;
          lastTouchY = e.touches[0].clientY;
        } else if (e.touches.length === 0) {
          touchMode = 'none';
        }
      }, { passive: true });

      if (typeof ResizeObserver !== 'undefined') {
        new ResizeObserver(scheduleRender).observe(container);
      } else {
        window.addEventListener('resize', scheduleRender);
      }

      window.watchdogMap = {
        setLayerMode: function(mode) {
          state.layerMode = mode || 'hybrid';
          scheduleRender();
        },
        updateMyLocation: function(lon, lat, accuracy, bearing, shouldCenter) {
          state.my = { lon: lon, lat: lat, accuracy: accuracy || 0, bearing: bearing };
          if (shouldCenter || !state.hasCenteredMy) {
            state.hasCenteredMy = true;
            state.centerLon = lon;
            state.centerLat = lat;
            if (state.zoom < 15) state.zoom = 17;
          }
          scheduleRender();
        },
        updateIncident: function(lon, lat, title) {
          state.incident = { lon: lon, lat: lat, title: title || '事发地点' };
          scheduleRender();
        },
        focusMyLocation: function() {
          if (!state.my) return;
          state.centerLon = state.my.lon;
          state.centerLat = state.my.lat;
          if (state.zoom < 16) state.zoom = 17;
          scheduleRender();
        },
        focusIncident: function() {
          if (!state.incident) return;
          state.centerLon = state.incident.lon;
          state.centerLat = state.incident.lat;
          if (state.zoom < 15) state.zoom = 16;
          scheduleRender();
        },
        fitBoth: function() {
          if (state.my && state.incident) {
            var w = Math.max(120, (container.clientWidth || 360) - 120);
            var h = Math.max(120, (container.clientHeight || 640) - 320);
            var bestZoom = 5;
            for (var z = 17; z >= 3; z--) {
              var p1 = lonLatToWorld(state.my.lon, state.my.lat, z);
              var p2 = lonLatToWorld(state.incident.lon, state.incident.lat, z);
              if (Math.abs(p1.x - p2.x) <= w && Math.abs(p1.y - p2.y) <= h) {
                bestZoom = z;
                break;
              }
            }
            var w1 = lonLatToWorld(state.my.lon, state.my.lat, bestZoom);
            var w2 = lonLatToWorld(state.incident.lon, state.incident.lat, bestZoom);
            var mid = worldToLonLat((w1.x + w2.x) / 2, (w1.y + w2.y) / 2, bestZoom);
            state.zoom = bestZoom;
            state.centerLon = mid.lon;
            state.centerLat = mid.lat;
            scheduleRender();
          } else if (state.my) {
            window.watchdogMap.focusMyLocation();
          } else if (state.incident) {
            window.watchdogMap.focusIncident();
          }
        }
      };

      renderNow();
      notifyBridge('mapReady', { engine: 'raster' });
    })();
  </script>
</body>
</html>
''';
}

enum _LocStatus { unknown, ok, permissionDenied, serviceDisabled, fixFailed }

class SceneMapPage extends StatefulWidget {
  final AppController controller;
  final SceneMapGateway? gateway;

  const SceneMapPage({super.key, required this.controller, this.gateway});

  @override
  State<SceneMapPage> createState() => _SceneMapPageState();
}

class _SceneMapPageState extends State<SceneMapPage>
    with WidgetsBindingObserver {
  late final SceneMapGateway _gateway;
  final SceneMapSurfaceController _surfaceController =
      SceneMapSurfaceController();

  SceneMapLayerMode _layerMode = SceneMapLayerMode.hybrid;
  bool _followMe = true;
  bool _loadingBootstrap = true;
  String? _bootstrapError;
  String? _scriptError;
  SceneMapBootstrap? _bootstrap;

  _LocStatus _locStatus = _LocStatus.unknown;
  LocationFix? _myWgsFix;
  ({double lat, double lon})? _myGcj;
  String? _myAddress;
  DateTime? _lastRegeoAt;
  double? _lastRegeoLat;
  double? _lastRegeoLon;
  bool _regeoInFlight = false;

  RouteTrafficInfo? _incidentInfo;
  String? _incidentDisplayLocation;
  ({double lat, double lon})? _incidentGcj;

  StreamSubscription<LocationFix>? _watchSub;
  int _generation = 0;
  bool _surfaceReady = false;
  bool _htmlLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final ctrl = widget.controller;
    _gateway =
        widget.gateway ??
        SceneMapGateway(
          requestPermission: CameraBridge.requestLocationPermission,
          locationServiceEnabled: CameraBridge.isLocationServiceEnabled,
          currentLocation: () =>
              CameraBridge.currentLocation(timeout: const Duration(seconds: 6)),
          watchLocation: CameraBridge.watchLocation,
          fetchMapBootstrap: () async {
            final api = ctrl.api;
            if (api == null) throw Exception('未连接服务端');
            return api.fetchSceneMapBootstrap();
          },
          fetchWeather: (lat, lon) async =>
              ctrl.api?.fetchWeather(lat: lat, lon: lon) ?? WeatherInfo.empty,
          fetchIncidentRouteInfo: ({
            required String address,
            String? city,
            double? destLat,
            double? destLon,
          }) async {
            final api = ctrl.api;
            if (api == null) throw Exception('未连接服务端');
            return api.fetchRouteTraffic(
              address: address,
              city: city,
              destLat: destLat,
              destLon: destLon,
            );
          },
          fetchIncidentDetails: (id) async {
            final api = ctrl.api;
            if (api == null) return {};
            return api.forIncident(id).fetchIncidentDetails();
          },
          openAppSettings: ScreenOn.openAppSettings,
          openLocationSettings: CameraBridge.openLocationSettings,
          launchNavigation: (uri) =>
              launchUrl(uri, mode: LaunchMode.externalApplication),
          now: DateTime.now,
        );

    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_stopWatching());
    } else if (state == AppLifecycleState.resumed) {
      if (_locStatus == _LocStatus.ok || _locStatus == _LocStatus.fixFailed) {
        unawaited(_startWatching());
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopWatching());
    _surfaceController.detach();
    super.dispose();
  }

  Future<void> _stopWatching() async {
    final sub = _watchSub;
    _watchSub = null;
    if (sub != null) {
      await sub.cancel();
    }
  }

  Future<void> _initialize() async {
    final gen = ++_generation;
    await _stopWatching();
    if (!mounted) return;
    setState(() {
      _loadingBootstrap = true;
      _bootstrapError = null;
      _scriptError = null;
      _htmlLoaded = false;
    });

    await Future.wait([
      _loadBootstrap(gen),
      _initLocation(gen),
      _loadIncidentPoint(gen),
    ]);
  }

  Future<void> _loadBootstrap(int gen) async {
    final api = widget.controller.api;
    if (api == null || widget.controller.isGuest) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingBootstrap = false;
        _bootstrap = null;
        _bootstrapError = '请先完成单位认证后加载高德在线卫星图';
      });
      return;
    }

    try {
      final boot = await _gateway.fetchMapBootstrap();
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingBootstrap = false;
        _bootstrap = boot;
        _bootstrapError =
            (boot.configured || boot.code == 'AMAP_JS_NOT_CONFIGURED')
            ? null
            : (boot.message ?? '现场地图服务暂不可用');
      });
      _tryLoadHtmlIntoSurface();
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loadingBootstrap = false;
        _bootstrapError = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      });
    }
  }

  Future<void> _initLocation(int gen) async {
    try {
      final permitted = await _gateway.requestPermission();
      if (!mounted || gen != _generation) return;
      if (!permitted) {
        setState(() => _locStatus = _LocStatus.permissionDenied);
        return;
      }
      final enabled = await _gateway.locationServiceEnabled();
      if (!mounted || gen != _generation) return;
      if (!enabled) {
        setState(() => _locStatus = _LocStatus.serviceDisabled);
        return;
      }

      final quickFix = await _gateway.currentLocation();
      if (!mounted || gen != _generation) return;
      if (quickFix != null) {
        _applyLocationFix(quickFix);
      } else {
        setState(() => _locStatus = _LocStatus.fixFailed);
      }
      await _startWatching(gen);
    } catch (_) {
      if (!mounted || gen != _generation) return;
      setState(() => _locStatus = _LocStatus.fixFailed);
    }
  }

  Future<void> _startWatching([int? expectedGen]) async {
    final gen = expectedGen ?? _generation;
    await _stopWatching();
    if (!mounted || gen != _generation) return;
    _watchSub = _gateway.watchLocation().listen(
      (fix) {
        if (!mounted || gen != _generation) return;
        _applyLocationFix(fix);
      },
      onError: (_) {
        // 连续流报错时不清空已取得的最近定位
      },
    );
  }

  void _applyLocationFix(LocationFix fix) {
    final gcj = ChinaCoord.wgs84ToGcj02(fix.lat, fix.lon);
    setState(() {
      _locStatus = _LocStatus.ok;
      _myWgsFix = fix;
      _myGcj = gcj;
    });
    if (_htmlLoaded) {
      _pushMyToMap(fix, gcj);
    }
    _maybeRefreshAddress(fix);
  }

  void _pushMyToMap(LocationFix fix, ({double lat, double lon}) gcj) {
    final acc = fix.accuracyMeters > 0 ? fix.accuracyMeters : 0.0;
    final bearingArg = fix.bearingDegrees == null
        ? 'null'
        : fix.bearingDegrees!.toStringAsFixed(1);
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogMap && window.watchdogMap.updateMyLocation(${gcj.lon}, ${gcj.lat}, $acc, $bearingArg, $_followMe);',
      ),
    );
  }

  void _maybeRefreshAddress(LocationFix fix) {
    if (widget.controller.api == null || _regeoInFlight) return;
    final now = _gateway.now();
    final shouldFetch =
        _lastRegeoAt == null ||
        (now.difference(_lastRegeoAt!) >= const Duration(seconds: 15) &&
            _lastRegeoLat != null &&
            _lastRegeoLon != null &&
            ChinaCoord.distanceMeters(
                  _lastRegeoLat!,
                  _lastRegeoLon!,
                  fix.lat,
                  fix.lon,
                ) >=
                80.0);
    if (!shouldFetch) return;

    _regeoInFlight = true;
    final queryLat = fix.lat;
    final queryLon = fix.lon;
    _lastRegeoAt = now;
    _lastRegeoLat = queryLat;
    _lastRegeoLon = queryLon;
    final gen = _generation;

    unawaited(
      _gateway
          .fetchWeather(queryLat, queryLon)
          .then((weather) {
            if (!mounted || gen != _generation) return;
            final addr = (weather.address ?? '').trim();
            if (addr.isNotEmpty) {
              setState(() => _myAddress = addr);
            }
          })
          .catchError((_) {})
          .whenComplete(() {
            _regeoInFlight = false;
          }),
    );
  }

  Future<void> _loadIncidentPoint(int gen) async {
    final incident = widget.controller.currentIncident;
    if (incident == null) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _incidentInfo = null;
        _incidentDisplayLocation = null;
        _incidentGcj = null;
      });
      return;
    }

    var location = incident.effectiveLocation;
    var city = (incident.info['administrative_area']?.toString() ?? '').trim();
    var officialLat = double.tryParse(
      incident.info['latitude']?.toString() ?? '',
    );
    var officialLon = double.tryParse(
      incident.info['longitude']?.toString() ?? '',
    );

    if ((location.isEmpty ||
            city.isEmpty ||
            officialLat == null ||
            officialLon == null) &&
        _gateway.fetchIncidentDetails != null &&
        widget.controller.api != null) {
      try {
        final details = await _gateway.fetchIncidentDetails!(incident.id);
        if (details['data'] is Map) {
          final data = Map<String, dynamic>.from(details['data'] as Map);
          if (location.isEmpty) {
            location = (data['location']?.toString() ?? '').trim();
          }
          if (city.isEmpty) {
            city = (data['administrative_area']?.toString() ?? '').trim();
          }
          officialLat ??= double.tryParse(data['latitude']?.toString() ?? '');
          officialLon ??= double.tryParse(data['longitude']?.toString() ?? '');
        }
      } catch (_) {}
    }

    if (!mounted || gen != _generation) return;
    if (location.isEmpty && (officialLat == null || officialLon == null)) {
      return;
    }

    if (officialLat != null && officialLon != null) {
      setState(() {
        _incidentDisplayLocation = location.isNotEmpty
            ? location
            : incident.displayName;
        _incidentGcj = (lat: officialLat!, lon: officialLon!);
      });
      _pushIncidentToMap();
    }

    if (widget.controller.api == null || location.isEmpty) return;

    try {
      final info = await _gateway.fetchIncidentRouteInfo(
        address: location,
        city: city.isNotEmpty ? city : null,
        destLat: officialLat,
        destLon: officialLon,
      );
      if (!mounted || gen != _generation) return;
      final loc = info.destination?.location;
      final destCoord =
          (loc != null && loc.lat.isFinite && loc.lon.isFinite)
          ? (lat: loc.lat, lon: loc.lon)
          : _incidentGcj;
      setState(() {
        _incidentInfo = info;
        _incidentDisplayLocation =
            info.destination?.displayAddress.isNotEmpty == true
            ? info.destination!.displayAddress
            : (location.isNotEmpty ? location : incident.displayName);
        _incidentGcj = destCoord;
      });
      _pushIncidentToMap();
    } catch (_) {
      // 事发地坐标解析失败时不影响本机实时定位与卫星底图显示
    }
  }

  void _pushIncidentToMap() {
    final gcj = _incidentGcj;
    if (!_htmlLoaded || gcj == null) return;
    final title = _safeJsonEncode(
      (_incidentDisplayLocation ?? '').trim().isNotEmpty
          ? _incidentDisplayLocation!.trim()
          : '事发地点',
    );
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogMap && window.watchdogMap.updateIncident(${gcj.lon}, ${gcj.lat}, $title);',
      ),
    );
  }

  void _tryLoadHtmlIntoSurface() {
    final boot = _bootstrap;
    if (!_surfaceReady ||
        boot == null ||
        (!boot.configured && boot.code != 'AMAP_JS_NOT_CONFIGURED') ||
        _htmlLoaded) {
      return;
    }
    final apiBase = widget.controller.api?.baseUrl ?? '';
    final serviceHost = boot.resolveServiceHost(apiBase);
    final myGcj = _myGcj;
    final fix = _myWgsFix;
    final html = buildSceneMapHtml(
      jsKey: boot.jsKey,
      serviceHost: serviceHost,
      initialLayer: _layerMode,
      initialMyGcj: myGcj == null
          ? null
          : (
              lat: myGcj.lat,
              lon: myGcj.lon,
              accuracy: (fix != null && fix.accuracyMeters > 0)
                  ? fix.accuracyMeters
                  : 0.0,
              bearing: fix?.bearingDegrees,
            ),
      initialIncidentGcj: _incidentGcj == null
          ? null
          : (
              lat: _incidentGcj!.lat,
              lon: _incidentGcj!.lon,
              title: (_incidentDisplayLocation ?? '').trim().isNotEmpty
                  ? _incidentDisplayLocation!.trim()
                  : '事发地点',
            ),
    );
    _htmlLoaded = true;
    final baseUrl = apiBase.trim().isNotEmpty ? apiBase.trim() : 'https://fireman119.xyz';
    unawaited(_surfaceController.loadHtml(baseUrl, html));
  }

  void _onLayerChanged(SceneMapLayerMode mode) {
    if (_layerMode == mode) return;
    setState(() => _layerMode = mode);
    if (_htmlLoaded) {
      unawaited(
        _surfaceController.evalJs(
          'window.watchdogMap && window.watchdogMap.setLayerMode(${_safeJsonEncode(mode.jsValue)});',
        ),
      );
    }
  }

  void _focusMyLocation() {
    if (_locStatus == _LocStatus.permissionDenied ||
        _locStatus == _LocStatus.serviceDisabled ||
        _myGcj == null) {
      unawaited(_initLocation(_generation));
      return;
    }
    setState(() => _followMe = true);
    if (_htmlLoaded) {
      unawaited(
        _surfaceController.evalJs(
          'window.watchdogMap && window.watchdogMap.focusMyLocation();',
        ),
      );
    }
  }

  void _focusIncident() {
    if (_incidentGcj == null) return;
    setState(() => _followMe = false);
    if (_htmlLoaded) {
      unawaited(
        _surfaceController.evalJs(
          'window.watchdogMap && window.watchdogMap.focusIncident();',
        ),
      );
    }
  }

  void _fitBoth() {
    setState(() => _followMe = false);
    if (_htmlLoaded) {
      unawaited(
        _surfaceController.evalJs(
          'window.watchdogMap && window.watchdogMap.fitBoth();',
        ),
      );
    }
  }

  Future<void> _startNavigation() async {
    final coord = _incidentGcj;
    final info = _incidentInfo;
    final destName =
        (_incidentDisplayLocation ?? info?.destination?.displayAddress ?? '')
            .trim();
    final webUri =
        info?.navigationUri ??
        (coord == null
            ? null
            : Uri.https('uri.amap.com', '/navigation', {
                'to': destName.isNotEmpty
                    ? '${coord.lon.toStringAsFixed(6)},${coord.lat.toStringAsFixed(6)},$destName'
                    : '${coord.lon.toStringAsFixed(6)},${coord.lat.toStringAsFixed(6)}',
                'mode': 'car',
                'src': 'watchdog',
                'callnative': '1',
              }));
    final nativeUri =
        info?.nativeAndroidNavigationUri ??
        (coord == null
            ? null
            : Uri(
                scheme: 'androidamap',
                host: 'navi',
                queryParameters: {
                  'sourceApplication': 'watchdog',
                  'poiname': destName.isNotEmpty ? destName : '事发地点',
                  'lat': coord.lat.toStringAsFixed(6),
                  'lon': coord.lon.toStringAsFixed(6),
                  'dev': '0',
                  'style': '2',
                },
              ));
    if (webUri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('未获取到事发地点坐标，无法导航')));
      }
      return;
    }

    var ok = false;
    if (defaultTargetPlatform == TargetPlatform.android && nativeUri != null) {
      try {
        ok = await _gateway.launchNavigation(nativeUri);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      try {
        ok = await _gateway.launchNavigation(webUri);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('无法打开外部地图导航应用')));
    }
  }

  void _handleBridgeEvent(String type, Map<String, dynamic> data) {
    if (!mounted) return;
    if (type == 'userDragged') {
      if (_followMe) setState(() => _followMe = false);
    } else if (type == 'scriptError' || type == 'loadError') {
      final msg = data['message']?.toString().trim();
      setState(() {
        _scriptError = (msg != null && msg.isNotEmpty)
            ? msg
            : '地图底图加载失败，请检查网络后重试';
      });
    } else if (type == 'mapReady') {
      if (_scriptError != null) {
        setState(() => _scriptError = null);
      }
      _syncAllStateToMap();
    }
  }

  void _syncAllStateToMap() {
    if (!_htmlLoaded) return;
    unawaited(
      _surfaceController.evalJs(
        'window.watchdogMap && window.watchdogMap.setLayerMode(${_safeJsonEncode(_layerMode.jsValue)});',
      ),
    );
    final fix = _myWgsFix;
    final myGcj = _myGcj;
    if (fix != null && myGcj != null) {
      _pushMyToMap(fix, myGcj);
    }
    _pushIncidentToMap();
  }

  bool get _canRenderMapSurface =>
      !_loadingBootstrap &&
      _bootstrapError == null &&
      _bootstrap != null &&
      (_bootstrap!.configured || _bootstrap!.code == 'AMAP_JS_NOT_CONFIGURED');

  double? get _distanceToIncidentMeters {
    final me = _myGcj;
    final dest = _incidentGcj;
    if (me == null || dest == null) return null;
    return ChinaCoord.distanceMeters(me.lat, me.lon, dest.lat, dest.lon);
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('现场地图'),
        actions: [
          IconButton(
            key: const Key('scene-map-refresh'),
            tooltip: '刷新地图与定位',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _initialize,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(child: _buildMapArea(context)),
            Positioned(
              left: AppSpacing.s3,
              right: AppSpacing.s3,
              top: AppSpacing.s3,
              child: _buildTopOverlay(),
            ),
            Positioned(
              right: AppSpacing.s3,
              bottom: AppSpacing.s3,
              left: AppSpacing.s3,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_canRenderMapSurface) ...[
                    _buildQuickFocusButtons(),
                    const SizedBox(height: AppSpacing.s2),
                  ],
                  _buildBottomTelemetryCard(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapArea(BuildContext context) {
    if (_loadingBootstrap) {
      return Center(
        child: AppCard(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s5,
            vertical: AppSpacing.s4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: AppSpacing.s3),
              Text(
                '正在初始化卫星地图…',
                style: AppTextStyles.bodyMd.copyWith(
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_canRenderMapSurface) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s4,
            AppSpacing.s4,
            AppSpacing.s4,
            160,
          ),
          child: AppCard(
            key: const Key('scene-map-unavailable-card'),
            padding: const EdgeInsets.all(AppSpacing.s5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.satellite_alt_outlined,
                  size: 40,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(height: AppSpacing.s3),
                Text(
                  '暂无法加载高德卫星底图',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.title.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  _bootstrapError ?? '服务端尚未配置高德 Web 端 (JS API) Key',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodyMd.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                FilledButton.icon(
                  key: const Key('scene-map-retry-bootstrap'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(120, 48),
                  ),
                  onPressed: _initialize,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重试连接'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_gateway.mapSurfaceBuilder != null) {
      if (!_surfaceReady) {
        _surfaceReady = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _tryLoadHtmlIntoSurface();
        });
      }
      return _gateway.mapSurfaceBuilder!(
        context,
        _surfaceController,
        _handleBridgeEvent,
      );
    }

    return _AndroidAmapSurface(
      surfaceController: _surfaceController,
      backgroundColor: AppColors.background.toARGB32(),
      onReady: () {
        _surfaceReady = true;
        _tryLoadHtmlIntoSurface();
      },
      onBridgeEvent: _handleBridgeEvent,
    );
  }

  Widget _buildTopOverlay() {
    final mapReadyForLayers = _canRenderMapSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mapReadyForLayers)
          Align(
            alignment: Alignment.centerLeft,
            child: AppCard(
              radius: AppRadius.md,
              padding: const EdgeInsets.all(AppSpacing.s1),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final mode in SceneMapLayerMode.values)
                      _layerChip(mode),
                  ],
                ),
              ),
            ),
          ),
        if (_locStatus != _LocStatus.ok && _locStatus != _LocStatus.unknown) ...[
          if (mapReadyForLayers) const SizedBox(height: AppSpacing.s2),
          _buildLocationNotice(),
        ],
        if (_scriptError != null) ...[
          const SizedBox(height: AppSpacing.s2),
          AppBanner(
            kind: AppBannerKind.offline,
            text: _scriptError!,
            actionLabel: '重试',
            onAction: _initialize,
          ),
        ],
      ],
    );
  }

  Widget _layerChip(SceneMapLayerMode mode) {
    final selected = _layerMode == mode;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.s1),
      child: Material(
        color: selected ? AppColors.actionPrimary : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          key: Key('scene-map-layer-${mode.jsValue}'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () => _onLayerChanged(mode),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3,
                vertical: AppSpacing.s2,
              ),
              child: Center(
                child: Text(
                  mode.label,
                  style: AppTextStyles.label.copyWith(
                    color: selected
                        ? AppColors.onPrimary
                        : AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocationNotice() {
    final String text;
    final String actionLabel;
    final VoidCallback onAction;
    switch (_locStatus) {
      case _LocStatus.permissionDenied:
        text = '未授予定位权限，无法实时标记当前位置';
        actionLabel = '去授权';
        onAction = () => unawaited(_gateway.openAppSettings());
        break;
      case _LocStatus.serviceDisabled:
        text = '系统定位服务未开启，请开启后重试';
        actionLabel = '去开启';
        onAction = () => unawaited(_gateway.openLocationSettings());
        break;
      case _LocStatus.fixFailed:
        text = '暂未获取到实时定位，可点击右侧定位图标重试';
        actionLabel = '重试';
        onAction = () => unawaited(_initLocation(_generation));
        break;
      case _LocStatus.unknown:
      case _LocStatus.ok:
        return const SizedBox.shrink();
    }

    return AppNotice(
      key: const Key('scene-map-location-notice'),
      kind: AppNoticeKind.warning,
      text: text,
      action: TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: onAction,
        child: Text(actionLabel),
      ),
    );
  }

  Widget _buildQuickFocusButtons() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _mapActionButton(
          key: const Key('scene-map-focus-me'),
          icon: _followMe ? Icons.my_location_rounded : Icons.location_searching,
          tooltip: '我的位置',
          active: _followMe && _myGcj != null,
          onTap: _focusMyLocation,
        ),
        if (_incidentGcj != null) ...[
          const SizedBox(height: AppSpacing.s2),
          _mapActionButton(
            key: const Key('scene-map-focus-incident'),
            icon: Icons.location_on_rounded,
            tooltip: '事发地点',
            iconColor: AppColors.alarm,
            onTap: _focusIncident,
          ),
          const SizedBox(height: AppSpacing.s2),
          _mapActionButton(
            key: const Key('scene-map-fit-both'),
            icon: Icons.fit_screen_rounded,
            tooltip: '全览两点',
            onTap: _fitBoth,
          ),
        ],
      ],
    );
  }

  Widget _mapActionButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
    Color? iconColor,
  }) {
    return Tooltip(
      message: tooltip,
      child: AppCard(
        key: key,
        radius: AppRadius.md,
        padding: EdgeInsets.zero,
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            icon,
            size: 22,
            color:
                iconColor ??
                (active ? AppColors.noteInfo : AppColors.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomTelemetryCard() {
    final fix = _myWgsFix;
    final accuracyText = (fix != null && fix.accuracyMeters > 0)
        ? '±${fix.accuracyMeters.toStringAsFixed(0)} m'
        : null;
    final distanceMeters = _distanceToIncidentMeters;
    final incidentName = widget.controller.currentIncident?.displayName ?? '';

    return AppCard(
      key: const Key('scene-map-telemetry-card'),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _locStatus == _LocStatus.ok
                      ? AppColors.online
                      : AppColors.caution,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  _myAddress?.isNotEmpty == true
                      ? _myAddress!
                      : (_locStatus == _LocStatus.ok
                            ? '实时定位已开启'
                            : '正在获取当前位置…'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMd.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (accuracyText != null) ...[
                const SizedBox(width: AppSpacing.s2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s2,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSubtle,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    accuracyText,
                    style: AppTextStyles.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (fix != null) ...[
            const SizedBox(height: AppSpacing.s1),
            Text(
              'WGS84 ${fix.lat.toStringAsFixed(6)}, ${fix.lon.toStringAsFixed(6)}',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (_incidentGcj != null ||
              (_incidentDisplayLocation?.isNotEmpty ?? false)) ...[
            const SizedBox(height: AppSpacing.s2),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.s2),
            Row(
              children: [
                Icon(
                  Icons.local_fire_department_rounded,
                  size: 18,
                  color: AppColors.alarm,
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _incidentDisplayLocation ?? incidentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.label.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (distanceMeters != null)
                        Text(
                          '直线距离 ${ChinaCoord.formatDistance(distanceMeters)}',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.alarmText,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
                if (_incidentGcj != null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  FilledButton.icon(
                    key: const Key('scene-map-navigate'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(88, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s3,
                      ),
                    ),
                    onPressed: _startNavigation,
                    icon: const Icon(Icons.navigation_rounded, size: 18),
                    label: const Text('导航'),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AndroidAmapSurface extends StatefulWidget {
  final SceneMapSurfaceController surfaceController;
  final int backgroundColor;
  final VoidCallback onReady;
  final void Function(String type, Map<String, dynamic> data) onBridgeEvent;

  const _AndroidAmapSurface({
    required this.surfaceController,
    required this.backgroundColor,
    required this.onReady,
    required this.onBridgeEvent,
  });

  @override
  State<_AndroidAmapSurface> createState() => _AndroidAmapSurfaceState();
}

class _AndroidAmapSurfaceState extends State<_AndroidAmapSurface> {
  MethodChannel? _channel;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    widget.surfaceController.detach();
    super.dispose();
  }

  void _onPlatformViewCreated(int viewId) {
    final channel = MethodChannel('watchdog/amap_view_$viewId');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onBridgeMessage') {
        final raw = call.arguments as String? ?? '';
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map) {
            final type = parsed['type']?.toString() ?? '';
            final data = parsed['data'] is Map
                ? Map<String, dynamic>.from(parsed['data'] as Map)
                : const <String, dynamic>{};
            widget.onBridgeEvent(type, data);
          }
        } catch (_) {}
      }
      return null;
    });

    widget.surfaceController.attach(
      onLoadHtml: (baseUrl, html) =>
          channel.invokeMethod<void>('loadHtml', {'baseUrl': baseUrl, 'html': html}),
      onEvalJs: (script) =>
          channel.invokeMethod<void>('evalJs', {'script': script}),
    );
    widget.onReady();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return Center(
        child: Text(
          '当前平台暂不支持内置地图视图',
          style: AppTextStyles.bodyMd.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    return AndroidView(
      viewType: 'watchdog/amap_view',
      creationParams: {'backgroundColor': widget.backgroundColor},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}
