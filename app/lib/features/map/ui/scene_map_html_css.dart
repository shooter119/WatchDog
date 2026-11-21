/// 现场地图（高德 JS 2.0 与降级栅格引擎）共享的 WebView CSS 样式片段。
const String sceneMapSharedOverlayCss = '''
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

/// 降级栅格瓦片引擎专用基础样式。
const String sceneMapRasterBaseCss = '''
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
''';
