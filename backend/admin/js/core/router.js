const VALID_ROUTES = new Set(['sites', 'panos', 'hazmats', 'water-sources', 'access']);

export function parseRouteFromHash(hash = window.location.hash) {
  const cleaned = String(hash || '').replace(/^#\/?/, '').split('?')[0].split('/')[0].trim();
  return VALID_ROUTES.has(cleaned) ? cleaned : 'sites';
}

export function createRouter({ getMember, onBeforeLeave, onRouteChange }) {
  let current = 'sites';
  let navigating = false;

  function canAccess(route) {
    if (!VALID_ROUTES.has(route)) return false;
    if (route === 'access') {
      return getMember()?.admin_role === 'platform_admin';
    }
    return true;
  }

  async function navigate(targetRoute, { syncHash = true, force = false } = {}) {
    if (navigating) return false;
    const resolved = canAccess(targetRoute) ? targetRoute : 'sites';
    if (!force && resolved === current) {
      if (syncHash && parseRouteFromHash() !== resolved) {
        history.replaceState(null, '', `#/${resolved}`);
      }
      return true;
    }

    navigating = true;
    try {
      if (!force && onBeforeLeave) {
        const allowed = await onBeforeLeave(current, resolved);
        if (!allowed) {
          if (parseRouteFromHash() !== current) {
            history.replaceState(null, '', `#/${current}`);
          }
          return false;
        }
      }
      const prev = current;
      current = resolved;
      if (syncHash && parseRouteFromHash() !== resolved) {
        history.pushState(null, '', `#/${resolved}`);
      }
      await onRouteChange(resolved, prev);
      return true;
    } finally {
      navigating = false;
    }
  }

  function resetToDefault() {
    current = 'sites';
  }

  window.addEventListener('hashchange', () => {
    if (!getMember()) return;
    const target = parseRouteFromHash();
    if (target !== current) {
      navigate(target, { syncHash: false });
    }
  });

  return {
    getCurrent: () => current,
    canAccess,
    navigate,
    resetToDefault,
  };
}
