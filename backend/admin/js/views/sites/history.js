import { createAsyncButton, el, encodePath, formatDate } from '../../core/dom.js';
import { apiRequest } from '../../core/api.js';
import { openModal } from '../../ui/modal.js';
import { getFieldLabel, MODULE_META } from './model.js';

export async function openSiteHistoryModal({ site, schema }) {
  const container = el('div', { className: 'history-list' }, el('div', { className: 'skeleton-bar' }));
  const previewBox = el('div', { className: 'version-preview', hidden: true });

  const abort = new AbortController();
  const modal = openModal({
    title: `发布历史 · ${site.name}`,
    size: 'lg',
    body: [container, previewBox],
    footer: [
      el('button', { type: 'button', className: 'btn btn-secondary', onClick: () => modal.close() }, '关闭'),
    ],
    onClose: () => abort.abort(),
  });

  try {
    const { data } = await apiRequest(`/key-sites/${encodePath(site.id)}/history`, { signal: abort.signal });
    const versions = data.versions || [];
    if (!versions.length) {
      container.replaceChildren(
        el('div', { className: 'empty-state' }, el('strong', null, '暂无已发布版本'), el('span', null, '点击编辑器底部的「发布到 App」后将生成正式版本记录')),
      );
      return;
    }

    container.replaceChildren(
      ...versions.map((ver) => {
        const viewBtn = createAsyncButton('查看版本快照', 'btn btn-secondary btn-xs', async () => {
          try {
            const { data: detail } = await apiRequest(
              `/key-sites/${encodePath(site.id)}/history/${encodePath(ver.version)}`,
              { signal: abort.signal },
            );
            renderVersionPreview(previewBox, detail, schema);
          } catch (err) {
            if (err?.name === 'AbortError') return;
            previewBox.hidden = false;
            previewBox.replaceChildren(el('div', { className: 'inline-alert inline-alert-danger' }, err?.message || '版本快照加载失败'));
          }
        });

        return el(
          'div',
          { className: 'history-item' },
          el(
            'div',
            null,
            el('div', { style: { display: 'flex', alignItems: 'center', gap: '8px' } }, el('strong', null, `正式版本 v${ver.version}`), ver.summary ? el('span', { className: 'pill pill-neutral' }, ver.summary) : null),
            el('div', { className: 'muted', style: { fontSize: '12px', marginTop: '4px' } }, `发布时间：${formatDate(ver.published_at)}`),
          ),
          viewBtn,
        );
      }),
    );
  } catch (err) {
    if (err?.name === 'AbortError') return;
    container.replaceChildren(el('div', { className: 'inline-alert inline-alert-danger' }, err?.message || '历史版本加载失败'));
  }
}

function renderVersionPreview(box, detail, schema) {
  const saved = detail.version || detail;
  const content = saved.content && typeof saved.content === 'object' ? saved.content : {};
  const blocks = [
    el('h4', null, `只读版本快照 · v${saved.version ?? '—'}（发布于 ${formatDate(saved.published_at)}）`),
  ];

  for (const [modKey, meta] of Object.entries(MODULE_META)) {
    const entries = Array.isArray(content[modKey]) ? content[modKey] : [];
    if (!entries.length) continue;
    const entryNodes = entries.map((entry) => {
      const kindLabel = entry.kind && schema?.kinds?.[entry.kind]?.label ? `[${schema.kinds[entry.kind].label}] ` : '';
      const fieldPairs = Object.entries(entry.fields || {})
        .filter(([, v]) => String(v ?? '').trim())
        .map(([k, v]) => el('div', { className: 'muted', style: { fontSize: '12px' } }, `${getFieldLabel(schema, k)}：${v}`));
      return el(
        'div',
        { style: { padding: '8px 10px', borderRadius: '8px', background: 'var(--surface-muted)', border: '1px solid var(--border-subtle)' } },
        el('strong', { style: { fontSize: '13px' } }, `${kindLabel}${entry.title || '未命名条目'}`),
        entry.body ? el('p', { style: { fontSize: '12px', marginTop: '4px', whiteSpace: 'pre-wrap' } }, entry.body) : null,
        ...fieldPairs,
      );
    });
    blocks.push(
      el('div', { style: { display: 'flex', flexDirection: 'column', gap: '6px' } }, el('strong', { style: { fontSize: '13px' } }, `${meta.label}（${entries.length}项）`), ...entryNodes),
    );
  }

  box.hidden = false;
  box.replaceChildren(...blocks);
  box.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}
