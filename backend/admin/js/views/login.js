import { $, el } from '../core/dom.js';
import { apiRequest } from '../core/api.js';

const POLL_INTERVAL_MS = 2000;
const RETRY_BACKOFF_MS = 4000;

function formatCountdown(remainingMs) {
  const sec = Math.max(0, Math.ceil(remainingMs / 1000));
  const m = String(Math.floor(sec / 60)).padStart(2, '0');
  const s = String(sec % 60).padStart(2, '0');
  return `${m}:${s}`;
}

export function createLoginView({ session, onLoginSuccess }) {
  let generation = 0;
  let pollTimer = null;
  let countdownTimer = null;
  let activeAbort = null;
  let activeChallenge = null;
  let visible = false;

  const loginSection = $('login');
  const qrBox = $('qr');
  const qrExpiredOverlay = $('qr-expired');
  const stateEl = $('login-state');
  const countdownEl = $('qr-countdown');
  const errorEl = $('login-error');
  const refreshBtn = $('refresh');
  const overlayRefreshBtn = $('qr-overlay-refresh');

  function setInlineError(message) {
    if (!errorEl) return;
    errorEl.textContent = message || '';
    errorEl.hidden = !message;
  }

  function stopTimersAndRequests() {
    if (pollTimer) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
    if (countdownTimer) {
      clearInterval(countdownTimer);
      countdownTimer = null;
    }
    if (activeAbort) {
      activeAbort.abort();
      activeAbort = null;
    }
    activeChallenge = null;
  }

  function markExpired(message = '二维码已失效，请重新生成') {
    stopTimersAndRequests();
    if (stateEl) stateEl.textContent = message;
    if (countdownEl) {
      countdownEl.textContent = '00:00';
      countdownEl.classList.add('expiring');
      countdownEl.hidden = false;
    }
    if (qrExpiredOverlay) qrExpiredOverlay.hidden = false;
  }

  function startCountdown(deadlineAt, currentGen) {
    const tick = () => {
      if (currentGen !== generation || !visible) return;
      const remaining = deadlineAt - Date.now();
      if (remaining <= 0) {
        markExpired('二维码已过期，请点击重新生成');
        return;
      }
      if (countdownEl) {
        countdownEl.hidden = false;
        countdownEl.textContent = formatCountdown(remaining);
        countdownEl.classList.toggle('expiring', remaining <= 20000);
      }
    };
    tick();
    countdownTimer = setInterval(tick, 1000);
  }

  async function pollOnce(challengeId, deadlineAt, currentGen) {
    if (currentGen !== generation || !visible) return;
    if (Date.now() >= deadlineAt) {
      markExpired('二维码已过期，请点击重新生成');
      return;
    }
    if (document.hidden) {
      return;
    }

    activeAbort = new AbortController();
    try {
      const { status, data } = await apiRequest('/login/claim', {
        method: 'POST',
        body: { id: challengeId },
        signal: activeAbort.signal,
        suppressUnauthorized: true,
      });
      if (currentGen !== generation || !visible) return;
      if (status === 202 || data?.state === 'pending') {
        if (stateEl) stateEl.textContent = '请使用火场智控 App 扫码并确认登录';
        pollTimer = setTimeout(() => pollOnce(challengeId, deadlineAt, currentGen), POLL_INTERVAL_MS);
        return;
      }
      if (data?.member) {
        hide();
        onLoginSuccess(data.member, data.csrf);
      }
    } catch (err) {
      if (err?.name === 'AbortError' || currentGen !== generation || !visible) return;
      if (err?.status === 409 || err?.code === 'ADMIN_CHALLENGE_INVALID') {
        markExpired('二维码已被取消或失效，请重新生成');
        return;
      }
      // Transient network / 5xx / 429: keep QR visible and retry with backoff
      if (stateEl) {
        stateEl.textContent = err?.status === 429
          ? '请求频率较高，正在自动等待重试…'
          : '网络波动，正在等待连接恢复…';
      }
      pollTimer = setTimeout(() => pollOnce(challengeId, deadlineAt, currentGen), RETRY_BACKOFF_MS);
    }
  }

  async function refreshChallenge() {
    if (!visible) return;
    const currentGen = ++generation;
    stopTimersAndRequests();
    setInlineError('');
    if (qrExpiredOverlay) qrExpiredOverlay.hidden = true;
    if (countdownEl) {
      countdownEl.hidden = true;
      countdownEl.classList.remove('expiring');
    }
    if (refreshBtn) refreshBtn.disabled = true;
    if (qrBox) {
      qrBox.replaceChildren(el('span', { className: 'muted', style: { fontSize: '12px' } }, '生成中…'));
    }
    if (stateEl) stateEl.textContent = '正在生成安全登录二维码…';

    activeAbort = new AbortController();
    try {
      const { data } = await apiRequest('/login/challenges', {
        method: 'POST',
        body: {},
        signal: activeAbort.signal,
        suppressUnauthorized: true,
      });
      if (currentGen !== generation || !visible) return;

      const ttlMs = Number.isFinite(Number(data.expiresInMs)) && Number(data.expiresInMs) > 0
        ? Number(data.expiresInMs)
        : Math.max(15000, Math.min(120000, (Number(data.expiresAt) || Date.now() + 120000) - Date.now()));
      const deadlineAt = Date.now() + ttlMs;
      activeChallenge = { id: data.id, deadlineAt, gen: currentGen };

      const img = el('img', {
        src: data.qrImage,
        alt: '管理后台扫码登录二维码',
        width: 220,
        height: 220,
      });
      if (qrBox) qrBox.replaceChildren(img);
      if (stateEl) stateEl.textContent = '请使用火场智控 App 扫码并确认登录';

      startCountdown(deadlineAt, currentGen);
      pollTimer = setTimeout(() => pollOnce(data.id, deadlineAt, currentGen), POLL_INTERVAL_MS);
    } catch (err) {
      if (err?.name === 'AbortError' || currentGen !== generation || !visible) return;
      if (qrBox) qrBox.replaceChildren();
      if (stateEl) stateEl.textContent = '二维码获取失败';
      setInlineError(err?.message || '无法生成登录二维码，请检查网络后重试');
      if (qrExpiredOverlay) qrExpiredOverlay.hidden = false;
    } finally {
      if (currentGen === generation && refreshBtn) {
        refreshBtn.disabled = false;
      }
    }
  }

  function show(reason = '') {
    visible = true;
    if (loginSection) loginSection.hidden = false;
    setInlineError(reason);
    refreshChallenge();
  }

  function hide() {
    visible = false;
    generation += 1;
    stopTimersAndRequests();
    setInlineError('');
    if (qrBox) qrBox.replaceChildren();
    if (qrExpiredOverlay) qrExpiredOverlay.hidden = true;
    if (countdownEl) {
      countdownEl.hidden = true;
      countdownEl.textContent = '';
      countdownEl.classList.remove('expiring');
    }
    if (stateEl) stateEl.textContent = '';
    if (refreshBtn) refreshBtn.disabled = false;
    if (loginSection) loginSection.hidden = true;
  }

  refreshBtn?.addEventListener('click', () => refreshChallenge());
  overlayRefreshBtn?.addEventListener('click', () => refreshChallenge());

  document.addEventListener('visibilitychange', async () => {
    if (document.hidden || !visible) return;
    // Another tab might have completed login while this tab was in background
    const restored = await session.restore();
    if (restored) return;
    if (activeChallenge && activeChallenge.gen === generation) {
      if (Date.now() >= activeChallenge.deadlineAt) {
        markExpired('二维码已过期，请点击重新生成');
      } else if (!pollTimer) {
        pollOnce(activeChallenge.id, activeChallenge.deadlineAt, generation);
      }
    }
  });

  return {
    show,
    hide,
    refresh: refreshChallenge,
  };
}
