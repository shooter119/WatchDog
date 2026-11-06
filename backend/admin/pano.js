'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const DEFAULT_VIEW = {
    hfov: 105,
    minHfov: 35,
    maxHfov: 120,
    pitch: -5,
    yaw: 20,
    autoRotate: -1.6,
    northOffset: 0,
  };

  let viewer = null;
  let rightViewer = null;
  let vrSyncTimer = null;
  let vrEnabled = false;
  let autoRotating = true;
  let currentBlobUrl = null;
  let scenes = [];
  let currentIndex = 0;

  const params = new URLSearchParams(window.location.search);
  const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ''));
  const siteId = params.get('siteId') || '';
  const initialAttachmentId = params.get('attachmentId') || '';
  const version = params.get('version') || '';
  const incidentId = params.get('incidentId') || '';
  const mode = params.get('mode') || (version ? 'app' : 'admin');
  const appToken = hashParams.get('token') || sessionStorage.getItem('watchdog_pano_token') || '';
  if (hashParams.get('token')) {
    sessionStorage.setItem('watchdog_pano_token', hashParams.get('token'));
    history.replaceState(null, '', window.location.pathname + window.location.search);
  }

  function authHeaders() {
    return mode === 'app' && appToken ? { Authorization: `Bearer ${appToken}` } : {};
  }

  function setLoading(visible, text = '正在加载全景图…', progress = null, canRetry = false) {
    const overlay = $('loading');
    overlay.hidden = !visible;
    if (!visible) return;
    $('loading-text').textContent = text;
    $('loading-spinner').hidden = canRetry;
    $('progress-track').hidden = progress === null;
    if (progress !== null) $('progress-bar').style.width = `${Math.max(5, Math.min(100, progress))}%`;
    $('btn-retry').hidden = !canRetry;
  }

  function cleanupViewers() {
    if (vrSyncTimer) {
      clearInterval(vrSyncTimer);
      vrSyncTimer = null;
    }
    if (rightViewer) {
      try { rightViewer.destroy(); } catch (_) {}
      rightViewer = null;
    }
    if (viewer) {
      try { viewer.destroy(); } catch (_) {}
      viewer = null;
    }
    $('viewer').replaceChildren();
    $('viewer-right').replaceChildren();
    if (currentBlobUrl) {
      URL.revokeObjectURL(currentBlobUrl);
      currentBlobUrl = null;
    }
  }

  function syncRotateButton(active) {
    autoRotating = Boolean(active);
    const btn = $('btn-rotate');
    btn.classList.toggle('active', autoRotating);
    btn.setAttribute('aria-pressed', String(autoRotating));
  }

  function createPannellum(containerId, blobUrl, config, options = {}) {
    return window.pannellum.viewer(containerId, {
      type: 'equirectangular',
      panorama: blobUrl,
      autoLoad: true,
      hfov: config.hfov ?? DEFAULT_VIEW.hfov,
      minHfov: config.minHfov ?? DEFAULT_VIEW.minHfov,
      maxHfov: config.maxHfov ?? DEFAULT_VIEW.maxHfov,
      pitch: config.pitch ?? DEFAULT_VIEW.pitch,
      yaw: config.yaw ?? DEFAULT_VIEW.yaw,
      autoRotate: options.autoRotate ? (config.autoRotate ?? DEFAULT_VIEW.autoRotate) : 0,
      northOffset: config.northOffset ?? DEFAULT_VIEW.northOffset,
      compass: options.compass !== false,
      showControls: false,
    });
  }

  function applyVRMode(enable) {
    vrEnabled = Boolean(enable);
    const stage = $('stage');
    const rightEl = $('viewer-right');
    const btn = $('btn-vr');
    stage.classList.toggle('vr-mode', vrEnabled);
    rightEl.hidden = !vrEnabled;
    btn.classList.toggle('active', vrEnabled);
    btn.setAttribute('aria-pressed', String(vrEnabled));
    if (vrSyncTimer) {
      clearInterval(vrSyncTimer);
      vrSyncTimer = null;
    }
    if (rightViewer) {
      try { rightViewer.destroy(); } catch (_) {}
      rightViewer = null;
      rightEl.replaceChildren();
    }
    if (!viewer) return;
    try { viewer.resize(); } catch (_) {}
    if (vrEnabled && currentBlobUrl) {
      const scene = scenes[currentIndex] || {};
      const stereoOffset = 3.2;
      rightViewer = createPannellum('viewer-right', currentBlobUrl, {
        ...(scene.config || {}),
        pitch: viewer.getPitch(),
        yaw: viewer.getYaw() + stereoOffset,
        hfov: viewer.getHfov(),
      }, { autoRotate: false, compass: false });
      vrSyncTimer = setInterval(() => {
        if (!viewer || !rightViewer) return;
        try {
          rightViewer.lookAt(viewer.getPitch(), viewer.getYaw() + stereoOffset, viewer.getHfov(), false);
        } catch (_) {}
      }, 33);
    }
  }

  async function fetchImageBlob(url) {
    const response = await fetch(url, {
      method: 'GET',
      credentials: mode === 'admin' ? 'same-origin' : 'omit',
      headers: authHeaders(),
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error('鉴权已失效或无权限查看该全景图，请重新登录后重试');
    }
    if (!response.ok) {
      throw new Error(`全景图加载失败（HTTP ${response.status}）`);
    }
    const contentLength = Number(response.headers.get('content-length')) || 0;
    if (!response.body || !contentLength) {
      setLoading(true, '正在接收全景图像数据…', 65, false);
      return response.blob();
    }
    const reader = response.body.getReader();
    const chunks = [];
    let received = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.byteLength;
      setLoading(true, `正在加载全景图 (${Math.round((received / contentLength) * 100)}%)…`, Math.round((received / contentLength) * 90), false);
    }
    return new Blob(chunks, { type: response.headers.get('content-type') || 'image/jpeg' });
  }

  function renderSceneBar() {
    const bar = $('scene-bar');
    bar.replaceChildren();
    if (scenes.length <= 1) {
      bar.hidden = true;
      return;
    }
    bar.hidden = false;
    scenes.forEach((scene, index) => {
      const pill = document.createElement('button');
      pill.type = 'button';
      pill.className = `scene-pill${index === currentIndex ? ' active' : ''}`;
      pill.textContent = `${index + 1}. ${scene.label}`;
      pill.onclick = () => {
        if (index !== currentIndex) loadScene(index);
      };
      bar.append(pill);
    });
  }

  async function loadScene(index) {
    if (!scenes.length || index < 0 || index >= scenes.length) return;
    currentIndex = index;
    const scene = scenes[currentIndex];
    renderSceneBar();
    $('pano-title').textContent = scene.siteName || '重点单位全景';
    const countNote = scenes.length > 1 ? ` · 机位 ${currentIndex + 1}/${scenes.length}` : '';
    $('pano-subtitle').textContent = `${scene.label}${scene.subtitle ? ` · ${scene.subtitle}` : ''}${countNote}`;

    cleanupViewers();
    setLoading(true, `正在加载「${scene.label}」…`, 15, false);
    try {
      const blob = await fetchImageBlob(scene.imageUrl);
      currentBlobUrl = URL.createObjectURL(blob);
      setLoading(true, '正在初始化 3D 球面纹理…', 95, false);
      viewer = createPannellum('viewer', currentBlobUrl, scene.config || {}, { autoRotate: autoRotating, compass: true });
      window.viewer = viewer;
      viewer.on('load', () => {
        setLoading(false);
        if (vrEnabled) applyVRMode(true);
      });
      viewer.on('error', err => {
        setLoading(true, `全景渲染失败：${String(err || '未知错误')}`, null, true);
      });
      viewer.on('mousedown', () => syncRotateButton(false));
      viewer.on('touchstart', () => syncRotateButton(false));
    } catch (error) {
      setLoading(true, error.message || '全景图加载失败', null, true);
    }
  }

  function buildScenesFromSite(siteName, contentMaps, attachments, urlBuilder) {
    const readyPanos = new Map(
      (attachments || [])
        .filter(att => att.metadata?.panorama && (att.status === 'ready' || att.status === undefined))
        .map(att => [att.id, att]),
    );
    const list = [];
    const seen = new Set();

    for (const entry of contentMaps || []) {
      const areaNote = [entry.fields?.area, entry.fields?.capturedAt].filter(Boolean).join(' · ');
      for (const source of entry.sources || []) {
        const att = readyPanos.get(source.attachmentId);
        if (!att || seen.has(att.id)) continue;
        seen.add(att.id);
        const label = (source.paragraph && source.paragraph.trim())
          || (entry.sources.length > 1 ? `${entry.title} (${list.length + 1})` : entry.title)
          || att.filename.replace(/\.[^.]+$/, '');
        list.push({
          attachmentId: att.id,
          siteName,
          label,
          subtitle: areaNote || att.filename,
          imageUrl: urlBuilder(att.id),
          config: typeof att.metadata.panorama === 'object' ? att.metadata.panorama : {},
        });
      }
    }

    for (const att of readyPanos.values()) {
      if (seen.has(att.id)) continue;
      seen.add(att.id);
      list.push({
        attachmentId: att.id,
        siteName,
        label: att.filename.replace(/\.[^.]+$/, '') || `全景机位 ${list.length + 1}`,
        subtitle: '未关联分项的草稿全景图',
        imageUrl: urlBuilder(att.id),
        config: typeof att.metadata.panorama === 'object' ? att.metadata.panorama : {},
      });
    }
    return list;
  }

  async function bootstrap() {
    if (!siteId) {
      setLoading(true, '缺少重点单位参数（siteId），请从重点单位资料页面进入', null, false);
      return;
    }
    setLoading(true, '正在核验身份并读取重点单位全景配置…', 10, false);
    try {
      if (mode === 'app') {
        const verPath = version ? `/versions/${encodeURIComponent(version)}` : '';
        const query = incidentId ? `?incidentId=${encodeURIComponent(incidentId)}` : '';
        const response = await fetch(`/api/key-sites/${encodeURIComponent(siteId)}${verPath}${query}`, {
          headers: authHeaders(),
        });
        if (response.status === 401 || response.status === 403) {
          throw new Error('请先完成单位有效成员认证后再查阅全景资料');
        }
        if (!response.ok) throw new Error('重点单位暂无已发布的全景资料');
        const data = await response.json();
        const ver = data.version;
        scenes = buildScenesFromSite(
          data.profile?.name || '重点单位',
          data.content?.maps || [],
          data.attachments || [],
          attId => `/api/key-sites/${encodeURIComponent(siteId)}/versions/${encodeURIComponent(ver)}/attachments/${encodeURIComponent(attId)}/panorama.jpg${query}`,
        );
      } else {
        const response = await fetch(`/api/admin/key-sites/${encodeURIComponent(siteId)}`, {
          credentials: 'same-origin',
        });
        if (response.status === 401 || response.status === 403) {
          throw new Error('后台会话已失效或无权访问，请先返回 /admin 扫码登录');
        }
        if (!response.ok) throw new Error('无法读取重点单位全景列表');
        const data = await response.json();
        scenes = buildScenesFromSite(
          data.site?.name || '重点单位',
          data.draft?.content?.maps || [],
          data.attachments || [],
          attId => `/api/admin/key-sites/${encodeURIComponent(siteId)}/attachments/${encodeURIComponent(attId)}/panorama.jpg`,
        );
      }

      if (!scenes.length) {
        setLoading(true, '该重点单位暂无已就绪的 360° 全景图', null, false);
        return;
      }
      const targetIdx = initialAttachmentId
        ? Math.max(0, scenes.findIndex(s => s.attachmentId === initialAttachmentId))
        : 0;
      await loadScene(targetIdx);
    } catch (error) {
      setLoading(true, error.message || '加载失败，请重试', null, true);
    }
  }

  $('btn-rotate').onclick = () => {
    if (!viewer) return;
    if (autoRotating) {
      viewer.stopAutoRotate();
      syncRotateButton(false);
    } else {
      const scene = scenes[currentIndex] || {};
      viewer.startAutoRotate(scene.config?.autoRotate ?? DEFAULT_VIEW.autoRotate);
      syncRotateButton(true);
    }
  };

  $('btn-reset').onclick = () => {
    if (!viewer) return;
    const scene = scenes[currentIndex] || {};
    const cfg = scene.config || {};
    viewer.lookAt(cfg.pitch ?? DEFAULT_VIEW.pitch, cfg.yaw ?? DEFAULT_VIEW.yaw, cfg.hfov ?? DEFAULT_VIEW.hfov, 600);
  };

  $('btn-vr').onclick = () => applyVRMode(!vrEnabled);

  $('btn-fullscreen').onclick = () => {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen?.().catch(() => {
        viewer?.toggleFullscreen?.();
      });
    } else {
      document.exitFullscreen?.().catch(() => {
        viewer?.toggleFullscreen?.();
      });
    }
  };

  document.addEventListener('fullscreenchange', () => {
    const active = Boolean(document.fullscreenElement);
    $('btn-fullscreen').classList.toggle('active', active);
    $('btn-fullscreen').setAttribute('aria-pressed', String(active));
  });

  // BUG-001 fix: Only show and bind BGM button if #bgm audio element exists with a valid src.
  const bgm = $('bgm');
  const btnBgm = $('btn-bgm');
  if (bgm && bgm.getAttribute('src')) {
    btnBgm.hidden = false;
    btnBgm.onclick = () => {
      if (bgm.paused) {
        bgm.play().then(() => {
          btnBgm.classList.add('active');
          btnBgm.setAttribute('aria-pressed', 'true');
        }).catch(() => {});
      } else {
        bgm.pause();
        btnBgm.classList.remove('active');
        btnBgm.setAttribute('aria-pressed', 'false');
      }
    };
  } else if (btnBgm) {
    btnBgm.hidden = true;
  }

  $('btn-retry').onclick = () => {
    if (scenes.length) loadScene(currentIndex);
    else bootstrap();
  };

  bootstrap();
})();
