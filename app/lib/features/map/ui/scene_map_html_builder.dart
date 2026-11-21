import 'dart:convert';

import 'scene_map_html_css.dart';
import 'scene_map_html_js.dart';

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

/// 防止 JSON 中的 `</script>` 提前闭合 HTML `<script>` 标签。
String sceneMapSafeJsonEncode(Object? value) =>
    jsonEncode(value).replaceAll('</', '<\\/');

/// 生成现场卫星地图 HTML（当服务端配置 `jsKey` 时走高德 JS API 2.0；未配置 Key 时自动降级内置高德瓦片引擎）。
String buildSceneMapHtml({
  required String jsKey,
  String? serviceHost,
  SceneMapLayerMode initialLayer = SceneMapLayerMode.hybrid,
  bool initialTrafficEnabled = false,
  ({double lat, double lon, double accuracy, double? bearing})? initialMyGcj,
  ({double lat, double lon, String title})? initialIncidentGcj,
}) {
  final trimmedKey = jsKey.trim();
  if (trimmedKey.isEmpty) {
    return _buildRasterFallbackMapHtml(
      initialLayer: initialLayer,
      initialTrafficEnabled: initialTrafficEnabled,
      initialMyGcj: initialMyGcj,
      initialIncidentGcj: initialIncidentGcj,
    );
  }
  final encodedKey = Uri.encodeQueryComponent(trimmedKey);
  final securityBlock = (serviceHost != null && serviceHost.trim().isNotEmpty)
      ? '''
<script>
window._AMapSecurityConfig = {
  serviceHost: ${sceneMapSafeJsonEncode(serviceHost.trim())}
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
      : sceneMapSafeJsonEncode({
          'lon': initialMyGcj.lon,
          'lat': initialMyGcj.lat,
          'accuracy': initialMyGcj.accuracy,
          'bearing': initialMyGcj.bearing,
        });
  final incidentJson = initialIncidentGcj == null
      ? 'null'
      : sceneMapSafeJsonEncode({
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
$sceneMapSharedOverlayCss
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
        layerMode: ${sceneMapSafeJsonEncode(initialLayer.jsValue)},
        trafficEnabled: ${initialTrafficEnabled ? 'true' : 'false'},
        my: $myJson,
        incident: $incidentJson,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };
$sceneMapSharedPinAndGuideJs
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
      var trafficLayer = new AMap.TileLayer.Traffic({ zIndex: 3, autoRefresh: true, interval: 180 });
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
      function applyTraffic(enabled) {
        state.trafficEnabled = Boolean(enabled);
        trafficLayer.setMap(state.trafficEnabled ? map : null);
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
          if (linkLine) { linkLine.setMap(null); linkLine = null; }
          return;
        }
        var path = [[state.my.lon, state.my.lat], [state.incident.lon, state.incident.lat]];
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
        var radius = typeof state.my.accuracy === 'number' && state.my.accuracy > 0 ? state.my.accuracy : 0;
        if (!myCircle) {
          myCircle = new AMap.Circle({
            center: pos, radius: radius,
            strokeColor: '#2563EB', strokeOpacity: 0.45, strokeWeight: 1,
            fillColor: '#2563EB', fillOpacity: 0.14, zIndex: 40
          });
          myCircle.setMap(map);
        } else { myCircle.setCenter(pos); myCircle.setRadius(radius); }
        if (!myMarker) {
          myMarker = new AMap.Marker({
            position: pos, content: createMyDom(state.my.bearing),
            offset: new AMap.Pixel(-15, -15), zIndex: 120
          });
          myMarker.setMap(map);
        } else { myMarker.setPosition(pos); myMarker.setContent(createMyDom(state.my.bearing)); }
        if (shouldCenter || !state.hasCenteredMy) {
          state.hasCenteredMy = true;
          if (map.getZoom() < 15) map.setZoomAndCenter(17, pos, false);
          else map.setCenter(pos, false);
        }
        syncLinkLine();
        refreshGuide();
      }
      function renderIncident() {
        if (!state.incident) {
          if (incidentMarker) { incidentMarker.setMap(null); incidentMarker = null; }
          syncLinkLine(); refreshGuide(); return;
        }
        var pos = [state.incident.lon, state.incident.lat];
        var dom = createIncidentDom(state.incident.title || '事发地点');
        if (!incidentMarker) {
          incidentMarker = new AMap.Marker({
            position: pos, content: dom, anchor: 'top-left',
            offset: new AMap.Pixel(0, 0), zIndex: 110
          });
          incidentMarker.setMap(map);
        } else { incidentMarker.setPosition(pos); incidentMarker.setContent(dom); }
        syncLinkLine();
        refreshGuide();
      }

      applyLayerMode(state.layerMode);
      applyTraffic(state.trafficEnabled);
      if (state.my) renderMy(false);
      if (state.incident) renderIncident();
      refreshGuide();

      map.on('dragstart', function() { notifyBridge('userDragged', {}); });
      map.on('mapmove', refreshGuide);
      map.on('zoomchange', refreshGuide);
      map.on('resize', refreshGuide);
      map.on('complete', function() { refreshGuide(); notifyBridge('mapReady', {}); });

      window.watchdogMap = {
        setLayerMode: function(mode) { applyLayerMode(mode); },
        setTrafficEnabled: function(enabled) { applyTraffic(enabled); },
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
          if (map.getZoom() < 16) map.setZoomAndCenter(17, pos, false);
          else map.setCenter(pos, false);
        },
        focusIncident: function() {
          if (!state.incident) return;
          var pos = [state.incident.lon, state.incident.lat];
          if (map.getZoom() < 15) map.setZoomAndCenter(16, pos, false);
          else map.setCenter(pos, false);
        },
        fitBoth: function() {
          var targets = [];
          if (myMarker) targets.push(myMarker);
          if (incidentMarker) targets.push(incidentMarker);
          if (targets.length >= 2) map.setFitView(targets, false, [140, 180, 60, 60], 17);
          else if (state.my) window.watchdogMap.focusMyLocation();
          else if (state.incident) window.watchdogMap.focusIncident();
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
  required bool initialTrafficEnabled,
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
      : sceneMapSafeJsonEncode({
          'lon': initialMyGcj.lon,
          'lat': initialMyGcj.lat,
          'accuracy': initialMyGcj.accuracy,
          'bearing': initialMyGcj.bearing,
        });
  final incidentJson = initialIncidentGcj == null
      ? 'null'
      : sceneMapSafeJsonEncode({
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
$sceneMapRasterBaseCss
$sceneMapSharedOverlayCss
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
        layerMode: ${sceneMapSafeJsonEncode(initialLayer.jsValue)},
        trafficEnabled: ${initialTrafficEnabled ? 'true' : 'false'},
        centerLon: ${initialLon.toStringAsFixed(6)},
        centerLat: ${initialLat.toStringAsFixed(6)},
        zoom: $initialZoom,
        my: $myJson,
        incident: $incidentJson,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };
$sceneMapSharedPinAndGuideJs
$sceneMapRasterEngineJs
    })();
  </script>
</body>
</html>
''';
}
