import { $, encodePath } from '../../core/dom.js';
import { apiRequest } from '../../core/api.js';
import { clearAllLocalDrafts } from '../../core/draft-store.js';
import { confirmDialog } from '../../ui/modal.js';
import { toast } from '../../ui/toast.js';
import { renderSitesListView } from './list.js';
import { renderSiteProfileView } from './profile.js';
import { renderSiteEditorView } from './editor.js';

export function createSitesView({ getMember, onDirtyChange }) {
  let bootstrappedMemberId = null;
  let bootstrapPromise = null;
  let schema = null;
  let limits = null;
  let units = [];

  let view = 'list'; // 'list' | 'profile' | 'detail'
  let panoFocusMode = false;
  let query = { q: '', district: '', site_type: '' };
  let offset = 0;
  let limit = 20;
  let current = null;
  let activeSectionId = 'kind:siteOverview';
  let dirty = false;

  let navSeq = 0;
  let activeAbort = null;
  let activeEditorHandle = null;

  function setDirty(nextDirty) {
    dirty = Boolean(nextDirty);
    onDirtyChange?.(dirty);
  }

  function cleanupEditor() {
    activeEditorHandle?.destroy();
    activeEditorHandle = null;
  }

  async function ensureBootstrap() {
    const member = getMember();
    if (!member) return false;
    if (bootstrappedMemberId === member.id && schema && limits) return true;
    if (bootstrapPromise) return bootstrapPromise;

    bootstrapPromise = (async () => {
      const [limitsRes, unitsRes] = await Promise.all([
        apiRequest('/key-sites/limits'),
        apiRequest('/units'),
      ]);
      limits = limitsRes.data.limits || {};
      schema = limitsRes.data.schema || null;
      units = unitsRes.data.units || [];
      bootstrappedMemberId = member.id;
      return true;
    })();

    try {
      return await bootstrapPromise;
    } finally {
      bootstrapPromise = null;
    }
  }

  async function canLeave() {
    if (!dirty) return true;
    const confirmed = await confirmDialog({
      title: '有尚未保存的更改',
      message: '当前页面的编辑尚未保存，离开后未提交更改将丢失。确认离开吗？',
      confirmText: '放弃更改并离开',
      danger: true,
    });
    if (confirmed) {
      setDirty(false);
    }
    return confirmed;
  }

  async function loadList({ panoMode = panoFocusMode } = {}) {
    const root = $('site-manager');
    if (!root) return;
    cleanupEditor();
    view = 'list';
    panoFocusMode = Boolean(panoMode);
    setDirty(false);

    const seq = ++navSeq;
    activeAbort?.abort();
    activeAbort = new AbortController();

    renderSitesListView({
      root,
      query,
      sites: [],
      hasMore: false,
      offset,
      limit,
      loading: true,
      error: '',
      panoFocusMode,
      onSearch: () => {},
      onResetFilters: () => {},
      onCreate: () => {},
      onOpenDetail: () => {},
      onOpenPano: () => {},
      onEditProfile: () => {},
      onPageChange: () => {},
    });

    try {
      await ensureBootstrap();
      if (seq !== navSeq) return;
      const params = new URLSearchParams();
      params.set('offset', String(offset));
      if (query.q) params.set('q', query.q);
      if (query.district) params.set('district', query.district);
      if (query.site_type) params.set('site_type', query.site_type);

      const { data } = await apiRequest(`/key-sites?${params.toString()}`, { signal: activeAbort.signal });
      if (seq !== navSeq) return;

      limit = Number(data.limit) || 20;
      renderSitesListView({
        root,
        query,
        sites: data.sites || [],
        hasMore: Boolean(data.hasMore),
        offset: Number(data.offset ?? offset),
        limit,
        loading: false,
        error: '',
        panoFocusMode,
        onSearch: (nextQuery) => {
          query = nextQuery;
          offset = 0;
          loadList();
        },
        onResetFilters: () => {
          query = { q: '', district: '', site_type: '' };
          offset = 0;
          loadList();
        },
        onCreate: () => openProfile(null),
        onOpenDetail: (id) => openDetail(id, 'kind:siteOverview'),
        onOpenPano: (id) => openDetail(id, 'module:maps'),
        onEditProfile: (site) => openProfile(site),
        onPageChange: (nextOffset) => {
          offset = nextOffset;
          loadList();
        },
      });
    } catch (err) {
      if (err?.name === 'AbortError' || seq !== navSeq) return;
      renderSitesListView({
        root,
        query,
        sites: [],
        hasMore: false,
        offset,
        limit,
        loading: false,
        error: err?.message || '加载重点单位列表失败',
        panoFocusMode,
        onSearch: (nextQuery) => {
          query = nextQuery;
          offset = 0;
          loadList();
        },
        onResetFilters: () => {
          query = { q: '', district: '', site_type: '' };
          offset = 0;
          loadList();
        },
        onCreate: () => openProfile(null),
        onOpenDetail: () => {},
        onOpenPano: () => {},
        onEditProfile: () => {},
        onPageChange: () => {},
      });
    }
  }

  async function openProfile(site) {
    if (!(await canLeave())) return;
    const root = $('site-manager');
    if (!root) return;
    cleanupEditor();
    activeAbort?.abort();
    navSeq += 1;
    view = 'profile';
    setDirty(false);

    try {
      await ensureBootstrap();
    } catch (err) {
      toast.error(err?.message || '初始化单位配置失败');
      return;
    }

    renderSiteProfileView({
      root,
      site,
      units,
      member: getMember(),
      onMarkDirty: () => setDirty(true),
      onSaved: async (savedId) => {
        setDirty(false);
        if (savedId) {
          await openDetail(savedId, activeSectionId);
        } else {
          await loadList();
        }
      },
      onCancel: async () => {
        if (!(await canLeave())) return;
        if (site?.id && current?.site?.id === site.id) {
          await openDetail(site.id, activeSectionId);
        } else {
          await loadList();
        }
      },
      onOpenExisting: async (existingId) => {
        if (!(await canLeave())) return;
        await openDetail(existingId, 'kind:siteOverview');
      },
    });
  }

  async function openDetail(siteId, sectionId = 'kind:siteOverview') {
    const root = $('site-manager');
    if (!root) return;
    cleanupEditor();
    view = 'detail';
    activeSectionId = sectionId;

    const seq = ++navSeq;
    activeAbort?.abort();
    activeAbort = new AbortController();

    try {
      await ensureBootstrap();
      if (seq !== navSeq) return;
      const { data } = await apiRequest(`/key-sites/${encodePath(siteId)}`, { signal: activeAbort.signal });
      if (seq !== navSeq) return;
      current = data;
      setDirty(false);
      mountEditor();
    } catch (err) {
      if (err?.name === 'AbortError' || seq !== navSeq) return;
      toast.error(err?.message || '无法加载重点单位详情');
      await loadList();
    }
  }

  function mountEditor() {
    const root = $('site-manager');
    if (!root || !current) return;
    cleanupEditor();
    activeEditorHandle = renderSiteEditorView({
      root,
      current,
      schema,
      limits,
      activeSectionId,
      dirty,
      onSetDirty: setDirty,
      onSelectSection: async (nextSectionId) => {
        if (nextSectionId === activeSectionId) return;
        const nextModule = nextSectionId.startsWith('module:') ? nextSectionId.slice(7) : null;
        const currModule = activeSectionId.startsWith('module:') ? activeSectionId.slice(7) : null;
        const switchingModule = nextModule !== currModule
          || (nextSectionId.startsWith('kind:') && !activeSectionId.startsWith('kind:'))
          || getModuleOfSection(nextSectionId) !== getModuleOfSection(activeSectionId);

        if (switchingModule && !(await canLeave())) return;
        activeSectionId = nextSectionId;
        mountEditor();
      },
      onBackToList: async () => {
        if (!(await canLeave())) return;
        current = null;
        await loadList();
      },
      onEditProfile: (site) => openProfile(site),
      onReloadSite: async (siteId, sectionId) => {
        await openDetail(siteId, sectionId);
      },
    });
  }

  function getModuleOfSection(secId) {
    if (secId === 'module:maps') return 'maps';
    if (secId === 'module:plans') return 'plans';
    if (secId === 'kind:warehouseStock' || secId === 'kind:storageTank') return 'hazards';
    if (secId === 'kind:contact') return 'organization';
    return 'cards';
  }

  async function activateSites() {
    panoFocusMode = false;
    if (view === 'detail' && current?.site?.id) {
      if (activeSectionId === 'module:maps') {
        activeSectionId = 'kind:siteOverview';
      }
      mountEditor();
      return;
    }
    await loadList({ panoMode: false });
  }

  async function activatePanos() {
    panoFocusMode = true;
    // Fixes P0-3: if currently on editProfile(site), cleanly reload site detail in maps mode instead of crashing!
    if (current?.site?.id) {
      await openDetail(current.site.id, 'module:maps');
      return;
    }
    await loadList({ panoMode: true });
  }

  function reset() {
    cleanupEditor();
    activeAbort?.abort();
    navSeq += 1;
    bootstrappedMemberId = null;
    bootstrapPromise = null;
    schema = null;
    limits = null;
    units = [];
    view = 'list';
    panoFocusMode = false;
    query = { q: '', district: '', site_type: '' };
    offset = 0;
    limit = 20;
    current = null;
    activeSectionId = 'kind:siteOverview';
    setDirty(false);
    clearAllLocalDrafts();
    $('site-manager')?.replaceChildren();
  }

  return {
    activateSites,
    activatePanos,
    canLeave,
    isDirty: () => dirty,
    reset,
  };
}
