import { el, formatDate } from '../../core/dom.js';

export function renderSitesListView({
  root,
  query,
  sites,
  hasMore,
  offset,
  limit,
  loading,
  error,
  panoFocusMode,
  onSearch,
  onResetFilters,
  onCreate,
  onOpenDetail,
  onOpenPano,
  onEditProfile,
  onPageChange,
}) {
  // Non-dirty search inputs (never triggers form dirty state!)
  const qInput = el('input', {
    type: 'search',
    className: 'field-control',
    placeholder: '单位名称、简称或地址…',
    value: query.q || '',
  });
  const districtInput = el('input', {
    type: 'text',
    className: 'field-control',
    placeholder: '行政区划 / 辖区',
    value: query.district || '',
  });
  const typeInput = el('input', {
    type: 'text',
    className: 'field-control',
    placeholder: '单位类型（如 化工、商业综合体）',
    value: query.site_type || '',
  });

  const submitSearch = (e) => {
    e?.preventDefault();
    onSearch({
      q: qInput.value.trim(),
      district: districtInput.value.trim(),
      site_type: typeInput.value.trim(),
    });
  };

  const searchForm = el(
    'form',
    { className: 'toolbar-card', onSubmit: submitSearch },
    el(
      'div',
      { className: 'filter-group' },
      qInput,
      districtInput,
      typeInput,
      el('button', { type: 'submit', className: 'btn btn-secondary btn-sm' }, '查询'),
      (query.q || query.district || query.site_type)
        ? el('button', { type: 'button', className: 'btn btn-subtle btn-sm', onClick: onResetFilters }, '清空')
        : null,
    ),
    el(
      'div',
      { className: 'toolbar-actions' },
      el('button', { type: 'button', className: 'btn btn-primary btn-sm', onClick: onCreate }, '+ 新建重点单位'),
    ),
  );

  const nodes = [];
  if (panoFocusMode) {
    nodes.push(
      el(
        'div',
        { className: 'inline-alert inline-alert-info', style: { marginBottom: '16px' } },
        el('span', null, '360° 全景漫游入口：请选择下方重点单位进入「地图与 360° 全景」面板上传、管理或全屏预览全景机位。'),
      ),
    );
  }
  nodes.push(searchForm);

  if (loading) {
    nodes.push(
      el('div', { className: 'skeleton-list' }, el('div', { className: 'skeleton-bar' }), el('div', { className: 'skeleton-bar' }), el('div', { className: 'skeleton-bar' })),
    );
    root.replaceChildren(...nodes);
    return;
  }

  if (error) {
    nodes.push(el('div', { className: 'inline-alert inline-alert-danger' }, error));
    root.replaceChildren(...nodes);
    return;
  }

  if (!sites.length) {
    nodes.push(
      el(
        'div',
        { className: 'card empty-state' },
        el('strong', null, '暂无符合条件的重点单位'),
        el('span', null, '可调整筛选条件，或点击右上角「新建重点单位」建档'),
      ),
    );
    root.replaceChildren(...nodes);
    return;
  }

  const listEl = el(
    'div',
    { className: 'site-list' },
    ...sites.map((site) => {
      const badges = [
        site.active
          ? el('span', { className: 'pill pill-safe' }, '启用中')
          : el('span', { className: 'pill pill-danger' }, '已停用'),
        site.published_version
          ? el('span', { className: 'pill pill-info' }, `已发布 v${site.published_version}`)
          : el('span', { className: 'pill pill-caution' }, '未发布'),
      ];

      const metaItems = [
        site.address || '未填写地址',
        site.district ? `辖区：${site.district}` : null,
        site.site_type ? `类型：${site.site_type}` : null,
        `更新于 ${formatDate(site.updated_at)}`,
      ].filter(Boolean);

      return el(
        'article',
        { className: 'site-row' },
        el(
          'div',
          { className: 'site-row-main' },
          el('div', { className: 'site-row-title' }, el('strong', null, site.name || '未命名单位'), ...badges),
          el('div', { className: 'site-row-meta' }, ...metaItems.map((m) => el('span', null, m))),
        ),
        el(
          'div',
          { className: 'site-row-actions' },
          panoFocusMode
            ? el('button', { type: 'button', className: 'btn btn-primary btn-sm', onClick: () => onOpenPano(site.id) }, '管理 360° 全景')
            : el('button', { type: 'button', className: 'btn btn-primary btn-sm', onClick: () => onOpenDetail(site.id) }, '维护九大分项'),
          !panoFocusMode
            ? el('button', { type: 'button', className: 'btn btn-secondary btn-sm', onClick: () => onOpenPano(site.id) }, '360° 全景')
            : null,
          el('button', { type: 'button', className: 'btn btn-subtle btn-sm', onClick: () => onEditProfile(site) }, '编辑档案'),
        ),
      );
    }),
  );

  nodes.push(listEl);

  const pageSize = Number(limit) || 20;
  const pageNum = Math.floor(offset / pageSize) + 1;
  nodes.push(
    el(
      'div',
      { className: 'pagination-bar' },
      el('span', { className: 'pagination-info' }, `当前第 ${pageNum} 页 · 本页展示 ${sites.length} 条`),
      el(
        'div',
        { className: 'pagination-controls' },
        el('button', {
          type: 'button',
          className: 'btn btn-secondary btn-sm',
          disabled: offset <= 0,
          onClick: () => onPageChange(Math.max(0, offset - pageSize)),
        }, '上一页'),
        el('button', {
          type: 'button',
          className: 'btn btn-secondary btn-sm',
          disabled: !hasMore,
          onClick: () => onPageChange(offset + pageSize),
        }, '下一页'),
      ),
    ),
  );

  root.replaceChildren(...nodes);
}
