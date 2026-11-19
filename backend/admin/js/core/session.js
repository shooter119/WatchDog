import { apiRequest, bumpAuthGeneration, onApiUnauthorized, setApiCsrf } from './api.js';

const HEARTBEAT_MS = 15000;

export function createSessionManager() {
  let member = null;
  let heartbeatTimer = null;
  let heartbeatInFlight = false;
  let offline = false;

  const listeners = {
    started: new Set(),
    refreshed: new Set(),
    ended: new Set(),
    connectivity: new Set(),
  };

  function emit(type, payload) {
    for (const fn of listeners[type]) {
      try {
        fn(payload);
      } catch (err) {
        console.error(`[session:${type}]`, err);
      }
    }
  }

  function setOffline(nextOffline) {
    if (offline === nextOffline) return;
    offline = nextOffline;
    emit('connectivity', { offline });
  }

  function stopHeartbeat() {
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
  }

  async function checkHeartbeat() {
    if (!member || heartbeatInFlight || document.hidden) return;
    heartbeatInFlight = true;
    try {
      const { data } = await apiRequest('/me', { poll: true });
      setOffline(false);
      if (data.csrf) setApiCsrf(data.csrf);
      const changedIdentity = !member || member.id !== data.member?.id || member.admin_role !== data.member?.admin_role;
      member = data.member;
      if (changedIdentity) {
        emit('started', member);
      } else {
        emit('refreshed', member);
      }
    } catch (err) {
      if (err?.status === 401 || err?.code === 'SESSION_EPOCH_CHANGED') {
        return;
      }
      // Transient network / 5xx errors must NOT kick the admin out or wipe unsaved forms
      setOffline(true);
    } finally {
      heartbeatInFlight = false;
    }
  }

  function startHeartbeat() {
    stopHeartbeat();
    heartbeatTimer = setInterval(checkHeartbeat, HEARTBEAT_MS);
  }

  function activate(nextMember, nextCsrf) {
    if (nextCsrf) setApiCsrf(nextCsrf);
    const shouldStart = !member || member.id !== nextMember?.id || member.admin_role !== nextMember?.admin_role;
    member = nextMember;
    setOffline(false);
    startHeartbeat();
    if (shouldStart) {
      emit('started', member);
    } else {
      emit('refreshed', member);
    }
  }

  function end(reason = '') {
    const hadSession = Boolean(member);
    bumpAuthGeneration();
    stopHeartbeat();
    setApiCsrf('');
    member = null;
    setOffline(false);
    emit('ended', { reason, hadSession });
  }

  async function restore() {
    try {
      const { data } = await apiRequest('/me', { suppressUnauthorized: true });
      if (data?.member) {
        activate(data.member, data.csrf);
        return true;
      }
      return false;
    } catch (err) {
      if (err?.status && err.status !== 401) {
        setOffline(true);
      }
      return false;
    }
  }

  async function logout(all = false) {
    try {
      await apiRequest('/logout', {
        method: 'POST',
        body: { all },
        suppressUnauthorized: true,
      });
    } catch {
      // Even if session was already expired (401) or network flaked, transition cleanly to login
    } finally {
      end(all ? '已退出所有设备会话' : '已安全退出登录');
    }
  }

  onApiUnauthorized((message) => {
    end(message);
  });

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && member) {
      checkHeartbeat();
    }
  });

  return {
    getMember: () => member,
    isOffline: () => offline,
    activate,
    end,
    restore,
    logout,
    retryHeartbeat: checkHeartbeat,
    on(event, fn) {
      listeners[event]?.add(fn);
      return () => listeners[event]?.delete(fn);
    },
  };
}
