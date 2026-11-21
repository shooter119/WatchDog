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
  hybrid('hybrid', '混合', '卫星+路网'),
  satellite('satellite', '卫星', '纯卫星'),
  standard('standard', '标准', '标准图');

  final String jsValue;
  final String shortLabel;
  final String label;
  const SceneMapLayerMode(this.jsValue, this.shortLabel, this.label);
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

const String _sharedOverlayCss = '''
    .wd-my-wrap {
      position: relative;
      width: 30px;
      height: 30px;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    #marker-layer .wd-my-wrap {
      position: absolute;
      margin-left: -15px;
      margin-top: -15px;
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
    .wd-incident-anchor {
      position: relative;
      width: 0;
      height: 0;
      overflow: visible;
      pointer-events: none;
    }
    #marker-layer .wd-incident-anchor {
      position: absolute;
    }
    .wd-incident-halo {
      position: absolute;
      left: 0;
      top: 0;
      width: 28px;
      height: 28px;
      margin-left: -14px;
      margin-top: -14px;
      border-radius: 50%;
      background: rgba(220, 38, 38, 0.22);
      border: 2px solid rgba(220, 38, 38, 0.92);
      box-shadow: 0 0 0 1.5px rgba(255, 255, 255, 0.78);
    }
    .wd-incident-core {
      position: absolute;
      left: 0;
      top: 0;
      width: 12px;
      height: 12px;
      margin-left: -6px;
      margin-top: -6px;
      border-radius: 50%;
      background: #DC2626;
      border: 2.5px solid #FFFFFF;
      box-shadow: 0 1px 6px rgba(0, 0, 0, 0.52);
    }
    .wd-incident-bubble {
      position: absolute;
      left: 0;
      top: 0;
      transform: translate(-50%, calc(-100% - 7px));
      display: flex;
      flex-direction: column;
      align-items: center;
      pointer-events: none;
    }
    .wd-incident-card {
      width: max-content;
      max-width: 158px;
      padding: 5px 9px;
      border-radius: 10px;
      background: #DC2626;
      color: #FFFFFF;
      border: 2px solid #FFFFFF;
      box-shadow: 0 3px 10px rgba(0, 0, 0, 0.42);
      font-size: 12px;
      font-weight: 700;
      line-height: 1.28;
    }
    .wd-incident-text {
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      overflow: hidden;
      white-space: normal;
      word-break: break-all;
      text-align: center;
    }
    .wd-incident-stem {
      display: block;
      margin-top: -2px;
      line-height: 0;
      filter: drop-shadow(0 2px 3px rgba(0, 0, 0, 0.32));
    }
    .wd-offscreen-guide {
      position: absolute;
      z-index: 140;
      display: none;
      align-items: center;
      gap: 6px;
      padding: 7px 11px;
      border-radius: 999px;
      background: rgba(220, 38, 38, 0.96);
      color: #FFFFFF;
      border: 2px solid #FFFFFF;
      box-shadow: 0 4px 14px rgba(0, 0, 0, 0.38);
      font-size: 12px;
      font-weight: 700;
      line-height: 1.2;
      white-space: nowrap;
      pointer-events: auto;
      cursor: pointer;
      transform: translate(-50%, -50%);
    }
    .wd-offscreen-arrow {
      width: 16px;
      height: 16px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
    }
    .wd-offscreen-label {
      line-height: 1.2;
    }
''';

const String _sharedPinAndGuideJs = r'''
      function shortPinLabel(raw, maxChars) {
        var limit = typeof maxChars === 'number' && maxChars >= 2 ? maxChars : 18;
        var text = String(raw || '').trim().replace(/\s+/g, ' ');
        text = text.replace(/^[\s,，、.。;；:：\-–—/|·]+/, '').trim();
        if (!text) return '事发地点';
        var steps = [
          /^[^\s\d,，。、;；:：\-/()（）省市县区]{1,12}?(?:特别行政区|自治区|省)/,
          /^[^\s\d,，。、;；:：\-/()（）省市县区]{1,12}?(?:自治州|地区|市(?!区)|盟)/,
          /^[^\s\d,，。、;；:：\-/()（）省县区]{1,12}?(?:自治县|自治旗|县|区|旗)/
        ];
        for (var i = 0; i < steps.length; i++) {
          var m = text.match(steps[i]);
          if (m) {
            if (i === 2 && /(?:小区|社区|园区|开发区|景区|港区|校区|库区|营区|厂区|矿区)$/.test(m[0])) continue;
            var rest = text.slice(m[0].length).replace(/^[\s,，、.。;；:：\-–—\/|·]+/, '').trim();
            if (rest.length >= 2) {
              text = rest;
            }
          }
        }
        if (text.length > limit) {
          text = text.slice(0, limit - 1) + '…';
        }
        return text || '事发地点';
      }

      function createIncidentDom(title) {
        var anchor = document.createElement('div');
        anchor.className = 'wd-incident-anchor';

        var halo = document.createElement('div');
        halo.className = 'wd-incident-halo';

        var core = document.createElement('div');
        core.className = 'wd-incident-core';

        var bubble = document.createElement('div');
        bubble.className = 'wd-incident-bubble';

        var card = document.createElement('div');
        card.className = 'wd-incident-card';
        var textSpan = document.createElement('span');
        textSpan.className = 'wd-incident-text';
        textSpan.textContent = shortPinLabel(title || '事发地点', 18);
        card.appendChild(textSpan);

        var stemWrap = document.createElement('div');
        stemWrap.className = 'wd-incident-stem';
        stemWrap.innerHTML = '<svg width="18" height="10" viewBox="0 0 18 10" aria-hidden="true"><path d="M1 0 L9 9 L17 0 Z" fill="#DC2626" stroke="#FFFFFF" stroke-width="2" stroke-linejoin="round"/><path d="M2.2 0 L15.8 0 L9 7.2 Z" fill="#DC2626"/></svg>';

        bubble.appendChild(card);
        bubble.appendChild(stemWrap);
        anchor.appendChild(halo);
        anchor.appendChild(core);
        anchor.appendChild(bubble);
        return anchor;
      }

      function haversineMeters(lon1, lat1, lon2, lat2) {
        var rad = Math.PI / 180;
        var dLat = (lat2 - lat1) * rad;
        var dLon = (lon2 - lon1) * rad;
        var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
          Math.cos(lat1 * rad) * Math.cos(lat2 * rad) *
          Math.sin(dLon / 2) * Math.sin(dLon / 2);
        return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
      }

      function formatDistLabel(meters) {
        if (typeof meters !== 'number' || !isFinite(meters) || meters < 0) return '';
        if (meters < 1000) return Math.round(meters) + ' m';
        return (meters / 1000).toFixed(1) + ' km';
      }

      function bindOffscreenGuideInteractions(guideEl) {
        if (!guideEl) return;
        if (!guideEl._wdReady) {
          guideEl._wdReady = true;
          guideEl.innerHTML = '<span class="wd-offscreen-arrow"><svg width="15" height="15" viewBox="0 0 18 18" aria-hidden="true"><path d="M2 3 L16 9 L2 15 L5.6 9 Z" fill="#FFFFFF"/></svg></span><span class="wd-offscreen-label">事发地</span>';
          guideEl.addEventListener('touchstart', function(e) { e.stopPropagation(); }, { passive: true });
          guideEl.addEventListener('touchmove', function(e) { e.stopPropagation(); }, { passive: true });
          guideEl.addEventListener('touchend', function(e) { e.stopPropagation(); }, { passive: true });
          guideEl.addEventListener('click', function(e) {
            e.stopPropagation();
            e.preventDefault();
            if (window.watchdogMap && window.watchdogMap.focusIncident) {
              window.watchdogMap.focusIncident();
            }
            notifyBridge('focusIncidentFromGuide', {});
          });
        }
      }

      function updateOffscreenGuide(guideEl, container, state, toScreenFn, getCenterLonLatFn) {
        if (!guideEl || !container) return;
        if (!state || !state.incident) {
          guideEl.style.display = 'none';
          return;
        }
        var incScreen = toScreenFn(state.incident.lon, state.incident.lat);
        if (!incScreen || !isFinite(incScreen.x) || !isFinite(incScreen.y)) {
          guideEl.style.display = 'none';
          return;
        }
        var w = container.clientWidth || window.innerWidth || 360;
        var h = container.clientHeight || window.innerHeight || 640;
        var safeLeft = Math.min(14, w * 0.05);
        var safeTop = Math.min(58, h * 0.16);
        var safeRight = Math.max(safeLeft + 80, w - 14);
        var safeBottom = Math.max(safeTop + 60, h - 204);

        var padRightCheck = Math.max(safeLeft + 44, w - 76);
        if (incScreen.x >= safeLeft && incScreen.x <= padRightCheck &&
            incScreen.y >= safeTop && incScreen.y <= safeBottom) {
          guideEl.style.display = 'none';
          return;
        }

        bindOffscreenGuideInteractions(guideEl);
        var cx = (safeLeft + safeRight) / 2;
        var cy = (safeTop + safeBottom) / 2;
        var refX = cx;
        var refY = cy;
        var myScreen = state.my ? toScreenFn(state.my.lon, state.my.lat) : null;
        if (myScreen && isFinite(myScreen.x) && isFinite(myScreen.y) &&
            myScreen.x >= safeLeft && myScreen.x <= safeRight &&
            myScreen.y >= safeTop && myScreen.y <= safeBottom) {
          refX = myScreen.x;
          refY = myScreen.y;
        }

        var dx = incScreen.x - refX;
        var dy = incScreen.y - refY;
        if (Math.hypot(dx, dy) < 1) {
          dx = 1;
          dy = 0;
        }

        var halfW = Math.min(68, (safeRight - safeLeft) * 0.4);
        var halfH = Math.min(20, (safeBottom - safeTop) * 0.35);
        var minX = Math.min(refX, safeLeft + halfW);
        var maxX = Math.max(refX, safeRight - halfW);
        var minY = Math.min(refY, safeTop + halfH);
        var maxY = Math.max(refY, safeBottom - halfH);

        var tx = dx > 0 ? (maxX - refX) / dx : (dx < 0 ? (minX - refX) / dx : 1e9);
        var ty = dy > 0 ? (maxY - refY) / dy : (dy < 0 ? (minY - refY) / dy : 1e9);
        var t = Math.min(tx, ty);
        if (!isFinite(t) || t < 0) t = 0;
        var gx = Math.max(minX, Math.min(maxX, refX + dx * t));
        var gy = Math.max(minY, Math.min(maxY, refY + dy * t));

        var btnZoneLeft = w - 76 - halfW;
        if (gx > btnZoneLeft && gy > h - 390) {
          gx = Math.max(minX, btnZoneLeft);
        }

        var deg = Math.atan2(dy, dx) * 180 / Math.PI;

        var refLonLat = state.my
          ? { lon: state.my.lon, lat: state.my.lat }
          : (getCenterLonLatFn ? getCenterLonLatFn() : null);
        var distText = '';
        if (refLonLat && isFinite(refLonLat.lon) && isFinite(refLonLat.lat)) {
          distText = formatDistLabel(
            haversineMeters(refLonLat.lon, refLonLat.lat, state.incident.lon, state.incident.lat)
          );
        }

        var arrowEl = guideEl.querySelector('.wd-offscreen-arrow');
        var labelEl = guideEl.querySelector('.wd-offscreen-label');
        if (arrowEl) {
          arrowEl.style.transform = 'rotate(' + deg.toFixed(1) + 'deg)';
        }
        if (labelEl) {
          labelEl.textContent = distText ? '事发地 · ' + distText : '事发地';
        }
        guideEl.style.left = gx.toFixed(1) + 'px';
        guideEl.style.top = gy.toFixed(1) + 'px';
        guideEl.style.display = 'inline-flex';
      }
''';

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
      ? 16
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
$_sharedOverlayCss
  </style>
</head>
<body>
  <div id="map-container"></div>
  <div id="wd-offscreen-guide" class="wd-offscreen-guide" role="button" aria-label="定位事发地点"></div>
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
    src="https://webapi.amap.com/maps?v=2.0&key=$encodedKey"
    onerror="window.onAmapScriptError()"
  ></script>
  <script>
    (function() {
      if (typeof AMap === 'undefined') {
        notifyBridge('scriptError', { message: '高德地图引擎未就绪，请检查网络后重试' });
        return;
      }

      var containerEl = document.getElementById('map-container');
      var guideEl = document.getElementById('wd-offscreen-guide');

      var state = {
        layerMode: ${_safeJsonEncode(initialLayer.jsValue)},
        my: $myJson,
        incident: $incidentJson,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };

$_sharedPinAndGuideJs

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

      function refreshGuide() {
        updateOffscreenGuide(
          guideEl,
          containerEl,
          state,
          function(lon, lat) {
            var px = map.lngLatToContainer([lon, lat]);
            if (!px) return null;
            return {
              x: typeof px.getX === 'function' ? px.getX() : px.x,
              y: typeof px.getY === 'function' ? px.getY() : px.y
            };
          },
          function() {
            var c = map.getCenter();
            if (!c) return null;
            return {
              lon: typeof c.getLng === 'function' ? c.getLng() : c.lng,
              lat: typeof c.getLat === 'function' ? c.getLat() : c.lat
            };
          }
        );
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
            strokeWeight: 5,
            strokeOpacity: 0.92,
            strokeStyle: 'dashed',
            strokeDasharray: [10, 6],
            isOutline: true,
            outlineColor: '#FFFFFF',
            borderWeight: 1.5,
            showDir: true,
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
        refreshGuide();
      }

      function renderIncident() {
        if (!state.incident) {
          if (incidentMarker) {
            incidentMarker.setMap(null);
            incidentMarker = null;
          }
          syncLinkLine();
          refreshGuide();
          return;
        }
        var pos = [state.incident.lon, state.incident.lat];
        var dom = createIncidentDom(state.incident.title || '事发地点');
        if (!incidentMarker) {
          incidentMarker = new AMap.Marker({
            position: pos,
            content: dom,
            anchor: 'top-left',
            offset: new AMap.Pixel(0, 0),
            zIndex: 110
          });
          incidentMarker.setMap(map);
        } else {
          incidentMarker.setPosition(pos);
          incidentMarker.setContent(dom);
        }
        syncLinkLine();
        refreshGuide();
      }

      applyLayerMode(state.layerMode);
      if (state.my) renderMy(false);
      if (state.incident) renderIncident();
      refreshGuide();

      map.on('dragstart', function() {
        notifyBridge('userDragged', {});
      });
      map.on('mapmove', refreshGuide);
      map.on('zoomchange', refreshGuide);
      map.on('resize', refreshGuide);
      map.on('complete', function() {
        refreshGuide();
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
      ? 16.4
      : 5.0;

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
    #tile-layer { z-index: 1; }
    #overlay-svg { z-index: 10; }
    #marker-layer { z-index: 20; }
    .wd-tile {
      position: absolute;
      image-rendering: auto;
      pointer-events: none;
      border: 0;
    }
    .wd-tile-sat {
      filter: contrast(1.06) saturate(1.05);
    }
$_sharedOverlayCss
  </style>
</head>
<body>
  <div id="map-container">
    <div id="tile-layer"></div>
    <svg id="overlay-svg"></svg>
    <div id="marker-layer"></div>
  </div>
  <div id="wd-offscreen-guide" class="wd-offscreen-guide" role="button" aria-label="定位事发地点"></div>
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
      var guideEl = document.getElementById('wd-offscreen-guide');

      var dpr = Math.min(3.2, Math.max(1, window.devicePixelRatio || 1));
      var retinaOffset = Math.log(dpr) / Math.LN2;
      var maxZoom = dpr >= 2 ? 17.0 : 18.0;

      var state = {
        layerMode: ${_safeJsonEncode(initialLayer.jsValue)},
        centerLon: ${initialLon.toStringAsFixed(6)},
        centerLat: ${initialLat.toStringAsFixed(6)},
        zoom: $initialZoom,
        my: $myJson,
        incident: $incidentJson,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };

$_sharedPinAndGuideJs

      var tileCache = Object.create(null);
      var tileOrder = [];
      var maxCacheSize = 320;
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
          img.className = kind === 'sat' ? 'wd-tile wd-tile-sat' : 'wd-tile';
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
        var tz = Math.max(3, Math.min(18, Math.round(state.zoom + retinaOffset)));
        var factor = Math.pow(2, state.zoom - tz);
        var maxIndex = Math.pow(2, tz);
        var c = lonLatToWorld(state.centerLon, state.centerLat, tz);

        var leftWorld = c.x - (w / 2) / factor;
        var rightWorld = c.x + (w / 2) / factor;
        var topWorld = c.y - (h / 2) / factor;
        var bottomWorld = c.y + (h / 2) / factor;

        var minTx = Math.floor(leftWorld / 256);
        var maxTx = Math.floor(rightWorld / 256);
        var minTy = Math.max(0, Math.floor(topWorld / 256));
        var maxTy = Math.min(maxIndex - 1, Math.floor(bottomWorld / 256));

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
          var dx = incScreen.x - myScreen.x;
          var dy = incScreen.y - myScreen.y;
          var segLen = Math.hypot(dx, dy);
          if (segLen > 12) {
            var trimEnd = segLen > 34 ? 15 : 0;
            var ux = dx / segLen;
            var uy = dy / segLen;
            var drawLen = Math.max(0, Math.min(segLen - trimEnd, 2400));
            var ex = myScreen.x + ux * drawLen;
            var ey = myScreen.y + uy * drawLen;
            svgHtml += '<defs><marker id="wd-dest-arrow" viewBox="0 0 12 12" refX="9" refY="6" markerWidth="6.5" markerHeight="6.5" orient="auto"><path d="M1 1.5 L10.5 6 L1 10.5 L3.2 6 Z" fill="#DC2626" stroke="#FFFFFF" stroke-width="1.2" stroke-linejoin="round"/></marker></defs>';
            svgHtml += '<line x1="' + myScreen.x.toFixed(1) + '" y1="' + myScreen.y.toFixed(1) + '" x2="' + ex.toFixed(1) + '" y2="' + ey.toFixed(1) + '" stroke="#FFFFFF" stroke-width="6" stroke-opacity="0.78" stroke-dasharray="10,7" stroke-linecap="round"/>';
            var markerAttr = drawLen >= segLen - trimEnd - 0.5 ? ' marker-end="url(#wd-dest-arrow)"' : '';
            svgHtml += '<line x1="' + myScreen.x.toFixed(1) + '" y1="' + myScreen.y.toFixed(1) + '" x2="' + ex.toFixed(1) + '" y2="' + ey.toFixed(1) + '" stroke="#DC2626" stroke-width="3.5" stroke-opacity="0.96" stroke-dasharray="10,7" stroke-linecap="round"' + markerAttr + '/>';
            if (segLen > 120) {
              var chevronDist = segLen <= 320 ? segLen * 0.52 : Math.min(segLen * 0.45, 115);
              var midX = myScreen.x + ux * chevronDist;
              var midY = myScreen.y + uy * chevronDist;
              var ang = Math.atan2(dy, dx) * 180 / Math.PI;
              svgHtml += '<g transform="translate(' + midX.toFixed(1) + ' ' + midY.toFixed(1) + ') rotate(' + ang.toFixed(1) + ')"><path d="M-8,-6.5 L9,0 L-8,6.5 L-3.8,0 Z" fill="#DC2626" stroke="#FFFFFF" stroke-width="1.8" stroke-linejoin="round"/></g>';
            }
          }
        }
        overlaySvg.innerHTML = svgHtml;

        markerLayer.innerHTML = '';
        if (incScreen) {
          var incEl = createIncidentDom((state.incident && state.incident.title) || '事发地点');
          incEl.style.left = incScreen.x.toFixed(1) + 'px';
          incEl.style.top = incScreen.y.toFixed(1) + 'px';
          incEl.style.zIndex = '110';
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

        updateOffscreenGuide(
          guideEl,
          container,
          state,
          toScreen,
          function() { return { lon: state.centerLon, lat: state.centerLat }; }
        );
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
            state.zoom = Math.max(3, Math.min(maxZoom, pinchStartZoom + deltaZoom));
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
            state.zoom = Math.min(maxZoom, state.zoom + 0.8);
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
            if (state.zoom < 15) state.zoom = 16.4;
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
          if (state.zoom < 15.8) state.zoom = 16.4;
          scheduleRender();
        },
        focusIncident: function() {
          if (!state.incident) return;
          state.centerLon = state.incident.lon;
          state.centerLat = state.incident.lat;
          if (state.zoom < 15.5) state.zoom = 16.2;
          scheduleRender();
        },
        fitBoth: function() {
          if (state.my && state.incident) {
            var w = Math.max(120, (container.clientWidth || 360) - 120);
            var h = Math.max(120, (container.clientHeight || 640) - 340);
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
            var mid = worldToLonLat((w1.x + w2.x) / 2, (w1.y + w2.y) / 2 + 52, bestZoom);
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

  String _incidentPinTitle() {
    final raw = (_incidentDisplayLocation ?? '').trim();
    if (raw.isEmpty) return '事发地点';
    final shortened = ChinaCoord.shortenPinLabel(raw);
    return shortened.isNotEmpty ? shortened : raw;
  }

  void _pushIncidentToMap() {
    final gcj = _incidentGcj;
    if (!_htmlLoaded || gcj == null) return;
    final title = _safeJsonEncode(_incidentPinTitle());
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
              title: _incidentPinTitle(),
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
    if (type == 'userDragged' || type == 'focusIncidentFromGuide') {
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

  double? get _bearingToIncidentDegrees {
    final me = _myGcj;
    final dest = _incidentGcj;
    if (me == null || dest == null) return null;
    return ChinaCoord.bearingDegrees(me.lat, me.lon, dest.lat, dest.lon);
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
              top: AppSpacing.s2,
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
            alignment: Alignment.centerRight,
            child: AppCard(
              radius: AppRadius.pill,
              padding: const EdgeInsets.all(2.5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final mode in SceneMapLayerMode.values)
                    _layerChip(mode),
                ],
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
    return Tooltip(
      message: mode.label,
      child: Material(
        color: selected ? AppColors.actionPrimary : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: InkWell(
          key: Key('scene-map-layer-${mode.jsValue}'),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: () => _onLayerChanged(mode),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Text(
              mode.shortLabel,
              style: AppTextStyles.caption.copyWith(
                height: 1.15,
                color: selected ? AppColors.onPrimary : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
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
    final bearingDegrees = _bearingToIncidentDegrees;
    final incidentSubtitle = distanceMeters == null
        ? null
        : (bearingDegrees == null
              ? '直线距离 ${ChinaCoord.formatDistance(distanceMeters)}'
              : '${ChinaCoord.cardinalDirection(bearingDegrees)} · 直线距离 ${ChinaCoord.formatDistance(distanceMeters)}');
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
                Expanded(
                  child: InkWell(
                    key: const Key('scene-map-telemetry-incident'),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    onTap: _incidentGcj != null ? _focusIncident : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
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
                                if (incidentSubtitle != null)
                                  Text(
                                    incidentSubtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.caption.copyWith(
                                      color: AppColors.alarmText,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
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
