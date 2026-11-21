import { $, createAsyncButton, debounce, el, encodePath, formatDate } from '../../core/dom.js';
import { apiRequest } from '../../core/api.js';
import { closeAllModals, confirmDialog, openModal } from '../../ui/modal.js';
import { toast } from '../../ui/toast.js';

const PAGE_SIZE = 50;

const CATEGORY_META = {
  hydrant: { label: '市政消火栓', pillClass: 'pill-info' },
  natural: { label: '天然水源', pillClass: 'pill-safe' },
  pump_connector: { label: '水泵接合器', pillClass: 'pill-caution' },
};

const STATUS_META = {
  available: { label: '可用', pillClass: 'pill-safe' },
  unavailable: { label: '不可用', pillClass: 'pill-danger' },
};

const INTAKE_METHODS = [
  { value: 'portable_pump', label: '手抬泵吸水' },
  { value: 'fire_truck', label: '消防车靠近取水' },
  { value: 'remote_supply', label: '远程供水系统直接取水' },
];

const INTAKE_LABEL_MAP = Object.fromEntries(INTAKE_METHODS.map((m) => [m.value, m.label]));

function labeledField(id, label, control, { required = false, spanFull = false, hint = '' } = {}) {
  if (id && control && !control.id) control.id = id;
  return el(
    'div',
    { className: `form-field${spanFull ? ' form-span-full' : ''}` },
    el(
      'label',
      { className: 'form-label', ...(id ? { for: id } : {}) },
      label,
      required ? el('span', { className: 'req' }, '*') : null,
    ),
    control,
    hint ? el('span', { className: 'form-hint' }, hint) : null,
  );
}

function formatCoord(value) {
  const num = Number(value);
  return Number.isFinite(num) ? num.toFixed(6) : '—';
}

export function createWaterSourcesView({ getMember }) {
  let mounted = false;
  let unitsLoaded = false;
  let selectedUnitId = '';
  let currentDeleted = 'none';
  let currentCategory = '';
  let currentStatus = '';
  let currentQuery = '';
  let currentPage = 0;
  let totalCount = 0;
  let loadSeq = 0;
  let loadAbort = null;

  let unitBar = null;
  let unitSelect = null;
  let statsContainer = null;
  let normalTabBtn = null;
  let trashTabBtn = null;
  let searchInput = null;
  let categorySelect = null;
  let statusSelect = null;
  let tableContainer = null;
  let paginationContainer = null;

  function isPlatformAdmin() {
    return getMember()?.admin_role === 'platform_admin';
  }

  function unitQuerySuffix() {
    if (isPlatformAdmin() && selectedUnitId) {
      return `?unit_id=${encodeURIComponent(selectedUnitId)}`;
    }
    return '';
  }

  const debouncedSearch = debounce(() => {
    currentPage = 0;
    loadList();
  }, 260);

  function updateModeTabs() {
    if (!normalTabBtn || !trashTabBtn) return;
    const isTrash = currentDeleted === 'only';
    normalTabBtn.classList.toggle('active', !isTrash);
    normalTabBtn.setAttribute('aria-pressed', String(!isTrash));
    trashTabBtn.classList.toggle('active', isTrash);
    trashTabBtn.setAttribute('aria-pressed', String(isTrash));
  }

  function renderSummary(summary) {
    if (!statsContainer) return;
    const s = summary || {};
    const byCat = s.by_category || {};
    const cards = [
      { label: '活跃水源总数', value: Number(s.total || 0), cls: '' },
      { label: '可用', value: Number(s.available || 0), cls: 'stat-safe' },
      { label: '不可用', value: Number(s.unavailable || 0), cls: 'stat-danger' },
      { label: '市政消火栓', value: Number(byCat.hydrant || 0), cls: 'stat-info' },
      { label: '天然水源', value: Number(byCat.natural || 0), cls: '' },
      { label: '水泵接合器', value: Number(byCat.pump_connector || 0), cls: '' },
    ];
    statsContainer.replaceChildren(
      ...cards.map((c) =>
        el(
          'div',
          { className: `water-stat-card${c.cls ? ` ${c.cls}` : ''}` },
          el('span', { className: 'water-stat-label' }, c.label),
          el('span', { className: 'water-stat-value' }, String(c.value)),
        ),
      ),
    );
  }

  function openWaterSourceModal(item = null) {
    const isEdit = Boolean(item?.id);
    const uid = `ws-${Date.now()}`;

    const nameInput = el('input', {
      type: 'text',
      className: 'field-control',
      required: true,
      maxlength: 120,
      value: item?.name || '',
      placeholder: '例如：示例路与兴业街交叉口市政消火栓',
    });

    const catSelect = el(
      'select',
      { className: 'select-control' },
      el('option', { value: 'hydrant' }, '市政消火栓'),
      el('option', { value: 'natural' }, '天然水源（含消防水池）'),
      el('option', { value: 'pump_connector' }, '水泵接合器'),
    );
    catSelect.value = item?.category || 'hydrant';

    const stSelect = el(
      'select',
      { className: 'select-control' },
      el('option', { value: 'available' }, '可用'),
      el('option', { value: 'unavailable' }, '不可用'),
    );
    stSelect.value = item?.status || 'available';

    const latInput = el('input', {
      type: 'number',
      className: 'field-control',
      required: true,
      step: 'any',
      min: 3,
      max: 55,
      value: item?.lat !== undefined && item?.lat !== null ? String(item.lat) : '',
      placeholder: '例如：30.123456',
    });

    const lngInput = el('input', {
      type: 'number',
      className: 'field-control',
      required: true,
      step: 'any',
      min: 73,
      max: 136,
      value: item?.lng !== undefined && item?.lng !== null ? String(item.lng) : '',
      placeholder: '例如：120.123456',
    });

    const initialMethods = new Set(Array.isArray(item?.intake_methods) ? item.intake_methods : []);
    const methodCheckboxes = INTAKE_METHODS.map((m) => {
      const cb = el('input', {
        type: 'checkbox',
        value: m.value,
        checked: initialMethods.has(m.value),
      });
      return {
        value: m.value,
        input: cb,
        node: el('label', { className: 'water-checkbox-item' }, cb, el('span', null, m.label)),
      };
    });

    const intakeField = el(
      'div',
      { className: 'form-field form-span-full', hidden: catSelect.value !== 'natural' },
      el('span', { className: 'form-label' }, '取水方式（天然水源至少选择 1 项）', el('span', { className: 'req' }, '*')),
      el('div', { className: 'water-checkbox-group' }, ...methodCheckboxes.map((m) => m.node)),
    );

    catSelect.addEventListener('change', () => {
      intakeField.hidden = catSelect.value !== 'natural';
    });

    const noteInput = el('textarea', {
      className: 'textarea-control',
      maxlength: 500,
      value: item?.note || '',
      placeholder: '例如：缺闷盖、水压偏低、消防水池容量 200m³ 或对应楼栋等',
    });

    const errorBanner = el('div', { className: 'inline-alert inline-alert-danger', role: 'alert', hidden: true });
    const submitBtn = el('button', { type: 'submit', className: 'btn btn-primary' }, isEdit ? '保存修改' : '确认新增');
    const cancelBtn = el('button', { type: 'button', className: 'btn btn-secondary' }, '取消');

    const body = el(
      'div',
      { className: 'modal-body' },
      errorBanner,
      el(
        'div',
        { className: 'form-grid-2' },
        labeledField(`${uid}-name`, '水源名称', nameInput, { required: true, spanFull: true }),
        labeledField(`${uid}-cat`, '水源类别', catSelect, { required: true }),
        labeledField(`${uid}-status`, '可用状态', stSelect, { required: true }),
        labeledField(`${uid}-lat`, 'GCJ-02 纬度 (lat)', latInput, { required: true, hint: '有效范围 3 ~ 55（火星坐标系）' }),
        labeledField(`${uid}-lng`, 'GCJ-02 经度 (lng)', lngInput, { required: true, hint: '有效范围 73 ~ 136（火星坐标系）' }),
        intakeField,
        labeledField(`${uid}-note`, '备注说明', noteInput, { spanFull: true, hint: '最多 500 字，如水压情况、缺件、水池容量或接口楼栋' }),
      ),
    );

    const footer = el('div', { className: 'modal-footer' }, cancelBtn, submitBtn);
    const form = el('form', null, body, footer);

    const modal = openModal({
      title: isEdit ? `编辑水源：${item.name}` : '新增水源点位',
      size: 'md',
      form,
    });

    cancelBtn.addEventListener('click', () => modal.close());

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const showError = (msg, focusEl) => {
        errorBanner.textContent = msg;
        errorBanner.hidden = false;
        focusEl?.focus();
      };

      const name = nameInput.value.trim();
      if (!name || name.length > 120) {
        showError('请填写 1~120 字的水源名称', nameInput);
        return;
      }

      const lat = Number(latInput.value);
      const lng = Number(lngInput.value);
      if (!Number.isFinite(lat) || lat < 3 || lat > 55) {
        showError('请输入有效的 GCJ-02 纬度（3 ~ 55）', latInput);
        return;
      }
      if (!Number.isFinite(lng) || lng < 73 || lng > 136) {
        showError('请输入有效的 GCJ-02 经度（73 ~ 136）', lngInput);
        return;
      }

      const category = catSelect.value;
      const intakeMethods = category === 'natural'
        ? methodCheckboxes.filter((m) => m.input.checked).map((m) => m.value)
        : [];

      if (category === 'natural' && intakeMethods.length === 0) {
        showError('天然水源请至少选择一种取水方式', methodCheckboxes[0].input);
        return;
      }

      const note = noteInput.value.trim();
      if (note.length > 500) {
        showError('备注长度不能超过 500 字', noteInput);
        return;
      }

      errorBanner.hidden = true;
      submitBtn.disabled = true;
      submitBtn.setAttribute('aria-busy', 'true');

      const payload = {
        category,
        name,
        lat,
        lng,
        status: stSelect.value,
        intake_methods: intakeMethods,
        note,
      };
      if (isPlatformAdmin() && selectedUnitId) {
        payload.unit_id = selectedUnitId;
      }

      try {
        if (isEdit) {
          await apiRequest(`/water-sources/${encodePath(item.id)}${unitQuerySuffix()}`, {
            method: 'PATCH',
            body: payload,
          });
          toast.success(`已更新「${name}」`);
        } else {
          await apiRequest(`/water-sources${unitQuerySuffix()}`, {
            method: 'POST',
            body: payload,
          });
          toast.success(`已新增「${name}」`);
        }
        modal.close();
        await loadList();
      } catch (err) {
        showError(err?.message || '保存失败，请检查输入后重试');
      } finally {
        submitBtn.disabled = false;
        submitBtn.removeAttribute('aria-busy');
      }
    });
  }

  async function handleDelete(item) {
    const confirmed = await confirmDialog({
      title: '确认删除水源点位',
      message: `确认将「${item.name}」移入回收站吗？移入后 App 端将隐藏该点位，后续可在回收站恢复。`,
      confirmText: '移入回收站',
      danger: true,
    });
    if (!confirmed) return false;
    try {
      await apiRequest(`/water-sources/${encodePath(item.id)}${unitQuerySuffix()}`, { method: 'DELETE' });
      toast.success(`已将「${item.name}」移入回收站`);
      await loadList();
      return true;
    } catch (err) {
      toast.error(err?.message || '删除失败');
      return false;
    }
  }

  async function handleRestore(item) {
    try {
      await apiRequest(`/water-sources/${encodePath(item.id)}/restore${unitQuerySuffix()}`, { method: 'POST' });
      toast.success(`已恢复「${item.name}」`);
      await loadList();
      return true;
    } catch (err) {
      toast.error(err?.message || '恢复失败');
      return false;
    }
  }

  function renderTable(items) {
    if (!tableContainer) return;
    const isTrash = currentDeleted === 'only';
    if (!items.length) {
      tableContainer.replaceChildren(
        el(
          'div',
          { className: 'empty-state' },
          el('strong', null, isTrash ? '回收站暂无已删除水源' : '未检索到匹配的水源点位'),
          el('span', null, isTrash ? '被软删除的水源点位会显示在此，可随时一键恢复' : '可调整筛选条件或点击右上角「+ 新增水源」录入'),
        ),
      );
      return;
    }

    const thead = el(
      'thead',
      null,
      el(
        'tr',
        null,
        el('th', null, '水源名称 / 备注'),
        el('th', null, '类别 / 取水方式'),
        el('th', null, '状态'),
        el('th', null, 'GCJ-02 坐标'),
        el('th', null, isTrash ? '删除记录' : '最近维护'),
        el('th', null, '操作'),
      ),
    );

    const tbody = el(
      'tbody',
      null,
      ...items.map((item) => {
        const catMeta = CATEGORY_META[item.category] || { label: item.category || '未知', pillClass: 'pill-neutral' };
        const statusMeta = STATUS_META[item.status] || { label: item.status || '未知', pillClass: 'pill-neutral' };
        const methods = Array.isArray(item.intake_methods) ? item.intake_methods : [];

        const actionNodes = isTrash
          ? [createAsyncButton('恢复', 'btn btn-primary btn-xs', () => handleRestore(item))]
          : [
              el('button', {
                type: 'button',
                className: 'btn btn-subtle btn-xs',
                onClick: () => openWaterSourceModal(item),
              }, '编辑'),
              createAsyncButton('删除', 'btn btn-danger-outline btn-xs', () => handleDelete(item)),
            ];

        const actorName = isTrash
          ? (item.deleted_by_name || item.deleted_by || '—')
          : (item.updated_by_name || item.created_by_name || '—');
        const actorTime = isTrash ? item.deleted_at : (item.updated_at || item.created_at);

        return el(
          'tr',
          null,
          el(
            'td',
            null,
            el(
              'div',
              { className: 'water-name-cell' },
              el(
                'div',
                { className: 'water-name-row' },
                el('span', { className: 'water-name-main' }, item.name || '—'),
                isTrash ? el('span', { className: 'pill pill-neutral' }, '已删除') : null,
              ),
              item.note
                ? el('span', { className: 'water-note-text' }, item.note)
                : el('span', { className: 'muted', style: { fontSize: '12px' } }, '无备注'),
            ),
          ),
          el(
            'td',
            null,
            el('span', { className: `pill ${catMeta.pillClass}` }, catMeta.label),
            item.category === 'natural' && methods.length
              ? el(
                  'div',
                  { className: 'water-intake-tags' },
                  ...methods.map((m) => el('span', { className: 'water-intake-tag' }, INTAKE_LABEL_MAP[m] || m)),
                )
              : null,
          ),
          el('td', null, el('span', { className: `pill ${statusMeta.pillClass}` }, statusMeta.label)),
          el(
            'td',
            { className: 'water-coord-cell' },
            el('div', null, `${formatCoord(item.lat)}, ${formatCoord(item.lng)}`),
          ),
          el(
            'td',
            null,
            el(
              'div',
              { className: 'water-meta-cell' },
              el('span', { className: 'water-meta-actor' }, actorName),
              el('span', { className: 'water-meta-time' }, formatDate(actorTime)),
            ),
          ),
          el('td', null, el('div', { className: 'table-actions' }, ...actionNodes)),
        );
      }),
    );

    tableContainer.replaceChildren(el('table', { className: 'data-table' }, thead, tbody));
  }

  function renderPagination() {
    if (!paginationContainer) return;
    const totalPages = Math.max(1, Math.ceil(totalCount / PAGE_SIZE));
    const prevBtn = el('button', {
      type: 'button',
      className: 'btn btn-secondary btn-sm',
      disabled: currentPage <= 0,
      onClick: () => {
        if (currentPage > 0) {
          currentPage -= 1;
          loadList();
        }
      },
    }, '上一页');

    const nextBtn = el('button', {
      type: 'button',
      className: 'btn btn-secondary btn-sm',
      disabled: currentPage + 1 >= totalPages,
      onClick: () => {
        if (currentPage + 1 < totalPages) {
          currentPage += 1;
          loadList();
        }
      },
    }, '下一页');

    const modeLabel = currentDeleted === 'only' ? '条回收站记录' : '条水源点位';
    paginationContainer.replaceChildren(
      el('span', { className: 'pagination-info' }, `共 ${totalCount} ${modeLabel} · 第 ${currentPage + 1} / ${totalPages} 页`),
      el('div', { className: 'pagination-controls' }, prevBtn, nextBtn),
    );
  }

  async function ensureUnits() {
    if (!unitBar || !unitSelect) return;
    if (!isPlatformAdmin()) {
      unitBar.hidden = true;
      selectedUnitId = '';
      return;
    }
    unitBar.hidden = false;
    if (unitsLoaded) {
      unitSelect.value = selectedUnitId;
      return;
    }
    try {
      const { data } = await apiRequest('/units');
      const units = Array.isArray(data.units) ? data.units : [];
      if (!selectedUnitId) {
        const ownUnitId = getMember()?.unit_id || '';
        const matched = units.find((u) => u.id === ownUnitId);
        selectedUnitId = matched ? matched.id : (units[0]?.id || ownUnitId);
      }
      unitSelect.replaceChildren(
        ...units.map((u) => el('option', { value: u.id }, u.name)),
      );
      if (selectedUnitId) {
        unitSelect.value = selectedUnitId;
      }
      unitsLoaded = true;
    } catch (err) {
      if (err?.name !== 'AbortError') {
        toast.error(err?.message || '大队列表加载失败');
      }
    }
  }

  async function loadList() {
    if (!tableContainer) return;
    const seq = ++loadSeq;
    loadAbort?.abort();
    loadAbort = new AbortController();

    tableContainer.replaceChildren(
      el(
        'div',
        { className: 'skeleton-list', style: { padding: '16px' } },
        el('div', { className: 'skeleton-bar' }),
        el('div', { className: 'skeleton-bar' }),
        el('div', { className: 'skeleton-bar' }),
      ),
    );

    const params = new URLSearchParams();
    params.set('limit', String(PAGE_SIZE));
    params.set('offset', String(currentPage * PAGE_SIZE));
    params.set('deleted', currentDeleted);
    if (isPlatformAdmin() && selectedUnitId) params.set('unit_id', selectedUnitId);
    if (currentCategory) params.set('category', currentCategory);
    if (currentStatus) params.set('status', currentStatus);
    if (currentQuery) params.set('q', currentQuery);

    try {
      const { data } = await apiRequest(`/water-sources?${params.toString()}`, { signal: loadAbort.signal });
      if (seq !== loadSeq) return;
      renderSummary(data.summary);
      totalCount = Number(data.total || 0);
      const maxPage = Math.max(0, Math.ceil(totalCount / PAGE_SIZE) - 1);
      if (currentPage > maxPage) {
        currentPage = maxPage;
        await loadList();
        return;
      }
      renderTable(data.items || []);
      renderPagination();
    } catch (err) {
      if (err?.name === 'AbortError' || seq !== loadSeq) return;
      tableContainer.replaceChildren(
        el(
          'div',
          { style: { padding: '16px' } },
          el('div', { className: 'inline-alert inline-alert-danger' }, err?.message || '水源列表加载失败'),
        ),
      );
      paginationContainer?.replaceChildren();
    }
  }

  function mount() {
    const root = $('water-source-manager');
    if (!root || mounted) return;
    mounted = true;

    unitSelect = el('select', {
      id: 'water-source-unit',
      className: 'select-control',
      'aria-label': '切换查看大队',
      onChange: () => {
        selectedUnitId = unitSelect.value;
        currentPage = 0;
        loadList();
      },
    });

    unitBar = el(
      'div',
      { className: 'water-unit-bar', hidden: !isPlatformAdmin() },
      el(
        'div',
        { className: 'water-unit-bar-left' },
        el('label', { className: 'inline-filter', for: 'water-source-unit' }, el('span', null, '当前管理大队'), unitSelect),
      ),
      el('span', { className: 'muted', style: { fontSize: '12px' } }, '平台管理员可按大队切换查看与维护水源台账'),
    );

    statsContainer = el('div', { className: 'water-stats-grid', 'aria-label': '水源统计概览' });
    renderSummary(null);

    normalTabBtn = el('button', {
      type: 'button',
      className: 'water-mode-tab active',
      'aria-pressed': 'true',
      onClick: () => {
        if (currentDeleted === 'none') return;
        currentDeleted = 'none';
        currentPage = 0;
        updateModeTabs();
        loadList();
      },
    }, '正常台账');

    trashTabBtn = el('button', {
      type: 'button',
      className: 'water-mode-tab',
      'aria-pressed': 'false',
      onClick: () => {
        if (currentDeleted === 'only') return;
        currentDeleted = 'only';
        currentPage = 0;
        updateModeTabs();
        loadList();
      },
    }, '回收站');

    searchInput = el('input', {
      type: 'search',
      className: 'field-control',
      placeholder: '搜索水源名称或备注…',
      value: currentQuery,
      onInput: () => {
        currentQuery = searchInput.value.trim();
        debouncedSearch();
      },
    });

    categorySelect = el(
      'select',
      {
        className: 'select-control',
        'aria-label': '按水源类别筛选',
        onChange: () => {
          currentCategory = categorySelect.value;
          currentPage = 0;
          loadList();
        },
      },
      el('option', { value: '' }, '全部类别'),
      el('option', { value: 'hydrant' }, '市政消火栓'),
      el('option', { value: 'natural' }, '天然水源'),
      el('option', { value: 'pump_connector' }, '水泵接合器'),
    );
    categorySelect.value = currentCategory;

    statusSelect = el(
      'select',
      {
        className: 'select-control',
        'aria-label': '按可用状态筛选',
        onChange: () => {
          currentStatus = statusSelect.value;
          currentPage = 0;
          loadList();
        },
      },
      el('option', { value: '' }, '全部状态'),
      el('option', { value: 'available' }, '可用'),
      el('option', { value: 'unavailable' }, '不可用'),
    );
    statusSelect.value = currentStatus;

    const addBtn = el('button', {
      type: 'button',
      className: 'btn btn-primary btn-sm',
      onClick: () => openWaterSourceModal(null),
    }, '+ 新增水源');

    const toolbar = el(
      'div',
      { className: 'toolbar-card' },
      el(
        'div',
        { className: 'filter-group' },
        el('div', { className: 'water-mode-tabs', role: 'group', 'aria-label': '台账视图切换' }, normalTabBtn, trashTabBtn),
        searchInput,
        categorySelect,
        statusSelect,
      ),
      el('div', { className: 'toolbar-actions' }, addBtn),
    );

    tableContainer = el('div', { className: 'data-table-container' });
    paginationContainer = el('div', { className: 'pagination-bar' });

    root.replaceChildren(unitBar, statsContainer, toolbar, tableContainer, paginationContainer);
  }

  async function activate() {
    mount();
    updateModeTabs();
    if (searchInput) searchInput.value = currentQuery;
    if (categorySelect) categorySelect.value = currentCategory;
    if (statusSelect) statusSelect.value = currentStatus;
    await ensureUnits();
    await loadList();
  }

  function reset() {
    debouncedSearch.cancel();
    loadAbort?.abort();
    loadSeq += 1;
    closeAllModals();
    mounted = false;
    unitsLoaded = false;
    selectedUnitId = '';
    currentDeleted = 'none';
    currentCategory = '';
    currentStatus = '';
    currentQuery = '';
    currentPage = 0;
    totalCount = 0;
    unitBar = null;
    unitSelect = null;
    statsContainer = null;
    normalTabBtn = null;
    trashTabBtn = null;
    searchInput = null;
    categorySelect = null;
    statusSelect = null;
    tableContainer = null;
    paginationContainer = null;
    $('water-source-manager')?.replaceChildren();
  }

  return {
    activate,
    reset,
  };
}
