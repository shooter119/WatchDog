/// 现场地图（高德 JS 2.0 与降级栅格引擎）共享的标点短名与屏外方向指引脚本。
const String sceneMapSharedPinAndGuideJs = r'''
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

/// 内置高德栅格瓦片引擎（无 JS Key 时自动降级：HiDPI 视网膜分级、靶心箭头与屏外指引）。
const String sceneMapRasterEngineJs = r'''
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
            if (oldImg && oldImg.parentNode === tileLayer) tileLayer.removeChild(oldImg);
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
        var minTx = Math.floor((c.x - (w / 2) / factor) / 256);
        var maxTx = Math.floor((c.x + (w / 2) / factor) / 256);
        var minTy = Math.max(0, Math.floor((c.y - (h / 2) / factor) / 256));
        var maxTy = Math.min(maxIndex - 1, Math.floor((c.y + (h / 2) / factor) / 256));
        var kinds = state.layerMode === 'hybrid'
          ? ['sat', 'road']
          : (state.layerMode === 'satellite' ? ['sat'] : ['std']);
        var activeSet = Object.create(null);
        for (var ki = 0; ki < kinds.length; ki++) {
          var kind = kinds[ki];
          for (var tx = minTx; tx <= maxTx; tx++) {
            var wrappedX = ((tx % maxIndex) + maxIndex) % maxIndex;
            var left = Math.round((w / 2) + (tx * 256 - c.x) * factor);
            var widthPx = Math.max(1, Math.round((w / 2) + ((tx + 1) * 256 - c.x) * factor) - left);
            for (var ty = minTy; ty <= maxTy; ty++) {
              var top = Math.round((h / 2) + (ty * 256 - c.y) * factor);
              var heightPx = Math.max(1, Math.round((h / 2) + ((ty + 1) * 256 - c.y) * factor) - top);
              var key = kind + ':' + tz + ':' + wrappedX + ':' + ty;
              activeSet[key] = true;
              var img = acquireTile(kind, wrappedX, ty, tz);
              img.style.left = left + 'px';
              img.style.top = top + 'px';
              img.style.width = widthPx + 'px';
              img.style.height = heightPx + 'px';
              img.style.zIndex = String(ki + 1);
              if (img.parentNode !== tileLayer) tileLayer.appendChild(img);
            }
          }
        }
        var existing = tileLayer.children;
        for (var i = existing.length - 1; i >= 0; i--) {
          var node = existing[i];
          var found = false;
          for (var k in activeSet) {
            if (tileCache[k] === node) { found = true; break; }
          }
          if (!found) tileLayer.removeChild(node);
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
        updateOffscreenGuide(guideEl, container, state, toScreen, function() {
          return { lon: state.centerLon, lat: state.centerLat };
        });
      }
      function renderNow() { renderScheduled = false; renderTiles(); renderOverlays(); }
      function scheduleRender() { if (renderScheduled) return; renderScheduled = true; requestAnimationFrame(renderNow); }
      function panByPixels(dx, dy) {
        var c = lonLatToWorld(state.centerLon, state.centerLat, state.zoom);
        var next = worldToLonLat(c.x - dx, c.y - dy, state.zoom);
        state.centerLon = next.lon; state.centerLat = next.lat;
      }
      var touchMode = 'none', lastTouchX = 0, lastTouchY = 0, totalPanPx = 0, draggedNotified = false;
      var pinchStartDist = 0, pinchStartZoom = state.zoom, lastPinchMidX = 0, lastPinchMidY = 0;
      var lastTapAt = 0, lastTapX = 0, lastTapY = 0;
      function touchDist(t1, t2) { var dx = t2.clientX - t1.clientX, dy = t2.clientY - t1.clientY; return Math.sqrt(dx * dx + dy * dy); }
      container.addEventListener('touchstart', function(e) {
        if (e.touches.length === 1) {
          touchMode = 'pan'; lastTouchX = e.touches[0].clientX; lastTouchY = e.touches[0].clientY;
          totalPanPx = 0; draggedNotified = false;
        } else if (e.touches.length >= 2) {
          touchMode = 'pinch'; pinchStartDist = Math.max(10, touchDist(e.touches[0], e.touches[1]));
          pinchStartZoom = state.zoom;
          lastPinchMidX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
          lastPinchMidY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
          if (!draggedNotified) { draggedNotified = true; notifyBridge('userDragged', {}); }
        }
      }, { passive: true });
      container.addEventListener('touchmove', function(e) {
        if (touchMode === 'pan' && e.touches.length === 1) {
          var t = e.touches[0], dx = t.clientX - lastTouchX, dy = t.clientY - lastTouchY;
          lastTouchX = t.clientX; lastTouchY = t.clientY; totalPanPx += Math.abs(dx) + Math.abs(dy);
          if (!draggedNotified && totalPanPx > 6) { draggedNotified = true; notifyBridge('userDragged', {}); }
          panByPixels(dx, dy); scheduleRender();
        } else if (e.touches.length >= 2) {
          var midX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
          var midY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
          var dist = Math.max(10, touchDist(e.touches[0], e.touches[1]));
          if (touchMode !== 'pinch') { touchMode = 'pinch'; pinchStartDist = dist; pinchStartZoom = state.zoom; }
          else {
            panByPixels(midX - lastPinchMidX, midY - lastPinchMidY);
            state.zoom = Math.max(3, Math.min(maxZoom, pinchStartZoom + Math.log(dist / pinchStartDist) / Math.LN2));
          }
          lastPinchMidX = midX; lastPinchMidY = midY; scheduleRender();
        }
      }, { passive: true });
      container.addEventListener('touchend', function(e) {
        if (touchMode === 'pan' && e.touches.length === 0 && totalPanPx < 10) {
          var nowMs = Date.now();
          if (nowMs - lastTapAt < 280 && Math.abs(lastTouchX - lastTapX) < 32 && Math.abs(lastTouchY - lastTapY) < 32) {
            state.zoom = Math.min(maxZoom, state.zoom + 0.8); scheduleRender(); lastTapAt = 0;
          } else { lastTapAt = nowMs; lastTapX = lastTouchX; lastTapY = lastTouchY; }
        }
        if (e.touches.length === 1) { touchMode = 'pan'; lastTouchX = e.touches[0].clientX; lastTouchY = e.touches[0].clientY; }
        else if (e.touches.length === 0) { touchMode = 'none'; }
      }, { passive: true });
      if (typeof ResizeObserver !== 'undefined') new ResizeObserver(scheduleRender).observe(container);
      else window.addEventListener('resize', scheduleRender);
      window.watchdogMap = {
        setLayerMode: function(mode) { state.layerMode = mode || 'hybrid'; scheduleRender(); },
        setTrafficEnabled: function(enabled) { state.trafficEnabled = Boolean(enabled); scheduleRender(); },
        updateMyLocation: function(lon, lat, accuracy, bearing, shouldCenter) {
          state.my = { lon: lon, lat: lat, accuracy: accuracy || 0, bearing: bearing };
          if (shouldCenter || !state.hasCenteredMy) {
            state.hasCenteredMy = true; state.centerLon = lon; state.centerLat = lat;
            if (state.zoom < 15) state.zoom = 16.4;
          }
          scheduleRender();
        },
        updateIncident: function(lon, lat, title) {
          state.incident = { lon: lon, lat: lat, title: title || '事发地点' }; scheduleRender();
        },
        focusMyLocation: function() {
          if (!state.my) return;
          state.centerLon = state.my.lon; state.centerLat = state.my.lat;
          if (state.zoom < 15.8) state.zoom = 16.4;
          scheduleRender();
        },
        focusIncident: function() {
          if (!state.incident) return;
          state.centerLon = state.incident.lon; state.centerLat = state.incident.lat;
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
              if (Math.abs(p1.x - p2.x) <= w && Math.abs(p1.y - p2.y) <= h) { bestZoom = z; break; }
            }
            var w1 = lonLatToWorld(state.my.lon, state.my.lat, bestZoom);
            var w2 = lonLatToWorld(state.incident.lon, state.incident.lat, bestZoom);
            var mid = worldToLonLat((w1.x + w2.x) / 2, (w1.y + w2.y) / 2 + 52, bestZoom);
            state.zoom = bestZoom; state.centerLon = mid.lon; state.centerLat = mid.lat; scheduleRender();
          } else if (state.my) { window.watchdogMap.focusMyLocation(); }
          else if (state.incident) { window.watchdogMap.focusIncident(); }
        }
      };
      renderNow();
      notifyBridge('mapReady', { engine: 'raster' });
''';
