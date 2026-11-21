import 'dart:convert';

import '../data/models/water_source.dart';

/// 防止 JSON 中的 `</script>` 提前闭合 HTML `<script>` 标签。
String waterSourcesSafeJsonEncode(Object? value) =>
    jsonEncode(value).replaceAll('</', '<\\/');

/// 将 [WaterSource] 转为地图 JS 桥接精简载荷。
Map<String, dynamic> waterSourceToJsPayload(WaterSource item) => {
  'id': item.id,
  'category': item.category.apiValue,
  'name': item.name,
  'lat': item.lat,
  'lng': item.lng,
  'status': item.status.apiValue,
  'hasNote': item.hasNote,
};

/// 构建「周边水源」高德 JS API 2.0 地图 HTML。
///
/// - 固定加载卫星+路网底图；
/// - 使用 `AMap.LabelsLayer` + `AMap.LabelMarker` 渲染 3 类图标 + 2 态配色 + 备注角标，图标右侧默认展示点位名称；
/// - 监听代理 401 响应通知端侧自动续签票据并重建底图；
/// - 不调用高德逆地理，不提供外部导航唤起。
String buildWaterSourcesMapHtml({
  required String jsKey,
  String? serviceHost,
  ({double lat, double lng, double accuracy})? initialMyGcj,
  ({double lat, double lng})? initialCenter,
  double? initialZoom,
  List<WaterSource> initialItems = const [],
  String? selectedId,
}) {
  final trimmedKey = jsKey.trim();
  final encodedKey = Uri.encodeQueryComponent(trimmedKey);
  final trimmedHost = serviceHost?.trim() ?? '';
  final securityBlock = trimmedHost.isNotEmpty
      ? '''
<script>
window._AMapSecurityConfig = {
  serviceHost: ${waterSourcesSafeJsonEncode(trimmedHost)}
};
</script>'''
      : '';

  final centerLng =
      initialCenter?.lng ??
      initialMyGcj?.lng ??
      (initialItems.isNotEmpty ? initialItems.first.lng : 116.397428);
  final centerLat =
      initialCenter?.lat ??
      initialMyGcj?.lat ??
      (initialItems.isNotEmpty ? initialItems.first.lat : 39.90923);
  final zoom =
      initialZoom ??
      ((initialCenter != null ||
              initialMyGcj != null ||
              initialItems.isNotEmpty)
          ? 16.0
          : 5.0);

  final myJson = initialMyGcj == null
      ? 'null'
      : waterSourcesSafeJsonEncode({
          'lat': initialMyGcj.lat,
          'lng': initialMyGcj.lng,
          'accuracy': initialMyGcj.accuracy,
        });

  final itemsJson = waterSourcesSafeJsonEncode(
    initialItems.map(waterSourceToJsPayload).toList(growable: false),
  );

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
    .wd-my-dot {
      width: 16px;
      height: 16px;
      border-radius: 50%;
      background: #2563EB;
      border: 3px solid #FFFFFF;
      box-shadow: 0 1px 6px rgba(0, 0, 0, 0.45);
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

    (function installTicketWatcher() {
      var proxyHost = ${waterSourcesSafeJsonEncode(trimmedHost)};
      if (!proxyHost) return;
      var notified = false;
      function triggerExpired(url) {
        if (notified) return;
        if (typeof url === 'string' && url.indexOf(proxyHost) !== -1) {
          notified = true;
          notifyBridge('ticketExpired', { status: 401 });
        }
      }
      if (typeof window.fetch === 'function') {
        var origFetch = window.fetch;
        window.fetch = function(input, init) {
          var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
          return origFetch.apply(this, arguments).then(function(resp) {
            if (resp && resp.status === 401) triggerExpired(url);
            return resp;
          });
        };
      }
      if (typeof XMLHttpRequest !== 'undefined') {
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
          this._wdUrl = typeof url === 'string' ? url : '';
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
          var xhr = this;
          xhr.addEventListener('load', function() {
            if (xhr.status === 401) triggerExpired(xhr._wdUrl || '');
          });
          return origSend.apply(this, arguments);
        };
      }
    })();

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

      var state = {
        my: $myJson,
        items: $itemsJson,
        selectedId: ${waterSourcesSafeJsonEncode(selectedId)},
        pickingMode: false,
        hasCenteredMy: ${initialMyGcj != null ? 'true' : 'false'}
      };

      var map = new AMap.Map('map-container', {
        zoom: ${zoom.toStringAsFixed(1)},
        center: [${centerLng.toStringAsFixed(6)}, ${centerLat.toStringAsFixed(6)}],
        viewMode: '2D',
        rotateEnable: false,
        pitchEnable: false,
        resizeEnable: true
      });

      var satelliteLayer = new AMap.TileLayer.Satellite({ zIndex: 1 });
      var roadNetLayer = new AMap.TileLayer.RoadNet({ zIndex: 2 });
      map.setLayers([satelliteLayer, roadNetLayer]);

      var labelsLayer = new AMap.LabelsLayer({
        zooms: [3, 20],
        zIndex: 120,
        collision: true,
        allowCollision: false
      });
      map.add(labelsLayer);

      var iconCache = {};
      function buildMarkerIcon(category, available, hasNote, selected) {
        var key = category + ':' + (available ? '1' : '0') + ':' + (hasNote ? '1' : '0') + ':' + (selected ? '1' : '0');
        if (iconCache[key]) return iconCache[key];

        var fill = '#2563EB';
        var stroke = '#FFFFFF';
        if (!available) {
          fill = '#6B7280';
          stroke = '#DC2626';
        } else if (category === 'natural') {
          fill = '#0D9488';
        } else if (category === 'pump_connector') {
          fill = '#D97706';
        }

        var glyph = '';
        if (category === 'natural') {
          glyph = '<path d="M18 9 C18 9 12 16 12 20.5 C12 23.8 14.7 26.5 18 26.5 C21.3 26.5 24 23.8 24 20.5 C24 16 18 9 18 9 Z" fill="#FFFFFF"/>';
        } else if (category === 'pump_connector') {
          glyph = '<path d="M11 16 H25 V20 H11 Z M15 11 H21 V25 H15 Z" fill="#FFFFFF"/>';
        } else {
          glyph = '<rect x="14.5" y="11" width="7" height="14" rx="2" fill="#FFFFFF"/><rect x="11.5" y="15" width="13" height="3.2" rx="1" fill="#FFFFFF"/><circle cx="18" cy="10" r="2.2" fill="#FFFFFF"/>';
        }

        var slash = available ? '' : '<line x1="9" y1="9" x2="27" y2="27" stroke="#DC2626" stroke-width="3" stroke-linecap="round"/>';
        var ring = selected ? '<circle cx="18" cy="18" r="16.5" fill="none" stroke="#FACC15" stroke-width="3"/>' : '';
        var noteBadge = hasNote ? '<circle cx="29" cy="7" r="4.5" fill="#F59E0B" stroke="#FFFFFF" stroke-width="1.6"/>' : '';

        var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36">' +
          ring +
          '<circle cx="18" cy="18" r="13.5" fill="' + fill + '" stroke="' + stroke + '" stroke-width="2.4"/>' +
          glyph +
          slash +
          noteBadge +
          '</svg>';
        var uri = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
        iconCache[key] = uri;
        return uri;
      }

      function shortLabel(name) {
        var s = String(name || '').trim();
        if (s.length <= 12) return s;
        return s.slice(0, 11) + '…';
      }

      function renderItems() {
        labelsLayer.clear();
        var markers = [];
        for (var i = 0; i < state.items.length; i++) {
          var item = state.items[i];
          if (typeof item.lng !== 'number' || typeof item.lat !== 'number') continue;
          var isSel = state.selectedId && item.id === state.selectedId;
          var available = item.status !== 'unavailable';
          var size = isSel ? [36, 36] : [30, 30];
          var marker = new AMap.LabelMarker({
            name: item.id,
            position: [item.lng, item.lat],
            zIndex: isSel ? 200 : (available ? 120 : 100),
            rank: isSel ? 10 : (available ? 5 : 1),
            icon: {
              type: 'image',
              image: buildMarkerIcon(item.category, available, !!item.hasNote, isSel),
              size: size,
              anchor: 'center'
            },
            text: {
              content: shortLabel(item.name),
              direction: 'right',
              offset: [4, 0],
              style: {
                fontSize: isSel ? 13 : 12,
                fontWeight: 'bold',
                fillColor: available ? '#FFFFFF' : '#FCA5A5',
                strokeColor: '#0F172A',
                strokeWidth: 3.5
              }
            }
          });
          (function(id) {
            marker.on('click', function() {
              notifyBridge('markerClick', { id: id });
            });
          })(item.id);
          markers.push(marker);
        }
        if (markers.length > 0) {
          labelsLayer.add(markers);
        }
      }

      var myMarker = null;
      var accuracyCircle = null;
      function renderMyLocation() {
        if (!state.my) return;
        var pos = [state.my.lng, state.my.lat];
        if (!myMarker) {
          var el = document.createElement('div');
          el.className = 'wd-my-dot';
          myMarker = new AMap.Marker({
            position: pos,
            content: el,
            offset: new AMap.Pixel(-11, -11),
            zIndex: 250
          });
          map.add(myMarker);
        } else {
          myMarker.setPosition(pos);
        }
        var acc = typeof state.my.accuracy === 'number' && state.my.accuracy > 0 ? state.my.accuracy : 0;
        if (acc > 0) {
          if (!accuracyCircle) {
            accuracyCircle = new AMap.Circle({
              center: pos,
              radius: Math.min(acc, 500),
              fillColor: '#2563EB',
              fillOpacity: 0.14,
              strokeColor: '#3B82F6',
              strokeOpacity: 0.45,
              strokeWeight: 1.5,
              zIndex: 90
            });
            map.add(accuracyCircle);
          } else {
            accuracyCircle.setCenter(pos);
            accuracyCircle.setRadius(Math.min(acc, 500));
          }
        }
      }

      function emitCenter() {
        var c = map.getCenter();
        if (!c) return;
        notifyBridge('centerChanged', { lat: c.getLat(), lng: c.getLng(), zoom: map.getZoom() });
      }

      map.on('moveend', function() { emitCenter(); });
      map.on('mapmove', function() { if (state.pickingMode) emitCenter(); });

      renderMyLocation();
      renderItems();

      window.watchdogWaterMap = {
        setItems: function(items, selectedId) {
          state.items = Array.isArray(items) ? items : [];
          state.selectedId = selectedId || null;
          renderItems();
        },
        setMyLocation: function(my, autoCenter) {
          state.my = my || null;
          renderMyLocation();
          if (autoCenter && state.my && !state.hasCenteredMy) {
            state.hasCenteredMy = true;
            map.setZoomAndCenter(16, [state.my.lng, state.my.lat]);
          }
        },
        focusItem: function(id, lng, lat) {
          state.selectedId = id || null;
          renderItems();
          if (typeof lng === 'number' && typeof lat === 'number') {
            map.setZoomAndCenter(Math.max(map.getZoom() || 16, 17), [lng, lat]);
          }
        },
        centerOn: function(lng, lat, zoom) {
          if (typeof lng === 'number' && typeof lat === 'number') {
            map.setZoomAndCenter(zoom || 17, [lng, lat]);
          }
        },
        setPickingMode: function(enabled) {
          state.pickingMode = !!enabled;
          if (state.pickingMode) emitCenter();
        }
      };

      notifyBridge('mapReady', {});
    })();
  </script>
</body>
</html>''';
}
