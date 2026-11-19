const $ = (id) => document.getElementById(id);

const DEFAULT_VIEW = {
  hfov: 105,
  minHfov: 35,
  maxHfov: 120,
  pitch: -5,
  yaw: 20,
  autoRotate: -1.6,
  northOffset: 0,
};

const FETCH_TIMEOUT_MS = 45000;
const STEREO_OFFSET_DEG = 3.2;
const PANO_TOKEN_STORAGE_KEY = 'watchdog_pano_token';

const isBrowser = typeof window !== 'undefined' && typeof document !== 'undefined';
const params = isBrowser ? new URLSearchParams(window.location.search) : new URLSearchParams();
const hashParams = isBrowser ? new URLSearchParams(window.location.hash.replace(/^#/, '')) : new URLSearchParams();
const siteId = params.get('siteId') || '';
const initialAttachmentId = params.get('attachmentId') || '';
const version = params.get('version') || '';
const incidentId = params.get('incidentId') || '';
const hashToken = hashParams.get('token') || '';
const mode = params.get('mode') || (version || hashToken ? 'app' : 'admin');

let appToken = '';
if (isBrowser) {
  try {
    if (hashToken) {
      appToken = hashToken;
      sessionStorage.setItem(PANO_TOKEN_STORAGE_KEY, hashToken);
      history.replaceState(null, '', window.location.pathname + window.location.search);
    } else {
      appToken = sessionStorage.getItem(PANO_TOKEN_STORAGE_KEY) || '';
    }
  } catch {
    appToken = hashToken;
  }
}

let viewer = null;
let rightViewer = null;
let vrSyncFrame = null;
let vrEnabled = false;
let autoRotating = true;
let currentBlobUrl = null;
let activeAbort = null;
let loadToken = 0;
let scenes = [];
let currentIndex = 0;

function clearStoredAppToken() {
  appToken = '';
  try {
    sessionStorage.removeItem(PANO_TOKEN_STORAGE_KEY);
  } catch {
    // ignore storage errors
  }
}

function authHeaders() {
  return mode === 'app' && appToken ? { Authorization: `Bearer ${appToken}` } : {};
}

function detectMaxTextureSize() {
  try {
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext('webgl2') || canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
    if (!gl) return 0;
    const size = Number(gl.getParameter(gl.MAX_TEXTURE_SIZE)) || 0;
    gl.getExtension('WEBGL_lose_context')?.loseContext();
    return size;
  } catch {
    return 0;
  }
}

const maxWebGLTextureSize = detectMaxTextureSize();

function setLoading(visible, text = '正在加载全景图…', progress = null, { canRetry = false, showAdminLogin = false } = {}) {
  const overlay = $('loading');
  if (!overlay) return;
  overlay.hidden = !visible;
  if (!visible) return;
  $('loading-text').textContent = text;
  $('loading-spinner').hidden = canRetry || showAdminLogin;
  const track = $('progress-track');
  track.hidden = progress === null;
  if (progress !== null) {
    const pct = Math.max(5, Math.min(100, Math.round(progress)));
    $('progress-bar').style.width = `${pct}%`;
  }
  $('btn-retry').hidden = !canRetry;
  const backAdmin = $('btn-back-admin');
  if (backAdmin) backAdmin.hidden = !showAdminLogin;
}

function stopVrSync() {
  if (vrSyncFrame !== null) {
    cancelAnimationFrame(vrSyncFrame);
    vrSyncFrame = null;
  }
}

function cleanupViewers() {
  stopVrSync();
  if (rightViewer) {
    try { rightViewer.destroy(); } catch { /* ignore */ }
    rightViewer = null;
  }
  if (viewer) {
    try { viewer.destroy(); } catch { /* ignore */ }
    viewer = null;
  }
  $('viewer')?.replaceChildren();
  $('viewer-right')?.replaceChildren();
  if (currentBlobUrl) {
    URL.revokeObjectURL(currentBlobUrl);
    currentBlobUrl = null;
  }
}

function syncRotateButton(active) {
  autoRotating = Boolean(active);
  const btn = $('btn-rotate');
  if (!btn) return;
  btn.classList.toggle('active', autoRotating);
  btn.setAttribute('aria-pressed', String(autoRotating));
}

function createPannellum(containerId, blobUrl, config, options = {}) {
  if (!window.pannellum?.viewer) {
    throw new Error('全景渲染引擎未加载完成，请刷新页面重试');
  }
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

function startVrSyncLoop() {
  stopVrSync();
  const tick = () => {
    if (!vrEnabled || !viewer || !rightViewer) {
      vrSyncFrame = null;
      return;
    }
    if (!document.hidden) {
      try {
        rightViewer.lookAt(viewer.getPitch(), viewer.getYaw() + STEREO_OFFSET_DEG, viewer.getHfov(), false);
      } catch {
        // ignore transient frame read errors
      }
    }
    vrSyncFrame = requestAnimationFrame(tick);
  };
  vrSyncFrame = requestAnimationFrame(tick);
}

function applyVRMode(enable) {
  vrEnabled = Boolean(enable);
  const stage = $('stage');
  const rightEl = $('viewer-right');
  const btn = $('btn-vr');
  stage?.classList.toggle('vr-mode', vrEnabled);
  if (rightEl) rightEl.hidden = !vrEnabled;
  btn?.classList.toggle('active', vrEnabled);
  btn?.setAttribute('aria-pressed', String(vrEnabled));

  stopVrSync();
  if (rightViewer) {
    try { rightViewer.destroy(); } catch { /* ignore */ }
    rightViewer = null;
    rightEl?.replaceChildren();
  }
  if (!viewer) return;
  try { viewer.resize(); } catch { /* ignore */ }

  if (vrEnabled && currentBlobUrl) {
    const scene = scenes[currentIndex] || {};
    try {
      rightViewer = createPannellum('viewer-right', currentBlobUrl, {
        ...(scene.config || {}),
        pitch: viewer.getPitch(),
        yaw: viewer.getYaw() + STEREO_OFFSET_DEG,
        hfov: viewer.getHfov(),
      }, { autoRotate: false, compass: false });

      rightViewer.on('error', () => {
        applyVRMode(false);
        const subtitle = $('pano-subtitle');
        if (subtitle && !subtitle.textContent.includes('VR')) {
          subtitle.textContent = `${subtitle.textContent} · 当前设备显存不足，已自动退出 VR 分屏`;
        }
      });
      startVrSyncLoop();
    } catch {
      applyVRMode(false);
    }
  }
}

async function fetchImageBlob(url, externalSignal) {
  const timeoutCtrl = new AbortController();
  const timer = setTimeout(() => timeoutCtrl.abort(), FETCH_TIMEOUT_MS);
  const onExternalAbort = () => timeoutCtrl.abort();
  externalSignal?.addEventListener('abort', onExternalAbort, { once: true });

  try {
    const response = await fetch(url, {
      method: 'GET',
      credentials: mode === 'admin' ? 'same-origin' : 'omit',
      headers: authHeaders(),
      signal: timeoutCtrl.signal,
    });
    if (response.status === 401 || response.status === 403) {
      if (mode === 'app') clearStoredAppToken();
      const err = new Error(
        mode === 'admin'
          ? '后台会话已失效或无权限查看该全景图，请返回管理后台重新扫码登录'
          : '移动端鉴权已失效或无权限查看该全景图，请在 App 内重新打开',
      );
      err.status = response.status;
      throw err;
    }
    if (!response.ok) {
      const err = new Error(`全景图加载失败（HTTP ${response.status}）`);
      err.status = response.status;
      throw err;
    }
    const contentLength = Number(response.headers.get('content-length')) || 0;
    if (!response.body || contentLength <= 0) {
      setLoading(true, '正在接收全景图像数据…', 65);
      return await response.blob();
    }
    const reader = response.body.getReader();
    const chunks = [];
    let received = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.byteLength;
      const ratio = Math.min(1, received / contentLength);
      const pct = Math.round(ratio * 100);
      setLoading(true, `正在加载全景图 (${pct}%)…`, Math.max(15, Math.min(90, Math.round(ratio * 90))));
    }
    return new Blob(chunks, { type: response.headers.get('content-type') || 'image/jpeg' });
  } catch (err) {
    if (externalSignal?.aborted) {
      const abortErr = new Error('已取消加载');
      abortErr.name = 'AbortError';
      throw abortErr;
    }
    if (err?.name === 'AbortError') {
      throw new Error('全景图下载超时，请检查网络连接后重试');
    }
    throw err;
  } finally {
    clearTimeout(timer);
    externalSignal?.removeEventListener('abort', onExternalAbort);
  }
}

function renderSceneBar() {
  const bar = $('scene-bar');
  if (!bar) return;
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
    pill.setAttribute('aria-current', index === currentIndex ? 'true' : 'false');
    pill.addEventListener('click', () => {
      if (index !== currentIndex) loadScene(index);
    });
    bar.append(pill);
  });
}

function shouldPreferPreviewResolution(scene) {
  if (!scene.fallbackImageUrl || !maxWebGLTextureSize) return false;
  const imgWidth = Number(scene.width) || 0;
  return imgWidth > maxWebGLTextureSize;
}

async function loadScene(index, { forceFallback = false } = {}) {
  if (!scenes.length || index < 0 || index >= scenes.length) return;
  currentIndex = index;
  const scene = scenes[currentIndex];
  const token = ++loadToken;

  activeAbort?.abort();
  activeAbort = new AbortController();
  const signal = activeAbort.signal;

  renderSceneBar();
  $('pano-title').textContent = scene.siteName || '重点单位全景';
  const countNote = scenes.length > 1 ? ` · 机位 ${currentIndex + 1}/${scenes.length}` : '';
  const useFallback = forceFallback || shouldPreferPreviewResolution(scene);
  const targetUrl = (useFallback && scene.fallbackImageUrl) ? scene.fallbackImageUrl : scene.imageUrl;
  const qualityTag = (useFallback && scene.fallbackImageUrl) ? ' · 兼容清晰度模式' : '';
  $('pano-subtitle').textContent = `${scene.label}${scene.subtitle ? ` · ${scene.subtitle}` : ''}${countNote}${qualityTag}`;

  cleanupViewers();
  setLoading(true, `正在加载「${scene.label}」…`, 15);

  try {
    const blob = await fetchImageBlob(targetUrl, signal);
    if (token !== loadToken || signal.aborted) return;

    currentBlobUrl = URL.createObjectURL(blob);
    setLoading(true, '正在初始化 3D 球面纹理…', 95);

    const instance = createPannellum('viewer', currentBlobUrl, scene.config || {}, {
      autoRotate: autoRotating,
      compass: true,
    });
    if (token !== loadToken) {
      try { instance.destroy(); } catch { /* ignore */ }
      return;
    }
    viewer = instance;

    viewer.on('load', () => {
      if (token !== loadToken) return;
      setLoading(false);
      if (vrEnabled) applyVRMode(true);
    });

    viewer.on('error', (err) => {
      if (token !== loadToken) return;
      const errText = String(err || '未知错误');
      if (!useFallback && scene.fallbackImageUrl && /texture|size|webgl|width|limit/i.test(errText)) {
        loadScene(index, { forceFallback: true });
        return;
      }
      setLoading(true, `全景渲染失败：${errText}`, null, { canRetry: true });
    });

    viewer.on('mousedown', () => syncRotateButton(false));
    viewer.on('touchstart', () => syncRotateButton(false));
  } catch (error) {
    if (error?.name === 'AbortError' || token !== loadToken) return;
    const isAdminAuthErr = mode === 'admin' && (error?.status === 401 || error?.status === 403);
    setLoading(true, error?.message || '全景图加载失败', null, {
      canRetry: !isAdminAuthErr,
      showAdminLogin: isAdminAuthErr,
    });
  }
}

export function buildScenesFromSite(siteName, contentMaps, attachments, urlBuilder, fallbackUrlBuilder) {
  const readyPanos = new Map(
    (attachments || [])
      .filter((att) => att.metadata?.panorama && (att.status === 'ready' || att.status === undefined))
      .map((att) => [att.id, att]),
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
        fallbackImageUrl: fallbackUrlBuilder ? fallbackUrlBuilder(att.id) : '',
        width: Number(att.metadata?.width) || 0,
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
      fallbackImageUrl: fallbackUrlBuilder ? fallbackUrlBuilder(att.id) : '',
      width: Number(att.metadata?.width) || 0,
      config: typeof att.metadata.panorama === 'object' ? att.metadata.panorama : {},
    });
  }
  return list;
}

async function bootstrap() {
  if (!siteId) {
    setLoading(true, '缺少重点单位参数（siteId），请从重点单位资料页面进入', null, {
      canRetry: false,
      showAdminLogin: mode === 'admin',
    });
    return;
  }
  const token = ++loadToken;
  activeAbort?.abort();
  activeAbort = new AbortController();

  setLoading(true, '正在核验身份并读取重点单位全景配置…', 10);
  try {
    if (mode === 'app') {
      const verPath = version ? `/versions/${encodeURIComponent(version)}` : '';
      const query = incidentId ? `?incidentId=${encodeURIComponent(incidentId)}` : '';
      const response = await fetch(`/api/key-sites/${encodeURIComponent(siteId)}${verPath}${query}`, {
        headers: authHeaders(),
        signal: activeAbort.signal,
      });
      if (token !== loadToken) return;
      if (response.status === 401 || response.status === 403) {
        clearStoredAppToken();
        const err = new Error('请先在火场智控 App 内完成有效成员认证后再查阅全景资料');
        err.status = response.status;
        throw err;
      }
      if (!response.ok) throw new Error('重点单位暂无已发布的全景资料');
      const data = await response.json();
      const ver = data.version;
      scenes = buildScenesFromSite(
        data.profile?.name || '重点单位',
        data.content?.maps || [],
        data.attachments || [],
        (attId) => `/api/key-sites/${encodeURIComponent(siteId)}/versions/${encodeURIComponent(ver)}/attachments/${encodeURIComponent(attId)}/panorama.jpg${query}`,
        (attId) => `/api/key-sites/${encodeURIComponent(siteId)}/versions/${encodeURIComponent(ver)}/attachments/${encodeURIComponent(attId)}/page-1.jpg${query}`,
      );
    } else {
      const response = await fetch(`/api/admin/key-sites/${encodeURIComponent(siteId)}`, {
        credentials: 'same-origin',
        signal: activeAbort.signal,
      });
      if (token !== loadToken) return;
      if (response.status === 401 || response.status === 403) {
        const err = new Error('后台会话已失效或无权访问，请返回管理后台重新扫码登录');
        err.status = response.status;
        throw err;
      }
      if (!response.ok) throw new Error('无法读取重点单位全景列表');
      const data = await response.json();
      scenes = buildScenesFromSite(
        data.site?.name || '重点单位',
        data.draft?.content?.maps || [],
        data.attachments || [],
        (attId) => `/api/admin/key-sites/${encodeURIComponent(siteId)}/attachments/${encodeURIComponent(attId)}/panorama.jpg`,
        (attId) => `/api/admin/key-sites/${encodeURIComponent(siteId)}/attachments/${encodeURIComponent(attId)}/page-1.jpg`,
      );
    }

    if (token !== loadToken) return;
    if (!scenes.length) {
      setLoading(true, '该重点单位暂无已就绪的 360° 全景图', null, {
        canRetry: false,
        showAdminLogin: mode === 'admin',
      });
      return;
    }

    const targetIdx = initialAttachmentId
      ? Math.max(0, scenes.findIndex((s) => s.attachmentId === initialAttachmentId))
      : 0;
    await loadScene(targetIdx);
  } catch (error) {
    if (error?.name === 'AbortError' || token !== loadToken) return;
    const isAdminAuthErr = mode === 'admin' && (error?.status === 401 || error?.status === 403);
    setLoading(true, error?.message || '加载失败，请重试', null, {
      canRetry: !isAdminAuthErr,
      showAdminLogin: isAdminAuthErr,
    });
  }
}

// Release WebGL contexts, Blob URLs, and in-flight requests cleanly on tab/WebView exit
function teardown() {
  loadToken += 1;
  activeAbort?.abort();
  cleanupViewers();
}

if (isBrowser) {
  $('btn-rotate')?.addEventListener('click', () => {
    if (!viewer) return;
    if (autoRotating) {
      viewer.stopAutoRotate();
      syncRotateButton(false);
    } else {
      const scene = scenes[currentIndex] || {};
      viewer.startAutoRotate(scene.config?.autoRotate ?? DEFAULT_VIEW.autoRotate);
      syncRotateButton(true);
    }
  });

  $('btn-reset')?.addEventListener('click', () => {
    if (!viewer) return;
    const scene = scenes[currentIndex] || {};
    const cfg = scene.config || {};
    viewer.lookAt(cfg.pitch ?? DEFAULT_VIEW.pitch, cfg.yaw ?? DEFAULT_VIEW.yaw, cfg.hfov ?? DEFAULT_VIEW.hfov, 600);
  });

  $('btn-vr')?.addEventListener('click', () => applyVRMode(!vrEnabled));

  $('btn-fullscreen')?.addEventListener('click', () => {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen?.().catch(() => {
        viewer?.toggleFullscreen?.();
      });
    } else {
      document.exitFullscreen?.().catch(() => {
        viewer?.toggleFullscreen?.();
      });
    }
  });

  document.addEventListener('fullscreenchange', () => {
    const active = Boolean(document.fullscreenElement);
    const btn = $('btn-fullscreen');
    btn?.classList.toggle('active', active);
    btn?.setAttribute('aria-pressed', String(active));
  });

  $('btn-retry')?.addEventListener('click', () => {
    if (scenes.length) loadScene(currentIndex);
    else bootstrap();
  });

  window.addEventListener('pagehide', teardown);
  window.addEventListener('beforeunload', teardown);

  if ($('viewer')) {
    bootstrap();
  }
}
