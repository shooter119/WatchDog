const PREFIX = 'watchdog_admin_draft_v1:';

export function buildDraftKey(siteId, module) {
  return `${PREFIX}${String(siteId || '')}:${String(module || '')}`;
}

export function saveLocalDraft(siteId, module, revision, records, storage = globalThis.sessionStorage) {
  if (!storage || !siteId || !module) return false;
  try {
    const payload = {
      siteId: String(siteId),
      module: String(module),
      revision: Number(revision) || 0,
      savedAt: Date.now(),
      records,
    };
    storage.setItem(buildDraftKey(siteId, module), JSON.stringify(payload));
    return true;
  } catch {
    return false;
  }
}

export function loadLocalDraft(siteId, module, expectedRevision, storage = globalThis.sessionStorage) {
  if (!storage || !siteId || !module) return null;
  try {
    const raw = storage.getItem(buildDraftKey(siteId, module));
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || parsed.siteId !== String(siteId) || parsed.module !== String(module)) return null;
    if (expectedRevision !== undefined && Number(parsed.revision) !== Number(expectedRevision)) {
      storage.removeItem(buildDraftKey(siteId, module));
      return null;
    }
    if (!Array.isArray(parsed.records)) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function clearLocalDraft(siteId, module, storage = globalThis.sessionStorage) {
  if (!storage || !siteId || !module) return;
  try {
    storage.removeItem(buildDraftKey(siteId, module));
  } catch {
    // ignore storage failures
  }
}

export function clearAllLocalDrafts(storage = globalThis.sessionStorage) {
  if (!storage) return;
  try {
    const toRemove = [];
    for (let i = 0; i < storage.length; i += 1) {
      const k = storage.key(i);
      if (k && k.startsWith(PREFIX)) toRemove.push(k);
    }
    toRemove.forEach((k) => storage.removeItem(k));
  } catch {
    // ignore
  }
}
