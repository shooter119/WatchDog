import { $, createAsyncButton, debounce, el, encodePath } from '../../core/dom.js';
import { apiDownload, apiRequest } from '../../core/api.js';
import { confirmDialog, closeAllModals } from '../../ui/modal.js';
import { closeDrawer } from '../../ui/drawer.js';
import { toast } from '../../ui/toast.js';
import { openHazmatDrawer, signColorClass, waterReactivityMeta } from './drawer.js';
import { openHazmatFormModal } from './form-modal.js';
import { openHazmatImportModal } from './import-modal.js';
import { computeRiskPopoverPosition, shouldOpenDrawerFromRowClick } from './table-helpers.js';

export { computeRiskPopoverPosition, shouldOpenDrawerFromRowClick };

const PAGE_SIZE = 20;

export function createHazmatsView() {
  let mounted = false;
  let currentQuery = '';
  let currentCategory = '';
  let currentWater = '';
  let currentPage = 0;
  let totalCount = 0;
  let loadSeq = 0;
  let loadAbort = null;
  let activePopover = null;
  let scrollCleanupBound = false;

  let searchInput = null;
  let waterSelect = null;
  let categorySelect = null;
  let tableContainer = null;
  let paginationContainer = null;

  function hideRiskPopover() {
    if (activePopover) {
      activePopover.remove();
      activePopover = null;
    }
  }

  function showRiskPopover(anchorEl, text) {
    const clean = String(text || '').trim();
    if (!clean || !anchorEl || typeof document === 'undefined') return;
    hideRiskPopover();
    const overlayRoot = $('overlay-root') || document.body;
    const popover = el('div', { className: 'hazmat-risk-popover', role: 'tooltip' }, clean);
    popover.style.visibility = 'hidden';
    overlayRoot.appendChild(popover);

    const anchorRect = anchorEl.getBoundingClientRect();
    const popoverRect = popover.getBoundingClientRect();
    const pos = computeRiskPopoverPosition(
      anchorRect,
      { width: popoverRect.width, height: popoverRect.height },
      { width: window.innerWidth, height: window.innerHeight },
    );
    popover.style.left = `${pos.left}px`;
    popover.style.top = `${pos.top}px`;
    popover.style.visibility = 'visible';
    activePopover = popover;
  }

  const debouncedSearch = debounce(() => {
    currentPage = 0;
    loadList();
  }, 260);

  function mount() {
    const root = $('hazmat-manager');
    if (!root || mounted) return;
    mounted = true;
    if (!scrollCleanupBound && typeof window !== 'undefined') {
      window.addEventListener('scroll', hideRiskPopover, true);
      window.addEventListener('resize', hideRiskPopover);
      scrollCleanupBound = true;
    }

    searchInput = el('input', {
      type: 'search',
      className: 'field-control',
      placeholder: '搜索中文名、英文名、俗名、UN 或 CAS 号…',
      value: currentQuery,
      onInput: () => {
        currentQuery = searchInput.value.trim();
        debouncedSearch();
      },
    });

    waterSelect = el(
      'select',
      {
        className: 'select-control',
        'aria-label': '按水反应性筛选',
        onChange: () => {
          currentWater = waterSelect.value;
          currentPage = 0;
          loadList();
        },
      },
      el('option', { value: '' }, '全部水反应性'),
      el('option', { value: 'forbidden' }, '严禁用水'),
      el('option', { value: 'reactive' }, '遇水剧烈反应'),
      el('option', { value: 'normal' }, '常规水反应性'),
    );
    waterSelect.value = currentWater;

    categorySelect = el(
      'select',
      {
        className: 'select-control',
        'aria-label': '按危险性类别筛选',
        onChange: () => {
          currentCategory = categorySelect.value;
          currentPage = 0;
          loadList();
        },
      },
      el('option', { value: '' }, '全部危险类别'),
      el('option', { value: '2.1' }, '2.1 易燃气体'),
      el('option', { value: '2.3' }, '2.3 有毒气体'),
      el('option', { value: '3' }, '第3类 易燃液体'),
      el('option', { value: '4.3' }, '4.3 遇水放易燃气体'),
      el('option', { value: '5' }, '第5类 氧化性物质'),
      el('option', { value: '6' }, '第6类 毒性物质'),
      el('option', { value: '8' }, '第8类 腐蚀品'),
    );
    categorySelect.value = currentCategory;

    const addBtn = el('button', {
      type: 'button',
      className: 'btn btn-primary btn-sm',
      onClick: () => openHazmatFormModal(null, { onSaved: () => loadList() }),
    }, '+ 手工录入');

    const importBtn = el('button', {
      type: 'button',
      className: 'btn btn-secondary btn-sm',
      onClick: () => openHazmatImportModal({ onImported: () => loadList() }),
    }, '批量导入');

    const templateBtn = createAsyncButton('下载模板', 'btn btn-subtle btn-sm', async () => {
      try {
        await apiDownload('/hazmats/template?format=xlsx', 'hazmat_template.xlsx');
      } catch (err) {
        toast.error(err?.message || '模板下载失败');
      }
    });

    const toolbar = el(
      'div',
      { className: 'toolbar-card' },
      el('div', { className: 'filter-group' }, searchInput, waterSelect, categorySelect),
      el('div', { className: 'toolbar-actions' }, templateBtn, importBtn, addBtn),
    );

    tableContainer = el('div', { className: 'data-table-container' });
    paginationContainer = el('div', { className: 'pagination-bar' });

    root.replaceChildren(toolbar, tableContainer, paginationContainer);
  }

  async function handleDelete(item) {
    const confirmed = await confirmDialog({
      title: '确认删除危化品',
      message: `确认将「${item.name_cn}」从速查库中移除吗？移除后 App 端增量同步将同步下线该记录。`,
      confirmText: '确认删除',
      danger: true,
    });
    if (!confirmed) return false;
    try {
      await apiRequest(`/hazmats/${encodePath(item.id)}`, { method: 'DELETE' });
      toast.success(`已删除「${item.name_cn}」`);
      await loadList();
      return true;
    } catch (err) {
      toast.error(err?.message || '删除失败');
      return false;
    }
  }

  function renderTable(items) {
    if (!tableContainer) return;
    hideRiskPopover();
    if (!items.length) {
      tableContainer.replaceChildren(
        el(
          'div',
          { className: 'empty-state' },
          el('strong', null, '未检索到匹配的危化品记录'),
          el('span', null, '可清空筛选条件、手工录入或通过 Excel/CSV 批量导入'),
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
        el('th', { className: 'col-name' }, '危化品名称 / 别名'),
        el('th', { className: 'col-un-cas' }, 'UN / CAS'),
        el('th', { className: 'col-category' }, '危险类别'),
        el('th', { className: 'col-water' }, '水反应性'),
        el('th', { className: 'col-risk' }, '核心风险'),
        el('th', { className: 'col-actions' }, '操作'),
      ),
    );

    const openDrawerFor = (item) => openHazmatDrawer(item, {
      onEdit: (target) => openHazmatFormModal(target, { onSaved: () => loadList() }),
      onDelete: handleDelete,
    });

    const tbody = el(
      'tbody',
      null,
      ...items.map((item) => {
        const water = waterReactivityMeta(item.water_reactivity);
        const aliases = Array.isArray(item.aliases) ? item.aliases : [];
        const aliasNodes = [];
        if (item.matched_alias) {
          aliasNodes.push(el('span', { className: 'alias-hit-tag' }, `命中别名：${item.matched_alias}`));
        }
        aliases.filter((a) => a !== item.matched_alias).slice(0, 3).forEach((a) => {
          aliasNodes.push(el('span', { className: 'alias-tag' }, a));
        });
        if (aliases.length > 3) {
          aliasNodes.push(el('span', { className: 'alias-tag' }, `+${aliases.length - 3}`));
        }

        const viewBtn = el('button', {
          type: 'button',
          className: 'btn btn-secondary btn-xs',
          onClick: () => openDrawerFor(item),
        }, '处置卡');

        const editBtn = el('button', {
          type: 'button',
          className: 'btn btn-subtle btn-xs',
          onClick: () => openHazmatFormModal(item, { onSaved: () => loadList() }),
        }, '编辑');

        const delBtn = createAsyncButton('删除', 'btn btn-danger-outline btn-xs', () => handleDelete(item));

        const riskSummaryText = String(item.danger_summary || '').trim();
        const riskNode = riskSummaryText
          ? el('div', {
              className: 'hazmat-risk-summary',
              tabIndex: 0,
              onMouseEnter: (ev) => showRiskPopover(ev.currentTarget, riskSummaryText),
              onMouseLeave: hideRiskPopover,
              onFocus: (ev) => showRiskPopover(ev.currentTarget, riskSummaryText),
              onBlur: hideRiskPopover,
            }, riskSummaryText)
          : el('span', { className: 'muted' }, '未录入');

        return el(
          'tr',
          {
            className: 'hazmat-row',
            onClick: (ev) => {
              if (!shouldOpenDrawerFromRowClick(ev)) return;
              hideRiskPopover();
              openDrawerFor(item);
            },
          },
          el(
            'td',
            { className: 'col-name' },
            el(
              'div',
              { className: 'hazmat-name-cell' },
              el('span', { className: 'hazmat-name-main' }, item.name_cn || '—'),
              item.name_en ? el('span', { className: 'hazmat-name-sub', title: item.name_en }, item.name_en) : null,
              aliasNodes.length ? el('div', { className: 'alias-badges' }, ...aliasNodes) : null,
            ),
          ),
          el(
            'td',
            { className: 'mono col-un-cas' },
            el('div', null, item.un_number ? `UN ${item.un_number}` : '—'),
            item.cas_number ? el('div', { className: 'muted', style: { fontSize: '12px' } }, item.cas_number) : null,
          ),
          el(
            'td',
            { className: 'col-category' },
            item.danger_category
              ? el('span', { className: `pill hazmat-category-pill ${signColorClass(item.danger_sign_color)}` }, item.danger_category)
              : el('span', { className: 'muted' }, '未标注'),
          ),
          el('td', { className: 'col-water' }, el('span', { className: `pill ${water.pillClass}` }, water.label)),
          el('td', { className: 'col-risk' }, riskNode),
          el('td', { className: 'col-actions' }, el('div', { className: 'table-actions' }, viewBtn, editBtn, delBtn)),
        );
      }),
    );

    tableContainer.replaceChildren(el('table', { className: 'data-table hazmat-table' }, thead, tbody));
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

    paginationContainer.replaceChildren(
      el('span', { className: 'pagination-info' }, `共 ${totalCount} 条危化品 · 第 ${currentPage + 1} / ${totalPages} 页`),
      el('div', { className: 'pagination-controls' }, prevBtn, nextBtn),
    );
  }

  async function loadList() {
    if (!tableContainer) return;
    hideRiskPopover();
    const seq = ++loadSeq;
    loadAbort?.abort();
    loadAbort = new AbortController();

    tableContainer.replaceChildren(
      el('div', { className: 'skeleton-list', style: { padding: '16px' } }, el('div', { className: 'skeleton-bar' }), el('div', { className: 'skeleton-bar' }), el('div', { className: 'skeleton-bar' })),
    );

    const params = new URLSearchParams();
    params.set('limit', String(PAGE_SIZE));
    params.set('offset', String(currentPage * PAGE_SIZE));
    if (currentQuery) params.set('q', currentQuery);
    if (currentCategory) params.set('category', currentCategory);
    if (currentWater) params.set('water', currentWater);

    try {
      const { data } = await apiRequest(`/hazmats?${params.toString()}`, { signal: loadAbort.signal });
      if (seq !== loadSeq) return;
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
          el('div', { className: 'inline-alert inline-alert-danger' }, err?.message || '危化品列表加载失败'),
        ),
      );
      paginationContainer?.replaceChildren();
    }
  }

  async function activate() {
    mount();
    if (searchInput) searchInput.value = currentQuery;
    if (waterSelect) waterSelect.value = currentWater;
    if (categorySelect) categorySelect.value = currentCategory;
    await loadList();
  }

  function reset() {
    debouncedSearch.cancel();
    loadAbort?.abort();
    loadSeq += 1;
    hideRiskPopover();
    if (scrollCleanupBound && typeof window !== 'undefined') {
      window.removeEventListener('scroll', hideRiskPopover, true);
      window.removeEventListener('resize', hideRiskPopover);
      scrollCleanupBound = false;
    }
    closeDrawer();
    closeAllModals();
    mounted = false;
    currentQuery = '';
    currentCategory = '';
    currentWater = '';
    currentPage = 0;
    totalCount = 0;
    searchInput = null;
    waterSelect = null;
    categorySelect = null;
    tableContainer = null;
    paginationContainer = null;
    $('hazmat-manager')?.replaceChildren();
  }

  return {
    activate,
    reset,
  };
}
