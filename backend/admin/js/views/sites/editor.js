import { createAsyncButton, el, encodePath, formatDate } from '../../core/dom.js';
import { apiRequest } from '../../core/api.js';
import { clearLocalDraft, loadLocalDraft, saveLocalDraft } from '../../core/draft-store.js';
import { confirmDialog } from '../../ui/modal.js';
import { toast } from '../../ui/toast.js';
import { createAttachmentsPanel } from './attachments.js';
import { openSiteHistoryModal } from './history.js';
import {
  countOutlineSection,
  getFieldLabel,
  getFieldsForRecord,
  MODULE_META,
  OUTLINE_GROUPS,
  REPEATABLE_KINDS,
  sanitizeSiteProfilePayload,
  serializeModuleEntries,
} from './model.js';

export function renderSiteEditorView({
  root,
  current,
  schema,
  limits,
  activeSectionId,
  dirty,
  onSetDirty,
  onSelectSection,
  onBackToList,
  onEditProfile,
  onReloadSite,
}) {
  const site = current.site;
  const draft = current.draft || { revision: 0, content: {} };
  const content = draft.content && typeof draft.content === 'object' ? draft.content : {};

  let activeOutline = null;
  for (const grp of OUTLINE_GROUPS) {
    const found = grp.items.find((it) => it.id === activeSectionId);
    if (found) {
      activeOutline = found;
      break;
    }
  }
  if (!activeOutline) {
    activeOutline = OUTLINE_GROUPS[0].items[0];
  }

  const activeModule = activeOutline.module;
  const activeKind = activeOutline.kind;
  const moduleEntries = Array.isArray(content[activeModule]) ? content[activeModule] : [];

  let attachmentsPanel = null;
  let keydownHandler = null;

  function buildRecordModels(rawEntries) {
    const attachments = current.attachments || [];
    const readyPanos = attachments.filter((f) => f.module === 'maps' && f.status === 'ready' && f.metadata?.panorama);
    const readyFlatMaps = attachments.filter((f) => f.module === 'maps' && f.status === 'ready' && !f.metadata?.panorama);
    const readyPanoIds = new Set(readyPanos.map((f) => f.id));
    const readyFlatIds = new Set(readyFlatMaps.map((f) => f.id));

    return (rawEntries || []).map((entry) => {
      const origSources = Array.isArray(entry.sources) ? entry.sources : [];
      const selectedPanos = origSources
        .filter((s) => readyPanoIds.has(s.attachmentId))
        .map((s) => ({ attachmentId: s.attachmentId, paragraph: s.paragraph || '' }));
      const flatSource = !selectedPanos.length
        ? origSources.find((s) => readyFlatIds.has(s.attachmentId))
        : null;
      const preservedSources = origSources.filter(
        (s) => !readyPanoIds.has(s.attachmentId) && !readyFlatIds.has(s.attachmentId),
      );

      return {
        kind: entry.kind || null,
        title: entry.title || '',
        defaultTitle: entry.kind ? (schema?.kinds?.[entry.kind]?.label || '') : '',
        body: entry.body || '',
        fields: { ...(entry.fields || {}) },
        originalSources: origSources,
        selectedPanos,
        flatMapAttachmentId: flatSource?.attachmentId || '',
        flatMapPage: flatSource?.page || 1,
        preservedSources,
        removed: false,
        isBlankTemplate: false,
      };
    });
  }

  let allModuleRecords = buildRecordModels(moduleEntries);

  // Ensure singleton kind has a blank editable template if none exists yet
  if (activeKind && !REPEATABLE_KINDS.has(activeKind)) {
    const exists = allModuleRecords.some((r) => !r.removed && r.kind === activeKind);
    if (!exists) {
      allModuleRecords.push({
        kind: activeKind,
        title: schema?.kinds?.[activeKind]?.label || activeOutline.label,
        defaultTitle: schema?.kinds?.[activeKind]?.label || activeOutline.label,
        body: '',
        fields: {},
        originalSources: [],
        selectedPanos: [],
        flatMapAttachmentId: '',
        flatMapPage: 1,
        preservedSources: [],
        removed: false,
        isBlankTemplate: true,
      });
    }
  }

  let isDirty = Boolean(dirty);

  function setLocalDirty(nextDirty) {
    isDirty = Boolean(nextDirty);
    onSetDirty(isDirty);
  }

  function markDirtyAndPersist() {
    setLocalDirty(true);
    saveLocalDraft(site.id, activeModule, draft.revision, serializeModuleEntries(activeModule, allModuleRecords));
    updateStickyStatus();
  }

  // Header
  const toggleActiveBtn = createAsyncButton(
    site.active ? '停用单位' : '恢复启用',
    site.active ? 'btn btn-danger-outline btn-sm' : 'btn btn-secondary btn-sm',
    async () => {
      if (isDirty) {
        const leave = await confirmDialog({
          title: '有未保存的编辑',
          message: '切换单位启停状态将重新加载页面，未保存的草稿更改将丢失。确认继续吗？',
          confirmText: '放弃编辑并继续',
          danger: true,
        });
        if (!leave) return;
      }
      const nextActive = !site.active;
      const confirmed = await confirmDialog({
        title: nextActive ? '恢复重点单位' : '停用重点单位',
        message: nextActive
          ? `确认恢复启用「${site.name}」吗？`
          : `确认停用「${site.name}」吗？停用后将不再向移动端推送。`,
        confirmText: nextActive ? '确认恢复' : '确认停用',
        danger: !nextActive,
      });
      if (!confirmed) return;
      try {
        await apiRequest(`/key-sites/${encodePath(site.id)}`, {
          method: 'PUT',
          body: sanitizeSiteProfilePayload(site, { active: nextActive }),
        });
        onSetDirty(false);
        toast.success(nextActive ? '已恢复启用该重点单位' : '已停用该重点单位');
        await onReloadSite(site.id, activeOutline.id);
      } catch (err) {
        toast.error(err?.message || '状态更新失败');
      }
    },
  );

  const headerEl = el(
    'header',
    { className: 'site-detail-header' },
    el(
      'div',
      null,
      el(
        'div',
        { className: 'site-breadcrumb' },
        el('button', { type: 'button', className: 'btn btn-subtle btn-xs', onClick: onBackToList }, '← 返回单位列表'),
        el('span', null, '/'),
        el('span', null, MODULE_META[activeModule]?.label || activeModule),
      ),
      el(
        'div',
        { className: 'site-detail-title' },
        el('h2', null, site.name || '重点单位'),
        site.active ? el('span', { className: 'pill pill-safe' }, '启用中') : el('span', { className: 'pill pill-danger' }, '已停用'),
        site.published_version
          ? el('span', { className: 'pill pill-info' }, `已发布 v${site.published_version}`)
          : el('span', { className: 'pill pill-caution' }, '尚未发布到 App'),
        el('span', { className: 'pill pill-neutral' }, `草稿修订 #${draft.revision ?? 0}`),
      ),
      el(
        'p',
        { className: 'site-detail-meta' },
        [site.address || '未填写地址', site.district, site.site_type].filter(Boolean).join(' · '),
      ),
    ),
    el(
      'div',
      { className: 'toolbar-actions' },
      el('button', { type: 'button', className: 'btn btn-secondary btn-sm', onClick: () => onEditProfile(site) }, '编辑基础档案'),
      el('button', {
        type: 'button',
        className: 'btn btn-secondary btn-sm',
        onClick: () => openSiteHistoryModal({ site, schema }),
      }, '发布历史'),
      toggleActiveBtn,
    ),
  );

  // Left 9-Section Outline
  const outlineEl = el(
    'aside',
    { className: 'section-outline', 'aria-label': '九大分项大纲导航' },
    ...OUTLINE_GROUPS.map((group) => el(
      'div',
      { className: 'outline-group' },
      el('div', { className: 'outline-group-label' }, group.label),
      el(
        'div',
        { className: 'outline-list' },
        ...group.items.map((item) => el(
          'button',
          {
            type: 'button',
            className: `outline-btn${item.id === activeOutline.id ? ' active' : ''}`,
            onClick: () => onSelectSection(item.id),
          },
          el('span', null, item.label),
          el('span', { className: 'outline-count' }, countOutlineSection(item, content, schema)),
        )),
      ),
    )),
  );

  // Local draft recovery banner (if sessionStorage has unsaved edits matching this revision)
  const localDraft = !isDirty ? loadLocalDraft(site.id, activeModule, draft.revision) : null;
  const recoveryBanner = localDraft
    ? el(
      'div',
      { className: 'inline-alert inline-alert-caution' },
      el('span', null, `检测到本会话 ${formatDate(localDraft.savedAt)} 有未提交的「${MODULE_META[activeModule]?.label}」草稿缓存，是否恢复？`),
      el(
        'div',
        { className: 'toolbar-actions' },
        el('button', {
          type: 'button',
          className: 'btn btn-primary btn-xs',
          onClick: () => {
            allModuleRecords = buildRecordModels(localDraft.records);
            recoveryBanner.remove();
            renderRecordsArea();
            setLocalDirty(true);
            updateStickyStatus();
            toast.info('已恢复本地草稿缓存，请核对后点击「保存草稿」');
          },
        }, '恢复草稿'),
        el('button', {
          type: 'button',
          className: 'btn btn-subtle btn-xs',
          onClick: () => {
            clearLocalDraft(site.id, activeModule);
            recoveryBanner.remove();
          },
        }, '忽略'),
      ),
    )
    : null;

  // Records Form Area
  const recordsContainer = el('div', { style: { display: 'flex', flexDirection: 'column', gap: '12px' } });

  function getVisibleRecords() {
    return allModuleRecords.filter((rec) => {
      if (rec.removed) return false;
      if (activeKind) return rec.kind === activeKind;
      return true;
    });
  }

  function renderMapSourceSelector(rec) {
    const attachments = current.attachments || [];
    const readyPanos = attachments.filter((f) => f.module === 'maps' && f.status === 'ready' && f.metadata?.panorama);
    const readyFlatMaps = attachments.filter((f) => f.module === 'maps' && f.status === 'ready' && !f.metadata?.panorama);

    const flatSelect = el(
      'select',
      { className: 'select-control' },
      el('option', { value: '' }, '不关联平面地图'),
      ...readyFlatMaps.map((f) => el('option', { value: f.id }, `${f.filename}${f.metadata?.pages ? `（共 ${f.metadata.pages} 页）` : ''}`)),
    );
    flatSelect.value = rec.flatMapAttachmentId || '';

    const getSelectedFlatMaxPages = () => {
      const att = readyFlatMaps.find((f) => f.id === flatSelect.value);
      return Number(att?.metadata?.pages) || Number(limits?.pages) || 200;
    };

    const pageInput = el('input', {
      type: 'number',
      min: 1,
      max: getSelectedFlatMaxPages(),
      className: 'field-control',
      value: String(rec.flatMapPage || 1),
      disabled: !flatSelect.value,
      onInput: () => {
        rec.flatMapPage = Math.max(1, Number.parseInt(pageInput.value, 10) || 1);
        markDirtyAndPersist();
      },
    });

    const panoCheckboxes = [];

    flatSelect.addEventListener('change', () => {
      rec.flatMapAttachmentId = flatSelect.value;
      pageInput.disabled = !flatSelect.value;
      pageInput.max = String(getSelectedFlatMaxPages());
      if (flatSelect.value) {
        // Mutual exclusion: selecting flat map unchecks panos
        rec.selectedPanos = [];
        panoCheckboxes.forEach(({ cb, labelInput }) => {
          cb.checked = false;
          labelInput.disabled = true;
        });
      }
      markDirtyAndPersist();
    });

    const panoListNode = readyPanos.length
      ? el(
        'div',
        { className: 'pano-check-list' },
        ...readyPanos.map((file) => {
          const existing = rec.selectedPanos.find((p) => p.attachmentId === file.id);
          const cb = el('input', { type: 'checkbox', checked: Boolean(existing) });
          const labelInput = el('input', {
            type: 'text',
            className: 'field-control',
            placeholder: '机位显示名称（可选，如 东门消防通道）',
            value: existing?.paragraph || '',
            disabled: !existing,
          });

          const syncPanos = () => {
            if (cb.checked) {
              if (rec.selectedPanos.length >= 30 && !rec.selectedPanos.some((p) => p.attachmentId === file.id)) {
                cb.checked = false;
                toast.warn('单个分项最多关联 30 个全景机位');
                return;
              }
              flatSelect.value = '';
              rec.flatMapAttachmentId = '';
              pageInput.disabled = true;
              const entry = rec.selectedPanos.find((p) => p.attachmentId === file.id);
              if (entry) entry.paragraph = labelInput.value;
              else rec.selectedPanos.push({ attachmentId: file.id, paragraph: labelInput.value });
            } else {
              rec.selectedPanos = rec.selectedPanos.filter((p) => p.attachmentId !== file.id);
            }
            labelInput.disabled = !cb.checked;
            markDirtyAndPersist();
          };

          cb.addEventListener('change', syncPanos);
          labelInput.addEventListener('input', () => {
            const entry = rec.selectedPanos.find((p) => p.attachmentId === file.id);
            if (entry) {
              entry.paragraph = labelInput.value;
              markDirtyAndPersist();
            }
          });
          panoCheckboxes.push({ cb, labelInput });

          return el(
            'div',
            { className: 'pano-check-row' },
            el('label', null, cb, el('span', null, file.filename)),
            labelInput,
          );
        }),
      )
      : el('span', { className: 'form-hint' }, '暂无已就绪的 360° 全景图，请先在上方上传素材。');

    return el(
      'div',
      { className: 'form-grid-2' },
      el('div', { className: 'form-field' }, el('label', { className: 'form-label' }, '关联平面地图'), flatSelect),
      el('div', { className: 'form-field' }, el('label', { className: 'form-label' }, '平面图页码'), pageInput),
      el('div', { className: 'form-field form-span-full' }, el('label', { className: 'form-label' }, '关联 360° 全景机位（勾选全景将自动取消平面图关联，最多 30 个）'), panoListNode),
    );
  }

  function renderRecordCard(rec, index) {
    const fieldKeys = getFieldsForRecord(schema, activeModule, rec.kind);
    const isRepeatable = !rec.kind || REPEATABLE_KINDS.has(rec.kind);
    const summaryTitleEl = el('strong', null, rec.title || `${activeOutline.label} #${index + 1}`);

    const titleInput = el('input', {
      type: 'text',
      className: 'field-control',
      maxLength: 160,
      value: rec.title,
      placeholder: rec.kind ? `填写${activeOutline.label}名称或标题` : '填写条目标题',
      onInput: () => {
        rec.title = titleInput.value;
        rec.isBlankTemplate = false;
        summaryTitleEl.textContent = rec.title.trim() || `${activeOutline.label} #${index + 1}`;
        markDirtyAndPersist();
      },
    });

    const fieldNodes = fieldKeys.map((fk) => {
      const label = getFieldLabel(schema, fk);
      const isLong = ['notes', 'processFlow', 'specialWarnings', 'useAndZones', 'responsibilities', 'response', 'risk', 'fixedFireFacilities', 'extinguishingAgents'].includes(fk);
      const ctrl = isLong
        ? el('textarea', {
          className: 'textarea-control',
          value: rec.fields[fk] || '',
          placeholder: `填写${label}（未知请留空）`,
          onInput: () => {
            rec.fields[fk] = ctrl.value;
            rec.isBlankTemplate = false;
            markDirtyAndPersist();
          },
        })
        : el('input', {
          type: 'text',
          className: 'field-control',
          value: rec.fields[fk] || '',
          placeholder: `填写${label}`,
          onInput: () => {
            rec.fields[fk] = ctrl.value;
            rec.isBlankTemplate = false;
            markDirtyAndPersist();
          },
        });
      return el(
        'div',
        { className: `form-field${isLong ? ' form-span-full' : ''}` },
        el('label', { className: 'form-label' }, label),
        ctrl,
      );
    });

    // CRITICAL P0-2 FIX: Always show body textarea for plans, and whenever body is non-empty on other modules
    const showBody = activeModule === 'plans' || Boolean(rec.body);
    let bodyField = null;
    if (showBody) {
      const bodyArea = el('textarea', {
        className: 'textarea-control',
        style: { minHeight: activeModule === 'plans' ? '140px' : '90px' },
        maxLength: 20000,
        value: rec.body || '',
        placeholder: activeModule === 'plans'
          ? '填写应急预案核心处置流程、力量编成、供水路线与现场注意事项（最多 20000 字）'
          : '补充正文内容（最多 20000 字）',
        onInput: () => {
          rec.body = bodyArea.value;
          rec.isBlankTemplate = false;
          markDirtyAndPersist();
        },
      });
      bodyField = el(
        'div',
        { className: 'form-field form-span-full' },
        el('label', { className: 'form-label' }, activeModule === 'plans' ? '应急预案正文内容' : '补充内容'),
        bodyArea,
      );
    }

    const removeBtn = isRepeatable
      ? el('button', {
        type: 'button',
        className: 'btn btn-danger-outline btn-xs',
        onClick: async (e) => {
          e.preventDefault();
          e.stopPropagation();
          const hasData = Boolean(rec.title.trim() || rec.body.trim() || Object.values(rec.fields).some((v) => String(v || '').trim()));
          if (hasData) {
            const ok = await confirmDialog({
              title: '移除此条目',
              message: `确认移除「${rec.title.trim() || activeOutline.label}」吗？保存草稿后生效。`,
              confirmText: '确认移除',
              danger: true,
            });
            if (!ok) return;
          }
          rec.removed = true;
          markDirtyAndPersist();
          renderRecordsArea();
        },
      }, '移除')
      : null;

    const cardBody = el(
      'div',
      { className: 'record-card-body' },
      el('div', { className: 'form-field' }, el('label', { className: 'form-label' }, '条目标题'), titleInput),
      fieldNodes.length ? el('div', { className: 'form-grid-2' }, ...fieldNodes) : null,
      bodyField,
      activeModule === 'maps' ? renderMapSourceSelector(rec) : null,
    );

    return el(
      'details',
      { className: 'record-card', open: true },
      el(
        'summary',
        { className: 'record-card-summary' },
        el(
          'div',
          { className: 'record-card-heading' },
          el('span', { className: 'pill pill-neutral' }, `#${index + 1}`),
          summaryTitleEl,
        ),
        removeBtn,
      ),
      cardBody,
    );
  }

  let addBtn = null;

  function renderRecordsArea() {
    const visible = getVisibleRecords();
    if (!visible.length) {
      recordsContainer.replaceChildren(
        el(
          'div',
          { className: 'empty-state' },
          el('strong', null, `暂无「${activeOutline.label}」条目`),
          el('span', null, '点击右上角按钮新增条目，录入完成后点击底部「保存草稿」'),
        ),
      );
    } else {
      recordsContainer.replaceChildren(...visible.map((rec, i) => renderRecordCard(rec, i)));
    }
    if (addBtn && activeKind && !REPEATABLE_KINDS.has(activeKind)) {
      addBtn.disabled = visible.length > 0;
    }
  }

  const canAdd = !activeKind || REPEATABLE_KINDS.has(activeKind);
  if (canAdd) {
    addBtn = el('button', {
      type: 'button',
      className: 'btn btn-secondary btn-sm',
      onClick: () => {
        allModuleRecords.push({
          kind: activeKind,
          title: '',
          defaultTitle: activeOutline.label,
          body: '',
          fields: {},
          originalSources: [],
          selectedPanos: [],
          flatMapAttachmentId: '',
          flatMapPage: 1,
          preservedSources: [],
          removed: false,
          isBlankTemplate: false,
        });
        markDirtyAndPersist();
        renderRecordsArea();
      },
    }, `+ 添加${activeOutline.label}`);
  }

  const sectionHelp = activeKind
    ? (schema?.kinds?.[activeKind]?.help || '')
    : (activeModule === 'maps'
      ? '为每个平面图或 360° 全景分组创建一条记录并关联已就绪素材。'
      : '可直接填写应急预案文本，或在上方上传 PDF/Word 预案原件。');

  const sectionCard = el(
    'section',
    { className: 'editor-section-card' },
    el(
      'div',
      { className: 'editor-section-head' },
      el('div', null, el('h3', null, activeOutline.label), sectionHelp ? el('p', { className: 'editor-section-help' }, sectionHelp) : null),
      addBtn,
    ),
    recordsContainer,
  );

  // Sticky Bottom Action Bar
  const stickyStatusEl = el('div', { className: 'sticky-action-status' });
  function updateStickyStatus() {
    stickyStatusEl.replaceChildren(
      isDirty
        ? el('span', { className: 'pill pill-caution' }, '有未保存更改（已自动暂存本会话）')
        : el('span', { className: 'pill pill-safe' }, '当前草稿已同步'),
      el('span', { className: 'muted', style: { fontSize: '12px' } }, '快捷键 Ctrl/Cmd + S 保存'),
    );
  }

  async function saveDraftAction({ reload = true } = {}) {
    const entries = serializeModuleEntries(activeModule, allModuleRecords);
    const { data } = await apiRequest(`/key-sites/${encodePath(site.id)}/draft`, {
      method: 'PUT',
      body: {
        revision: draft.revision,
        module: activeModule,
        entries,
      },
    });
    const nextRevision = data.draft?.revision ?? draft.revision + 1;
    clearLocalDraft(site.id, activeModule);
    setLocalDirty(false);
    updateStickyStatus();
    if (reload) {
      toast.success(`「${MODULE_META[activeModule]?.label}」草稿已保存（修订 #${nextRevision}）`);
      await onReloadSite(site.id, activeOutline.id);
    }
    return nextRevision;
  }

  const saveBtn = createAsyncButton('保存草稿', 'btn btn-primary btn-sm', async () => {
    try {
      await saveDraftAction();
    } catch (err) {
      toast.error(err?.message || '保存草稿失败');
    }
  });

  const discardBtn = createAsyncButton('放弃草稿', 'btn btn-subtle btn-sm', async () => {
    const ok = await confirmDialog({
      title: '放弃全部未发布草稿',
      message: '此操作将把草稿回退到最新已发布版本，所有尚未发布的改动都将丢失。确认放弃吗？',
      confirmText: '确认放弃',
      danger: true,
    });
    if (!ok) return;
    try {
      await apiRequest(`/key-sites/${encodePath(site.id)}/draft/discard`, {
        method: 'POST',
        body: { revision: draft.revision },
      });
      clearLocalDraft(site.id, activeModule);
      setLocalDirty(false);
      toast.success('已放弃未发布草稿');
      await onReloadSite(site.id, activeOutline.id);
    } catch (err) {
      toast.error(err?.message || '放弃草稿失败');
    }
  });

  const publishBtn = createAsyncButton('发布到 App', 'btn btn-secondary btn-sm', async () => {
    let targetRevision = draft.revision;
    if (isDirty) {
      const saveFirst = await confirmDialog({
        title: '发布前先保存当前修改',
        message: '您当前有未保存的编辑。是否先保存草稿并立即发布到 App 端？',
        confirmText: '保存并发布',
      });
      if (!saveFirst) return;
      try {
        targetRevision = await saveDraftAction({ reload: false });
      } catch (err) {
        toast.error(err?.message || '保存草稿失败，发布已取消');
        return;
      }
    } else {
      const ok = await confirmDialog({
        title: '发布重点单位资料到 App',
        message: `确认将「${site.name}」的当前草稿正式发布到移动端吗？发布后将生成新版本并记录审计日志。`,
        confirmText: '确认发布',
      });
      if (!ok) return;
    }

    try {
      const { data } = await apiRequest(`/key-sites/${encodePath(site.id)}/publish`, {
        method: 'POST',
        body: { revision: targetRevision },
      });
      toast.success(`已正式发布 v${data.version ?? ''} 到 App`);
      await onReloadSite(site.id, activeOutline.id);
    } catch (err) {
      toast.error(err?.message || '发布失败，请检查各分项关联附件与内容');
      if (targetRevision !== draft.revision) {
        await onReloadSite(site.id, activeOutline.id);
      }
    }
  });

  const stickyBar = el(
    'div',
    { className: 'sticky-action-bar' },
    stickyStatusEl,
    el('div', { className: 'sticky-action-buttons' }, discardBtn, publishBtn, saveBtn),
  );

  // Mount attachments panel for maps and plans modules
  const workspaceChildren = [];
  if (recoveryBanner) workspaceChildren.push(recoveryBanner);
  if (activeModule === 'maps' || activeModule === 'plans') {
    attachmentsPanel = createAttachmentsPanel({
      siteId: site.id,
      module: activeModule,
      limits,
      getAttachments: () => current.attachments || [],
      getTasks: () => current.tasks || [],
      onAssetsUpdated: (nextAttachments, nextTasks) => {
        const prevReadyCount = (current.attachments || []).filter((a) => a.status === 'ready').length;
        current.attachments = nextAttachments;
        current.tasks = nextTasks;
        const nextReadyCount = nextAttachments.filter((a) => a.status === 'ready').length;
        // Only refresh source selectors if a new attachment became ready and user isn't mid-edit
        if (activeModule === 'maps' && nextReadyCount !== prevReadyCount && !dirty) {
          renderRecordsArea();
        }
      },
    });
    workspaceChildren.push(attachmentsPanel.element);
  }
  workspaceChildren.push(sectionCard, stickyBar);

  renderRecordsArea();
  updateStickyStatus();

  const layout = el(
    'div',
    { className: 'editor-shell' },
    outlineEl,
    el('div', { className: 'editor-workspace' }, ...workspaceChildren),
  );

  root.replaceChildren(headerEl, layout);

  keydownHandler = (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
      e.preventDefault();
      saveBtn.click();
    }
  };
  window.addEventListener('keydown', keydownHandler);

  return {
    destroy() {
      attachmentsPanel?.destroy();
      if (keydownHandler) {
        window.removeEventListener('keydown', keydownHandler);
        keydownHandler = null;
      }
    },
  };
}
