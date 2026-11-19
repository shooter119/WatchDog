import { createAsyncButton, el, encodePath } from '../../core/dom.js';
import { apiRequest } from '../../core/api.js';
import { toast } from '../../ui/toast.js';
import { sanitizeSiteProfilePayload } from './model.js';

export function renderSiteProfileView({
  root,
  site,
  units,
  member,
  onMarkDirty,
  onSaved,
  onCancel,
  onOpenExisting,
}) {
  const isEdit = Boolean(site?.id);
  const uid = `site-prof-${Date.now()}`;

  const nameInput = el('input', {
    id: `${uid}-name`,
    type: 'text',
    className: 'field-control',
    required: true,
    maxLength: 160,
    value: site?.name || '',
    placeholder: '填写重点单位法定全称（最多 160 字）',
    onInput: onMarkDirty,
  });
  const shortNameInput = el('input', {
    id: `${uid}-short`,
    type: 'text',
    className: 'field-control',
    maxLength: 80,
    value: site?.short_name || '',
    placeholder: '常用简称（最多 80 字）',
    onInput: onMarkDirty,
  });
  const addressInput = el('input', {
    id: `${uid}-addr`,
    type: 'text',
    className: 'field-control',
    maxLength: 500,
    value: site?.address || '',
    placeholder: '详细地址（最多 500 字）',
    onInput: onMarkDirty,
  });
  const districtInput = el('input', {
    id: `${uid}-district`,
    type: 'text',
    className: 'field-control',
    maxLength: 120,
    value: site?.district || '',
    placeholder: '所属行政区或辖区（最多 120 字）',
    onInput: onMarkDirty,
  });
  const typeInput = el('input', {
    id: `${uid}-type`,
    type: 'text',
    className: 'field-control',
    maxLength: 80,
    value: site?.site_type || '',
    placeholder: '例如：石油化工、高层建筑、商业综合体',
    onInput: onMarkDirty,
  });

  let unitSelect = null;
  if (member?.admin_role === 'platform_admin' && units.length > 0) {
    unitSelect = el(
      'select',
      { id: `${uid}-unit`, className: 'select-control', onChange: onMarkDirty },
      ...units.map((u) => el('option', { value: u.id }, u.name)),
    );
    unitSelect.value = site?.owner_unit_id || member.unit_id || units[0]?.id || '';
  }

  const dupBox = el('div', { className: 'inline-alert inline-alert-info', hidden: true });
  const errorBox = el('div', { className: 'inline-alert inline-alert-danger', role: 'alert', hidden: true });

  const dupBtn = createAsyncButton('检查相似档案', 'btn btn-secondary btn-sm', async () => {
    const trimmedName = nameInput.value.trim();
    if (!trimmedName) {
      toast.warn('请先输入单位名称后再检查相似档案');
      nameInput.focus();
      return;
    }
    try {
      const qs = new URLSearchParams({ name: trimmedName });
      if (addressInput.value.trim()) qs.set('address', addressInput.value.trim());
      const { data } = await apiRequest(`/key-sites/duplicates?${qs.toString()}`);
      const matches = (data.sites || []).filter((row) => row.id !== site?.id);
      dupBox.hidden = false;
      if (!matches.length) {
        dupBox.className = 'inline-alert inline-alert-safe';
        dupBox.replaceChildren(el('span', null, '未找到相似档案，可以放心保存。'));
        return;
      }
      dupBox.className = 'inline-alert inline-alert-caution';
      dupBox.replaceChildren(
        el(
          'div',
          { style: { width: '100%' } },
          el('strong', null, `发现 ${matches.length} 条相似重点单位档案，请核对是否重复建档：`),
          el(
            'div',
            { className: 'dup-list' },
            ...matches.map((m) => el(
              'div',
              { className: 'dup-item' },
              el('span', null, `${m.name}${m.address ? ` · ${m.address}` : ''}`),
              el('button', {
                type: 'button',
                className: 'btn btn-secondary btn-xs',
                onClick: () => onOpenExisting(m.id),
              }, '打开该档案'),
            )),
          ),
        ),
      );
    } catch (err) {
      toast.error(err?.message || '查重失败');
    }
  });

  const submitBtn = el('button', { type: 'submit', className: 'btn btn-primary' }, isEdit ? '保存档案信息' : '创建重点单位');

  const form = el(
    'form',
    {
      className: 'card profile-form-card',
      style: { display: 'flex', flexDirection: 'column', gap: '16px' },
      onSubmit: async (e) => {
        e.preventDefault();
        const trimmedName = nameInput.value.trim();
        if (!trimmedName) {
          errorBox.textContent = '单位名称不能为空';
          errorBox.hidden = false;
          nameInput.focus();
          return;
        }
        errorBox.hidden = true;
        submitBtn.disabled = true;
        submitBtn.setAttribute('aria-busy', 'true');

        const payload = sanitizeSiteProfilePayload(site, {
          name: trimmedName,
          short_name: shortNameInput.value.trim(),
          address: addressInput.value.trim(),
          district: districtInput.value.trim(),
          site_type: typeInput.value.trim(),
          owner_unit_id: unitSelect ? unitSelect.value : (site?.owner_unit_id || member?.unit_id),
        });

        try {
          const { data } = isEdit
            ? await apiRequest(`/key-sites/${encodePath(site.id)}`, { method: 'PUT', body: payload })
            : await apiRequest('/key-sites', { method: 'POST', body: payload });
          const targetId = data.site?.id || data.id || site?.id;
          toast.success(isEdit ? '重点单位档案已保存' : '重点单位已创建');
          await onSaved(targetId);
        } catch (err) {
          errorBox.textContent = err?.message || '保存档案失败';
          errorBox.hidden = false;
        } finally {
          submitBtn.disabled = false;
          submitBtn.removeAttribute('aria-busy');
        }
      },
    },
    el(
      'div',
      { className: 'section-head' },
      el(
        'div',
        null,
        el('h2', null, isEdit ? `编辑档案：${site.name}` : '新建重点单位档案'),
        el('p', { className: 'muted' }, '先维护单位基础档案，保存后即可录入九大标准分项、平面图、360° 全景与应急预案。'),
      ),
      el('button', { type: 'button', className: 'btn btn-subtle btn-sm', onClick: onCancel }, '返回'),
    ),
    errorBox,
    el(
      'div',
      { className: 'form-grid-2' },
      el('div', { className: 'form-field form-span-full' }, el('label', { className: 'form-label', for: `${uid}-name` }, '单位全称', el('span', { className: 'req' }, '*')), nameInput),
      el('div', { className: 'form-field' }, el('label', { className: 'form-label', for: `${uid}-short` }, '单位简称'), shortNameInput),
      el('div', { className: 'form-field' }, el('label', { className: 'form-label', for: `${uid}-type` }, '单位类型'), typeInput),
      el('div', { className: 'form-field form-span-full' }, el('label', { className: 'form-label', for: `${uid}-addr` }, '单位地址'), addressInput),
      el('div', { className: 'form-field' }, el('label', { className: 'form-label', for: `${uid}-district` }, '行政区划 / 辖区'), districtInput),
      unitSelect
        ? el('div', { className: 'form-field' }, el('label', { className: 'form-label', for: `${uid}-unit` }, '归属消防单位'), unitSelect)
        : null,
    ),
    dupBox,
    el(
      'div',
      { style: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '10px', flexWrap: 'wrap', paddingTop: '8px', borderTop: '1px solid var(--border-subtle)' } },
      dupBtn,
      el(
        'div',
        { className: 'toolbar-actions' },
        el('button', { type: 'button', className: 'btn btn-secondary', onClick: onCancel }, '取消'),
        submitBtn,
      ),
    ),
  );

  root.replaceChildren(form);
}
