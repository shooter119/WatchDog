import { el, encodePath } from '../../core/dom.js';
import { apiRequest } from '../../core/api.js';
import { openModal } from '../../ui/modal.js';
import { createTagInput } from '../../ui/tag-input.js';
import { toast } from '../../ui/toast.js';

function labeledField(id, label, control, { required = false, spanFull = false, hint = '' } = {}) {
  control.id = id;
  return el(
    'div',
    { className: `form-field${spanFull ? ' form-span-full' : ''}` },
    el('label', { className: 'form-label', for: id }, label, required ? el('span', { className: 'req' }, '*') : null),
    control,
    hint ? el('span', { className: 'form-hint' }, hint) : null,
  );
}

export function openHazmatFormModal(item = null, { onSaved }) {
  const isEdit = Boolean(item?.id);
  const uid = `hm-${Date.now()}`;

  const nameCn = el('input', { type: 'text', className: 'field-control', required: true, value: item?.name_cn || '', placeholder: '例如：金属钠、苯、三氯甲烷' });
  const nameEn = el('input', { type: 'text', className: 'field-control', value: item?.name_en || '', placeholder: '例如：Sodium' });
  const unNum = el('input', { type: 'text', className: 'field-control', value: item?.un_number || '', placeholder: '4位数字，如 1428' });
  const casNum = el('input', { type: 'text', className: 'field-control', value: item?.cas_number || '', placeholder: '如 7440-23-5' });
  const dangerCategory = el('input', { type: 'text', className: 'field-control', value: item?.danger_category || '', placeholder: '如 第4.3项 遇水放出易燃气体的物质' });

  const signColor = el(
    'select',
    { className: 'select-control' },
    el('option', { value: '' }, '自动按危险类别推断'),
    el('option', { value: 'red' }, '红色（易燃）'),
    el('option', { value: 'blue' }, '蓝色（遇水/遇湿）'),
    el('option', { value: 'yellow' }, '黄色（氧化/过氧化物）'),
    el('option', { value: 'white' }, '白色（毒性气体/毒害品）'),
    el('option', { value: 'black_white' }, '黑白（腐蚀品）'),
  );
  signColor.value = item?.danger_sign_color || '';

  const waterReactivity = el(
    'select',
    { className: 'select-control' },
    el('option', { value: 'normal' }, '常规（可用水/雾状水）'),
    el('option', { value: 'reactive' }, '遇水剧烈反应（谨慎用水）'),
    el('option', { value: 'forbidden' }, '严禁用水（遇水燃爆/剧毒）'),
  );
  waterReactivity.value = item?.water_reactivity || 'normal';

  const tagInput = createTagInput({ initialTags: item?.aliases || [] });

  const dangerSummary = el('textarea', { className: 'textarea-control', value: item?.danger_summary || '', placeholder: '概括燃烧、爆炸、毒性或反应风险' });
  const forbiddenAgents = el('textarea', { className: 'textarea-control', value: item?.forbidden_agents || '', placeholder: '例如：严禁用水、泡沫、二氧化碳灭火剂' });
  const extinguishingAgents = el('textarea', { className: 'textarea-control', value: item?.extinguishing_agents || '', placeholder: '例如：干砂、D类金属专用干粉、石墨粉' });
  const firefightingTips = el('textarea', { className: 'textarea-control', value: item?.firefighting_tips || '', placeholder: '上风向站位、冷却保护、次生毒气防范等战术要点' });
  const protectiveLevel = el('input', { type: 'text', className: 'field-control', value: item?.protective_level || '', placeholder: '例如：正压式空呼 + 一级防化服' });
  const isolationDistance = el('input', { type: 'text', className: 'field-control', value: item?.isolation_distance || '', placeholder: '例如：初期隔离 100m，大火下风向疏散 800m' });
  const leakHandling = el('textarea', { className: 'textarea-control', value: item?.leak_handling || '', placeholder: '泄漏堵漏、围堰、吸附及排污要求' });
  const firstAid = el('textarea', { className: 'textarea-control', value: item?.first_aid || '', placeholder: '皮肤/眼部/吸入接触急救与洗消说明' });
  const appearance = el('input', { type: 'text', className: 'field-control', value: item?.appearance || '', placeholder: '颜色、物态、气味特征' });
  const flashPoint = el('input', { type: 'text', className: 'field-control', value: item?.flash_point || '', placeholder: '例如：-11°C 或 不燃' });
  const explosionLimit = el('input', { type: 'text', className: 'field-control', value: item?.explosion_limit || '', placeholder: '例如：1.2% - 7.5%' });
  const vaporDensity = el('input', { type: 'text', className: 'field-control', value: item?.vapor_density || '', placeholder: '相对空气密度，如 4.12（重于空气）' });
  const notes = el('textarea', { className: 'textarea-control', value: item?.notes || '', placeholder: '储存条件或其他补充注意事项' });

  const errorBanner = el('div', { className: 'inline-alert inline-alert-danger', role: 'alert', hidden: true });
  const submitBtn = el('button', { type: 'submit', className: 'btn btn-primary' }, isEdit ? '保存修改' : '确认录入');
  const cancelBtn = el('button', { type: 'button', className: 'btn btn-secondary' }, '取消');

  const body = el(
    'div',
    { className: 'modal-body' },
    errorBanner,
    el(
      'div',
      { className: 'form-grid-2' },
      labeledField(`${uid}-name-cn`, '中文品名', nameCn, { required: true }),
      labeledField(`${uid}-name-en`, '英文名称', nameEn),
      labeledField(`${uid}-un`, 'UN 编号', unNum),
      labeledField(`${uid}-cas`, 'CAS 编号', casNum),
      labeledField(`${uid}-cat`, '危险性类别', dangerCategory),
      labeledField(`${uid}-color`, '危险色标', signColor, { hint: '留空时将按危险性类别自动推断' }),
      labeledField(`${uid}-water`, '水反应性等级', waterReactivity, { spanFull: true }),
      el(
        'div',
        { className: 'form-field form-span-full' },
        el('span', { className: 'form-label' }, '别名 / 俗名 / 商品名'),
        tagInput.element,
      ),
      labeledField(`${uid}-summary`, '核心风险概述', dangerSummary, { spanFull: true }),
      labeledField(`${uid}-forbid`, '禁用灭火剂', forbiddenAgents, { spanFull: true }),
      labeledField(`${uid}-ext`, '推荐灭火剂', extinguishingAgents, { spanFull: true }),
      labeledField(`${uid}-tips`, '扑救战术要点', firefightingTips, { spanFull: true }),
      labeledField(`${uid}-protect`, '防护等级', protectiveLevel),
      labeledField(`${uid}-iso`, '隔离 / 疏散距离', isolationDistance),
      labeledField(`${uid}-leak`, '泄漏处置', leakHandling, { spanFull: true }),
      labeledField(`${uid}-aid`, '急救与洗消措施', firstAid, { spanFull: true }),
      labeledField(`${uid}-app`, '外观与气味', appearance, { spanFull: true }),
      labeledField(`${uid}-flash`, '闪点 / 自燃点', flashPoint),
      labeledField(`${uid}-exp`, '爆炸极限', explosionLimit),
      labeledField(`${uid}-vapor`, '相对蒸气密度', vaporDensity, { spanFull: true }),
      labeledField(`${uid}-notes`, '补充备注', notes, { spanFull: true }),
    ),
  );

  const footer = el('div', { className: 'modal-footer' }, cancelBtn, submitBtn);
  const form = el('form', null, body, footer);

  const modal = openModal({
    title: isEdit ? `编辑危化品：${item.name_cn}` : '新增危化品记录',
    size: 'lg',
    form,
  });

  cancelBtn.addEventListener('click', () => modal.close());

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const trimmedName = nameCn.value.trim();
    if (!trimmedName) {
      errorBanner.textContent = '请填写危化品中文品名';
      errorBanner.hidden = false;
      nameCn.focus();
      return;
    }

    errorBanner.hidden = true;
    submitBtn.disabled = true;
    submitBtn.setAttribute('aria-busy', 'true');

    const payload = {
      name_cn: trimmedName,
      name_en: nameEn.value.trim(),
      aliases: tagInput.getTags(),
      un_number: unNum.value.trim(),
      cas_number: casNum.value.trim(),
      danger_category: dangerCategory.value.trim(),
      water_reactivity: waterReactivity.value,
      danger_summary: dangerSummary.value.trim(),
      forbidden_agents: forbiddenAgents.value.trim(),
      extinguishing_agents: extinguishingAgents.value.trim(),
      firefighting_tips: firefightingTips.value.trim(),
      protective_level: protectiveLevel.value.trim(),
      isolation_distance: isolationDistance.value.trim(),
      leak_handling: leakHandling.value.trim(),
      first_aid: firstAid.value.trim(),
      appearance: appearance.value.trim(),
      flash_point: flashPoint.value.trim(),
      explosion_limit: explosionLimit.value.trim(),
      vapor_density: vaporDensity.value.trim(),
      notes: notes.value.trim(),
    };
    if (signColor.value) {
      payload.danger_sign_color = signColor.value;
    } else if (isEdit) {
      payload.danger_sign_color = '';
    }

    try {
      if (isEdit) {
        await apiRequest(`/hazmats/${encodePath(item.id)}`, { method: 'PUT', body: payload });
        toast.success(`已更新「${trimmedName}」`);
      } else {
        await apiRequest('/hazmats', { method: 'POST', body: payload });
        toast.success(`已录入「${trimmedName}」`);
      }
      modal.close();
      await onSaved?.();
    } catch (err) {
      errorBanner.textContent = err?.message || '保存失败，请检查输入后重试';
      errorBanner.hidden = false;
    } finally {
      submitBtn.disabled = false;
      submitBtn.removeAttribute('aria-busy');
    }
  });

  return modal;
}
