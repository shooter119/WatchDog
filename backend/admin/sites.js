'use strict';
(() => {
  const labels = { maps: '地图', plans: '应急预案', cards: '作战信息卡', organization: '组织架构', hazards: '危险品' };
  let schema, fieldLabels = {}, fields = {};
  const recordFields = (module, kind) => kind ? schema.kinds[kind].fields : fields[module];
  const profileFields = { name: '重点单位名称', short_name: '简称', address: '地址', district: '辖区', site_type: '类型' };
  let member, units = [], limits, current, module = 'cards', offset = 0, dirty = false, query = {}, taskTimer;
  let manager;
  const node = (tag, text, className) => { const n = document.createElement(tag); if (text) n.textContent = text; if (className) n.className = className; return n; };
  const button = (text, action, className) => { const b = node('button', text, className); b.type = 'button'; b.onclick = () => Promise.resolve(action()).catch(report); return b; };
  const report = error => { $('error').textContent = error.message; $('error').scrollIntoView({ block: 'nearest' }); };
  const date = time => new Date(Number(time)).toLocaleString();
  function input(form, label, value = '', { multiline = false, required = false, type = 'text' } = {}) {
    const wrapper = node('label', label), field = node(multiline ? 'textarea' : 'input');
    field.value = value; field.required = required;
    if (!multiline) field.type = type;
    wrapper.append(field); form.append(wrapper); field.oninput = () => { dirty = true; };
    return field;
  }
  async function start(next) {
    if (member?.id === next.id) { member = next; return; }
    member = next;
    manager = $('site-manager');
    if (!manager) { manager = node('section'); manager.id = 'site-manager'; $('workspace').append(manager); }
    units = (await api('/units', undefined, 'GET')).units;
    const capabilities = await api('/key-sites/limits', undefined, 'GET');
    limits = capabilities.limits;
    schema = capabilities.schema; fieldLabels = schema.fieldLabels; fields = schema.legacyFields;
    const p = $('workspace').querySelector(':scope > p:last-of-type');
    if (p?.textContent.includes('随阶段')) p.remove();
    await list();
  }
  function mayLeave() {
    if (!dirty) return true;
    if (!confirm('有尚未保存的编辑，确认放弃本次未保存内容？')) return false;
    return true;
  }
  function updateSummary() {
    if (!current || !$('site-summary')) return;
    const { site, draft } = current;
    $('site-summary').textContent = `${site.address} · ${site.published_version ? `当前已发布 v${site.published_version}` : '尚未发布'} · 草稿更新 ${date(draft.updated_at)}`;
  }
  function standardGuide() {
    const guide = node('details', '', 'standard-guide');
    guide.append(node('summary', `${schema.name} · 查看字段与填写约定`));
    for (const rule of schema.rules) guide.append(node('p', rule));
    for (const spec of Object.values(schema.kinds)) {
      guide.append(node('h4', `${labels[spec.module]} / ${spec.label}`), node('p', spec.fields.map(key => fieldLabels[key]).join(' · ')), node('p', spec.help, 'muted'));
    }
    return guide;
  }
  async function list() {
    clearTimeout(taskTimer); current = null; dirty = false; manager.replaceChildren();
    const head = node('div', '', 'section-head'); head.append(node('h2', '重点单位档案'), button('新建重点单位', () => editProfile())); manager.append(head, standardGuide());
    const search = node('form', '', 'search-bar');
    const q = input(search, '搜索名称、简称或地址', query.q || '');
    const district = input(search, '辖区', query.district || '');
    const type = input(search, '类型', query.site_type || '');
    const submit = node('button', '查询'); submit.type = 'submit'; search.append(submit);
    search.onsubmit = event => { event.preventDefault(); query = { q: q.value, district: district.value, site_type: type.value }; offset = 0; dirty = false; list().catch(report); };
    manager.append(search);
    const result = await api(`/key-sites?${new URLSearchParams({ ...query, offset })}`, undefined, 'GET');
    const table = node('div', '', 'site-list'); manager.append(table);
    if (!result.sites.length) table.append(node('p', '暂无匹配单位。可新建档案，或调整搜索条件。', 'empty'));
    for (const site of result.sites) {
      const row = node('div', '', 'site-row');
      const info = node('div'); info.append(node('h3', site.name), node('p', site.address), node('small', `${site.district || '辖区未填'} · ${site.site_type || '类型未填'} · ${site.active ? '有效' : '已停用'} · ${site.published_version ? `已发布 v${site.published_version}` : '尚未发布'}`));
      row.append(info, button('维护资料', () => open(site.id))); table.append(row);
    }
    const pagination = node('div', '', 'actions');
    if (offset) pagination.append(button('上一页', () => { offset = Math.max(0, offset - 20); return list(); }));
    if (result.hasMore) pagination.append(button('下一页', () => { offset += 20; return list(); }));
    pagination.append(node('span', `第 ${Math.floor(offset / 20) + 1} 页`)); manager.append(pagination);
    dirty = false;
  }
  async function editProfile(site) {
    if (!mayLeave()) return;
    manager.replaceChildren(); const form = node('form', '', 'profile-form');
    form.append(node('h2', site ? '编辑单位档案' : '新建重点单位'));
    const controls = {};
    for (const [key, label] of Object.entries(profileFields)) controls[key] = input(form, label, site?.[key], { required: ['name','address'].includes(key) });
    const ownerLabel = node('label', '维护归属消防单位'), owner = node('select');
    for (const unit of units) { const option = node('option', unit.name); option.value = unit.id; owner.append(option); }
    owner.value = site?.owner_unit_id || member.unit_id; owner.disabled = member.admin_role !== 'platform_admin';
    owner.onchange = () => { dirty = true; };
    ownerLabel.append(owner); form.append(ownerLabel);
    const duplicates = node('div', '', 'notice'); form.append(duplicates);
    form.append(button('检查相似档案', async () => {
      const result = await api(`/key-sites/duplicates?${new URLSearchParams({ name: controls.name.value, address: controls.address.value })}`, undefined, 'GET');
      duplicates.replaceChildren(node('strong', '相似提示（由人工判断，不自动合并）'));
      for (const row of result.sites.filter(row => row.id !== site?.id)) duplicates.append(node('p', `${row.name} · ${row.address}`));
      if (!result.sites.length) duplicates.append(node('p', '未找到相似档案'));
    }));
    const submit = node('button', '保存档案', 'primary'); submit.type = 'submit'; form.append(submit, button('取消', () => { dirty = false; return site ? open(site.id) : list(); }));
    form.onsubmit = async event => {
      event.preventDefault();
      try {
        const body = Object.fromEntries(Object.entries(controls).map(([key, field]) => [key, field.value]));
        body.owner_unit_id = owner.value;
        if (site) body.revision = site.revision;
        const result = await api(site ? `/key-sites/${site.id}` : '/key-sites', body, site ? 'PUT' : 'POST');
        dirty = false; await open(result.id);
      } catch (error) { report(error); }
    };
    manager.append(form); dirty = false;
  }
  async function open(id) {
    if (!mayLeave()) return;
    clearTimeout(taskTimer); current = await api(`/key-sites/${id}`, undefined, 'GET'); dirty = false;
    manager.replaceChildren();
    const { site } = current;
    manager.append(button('← 返回单位列表', () => mayLeave() ? list() : undefined));
    const head = node('div', '', 'section-head'); head.append(node('h2', site.name), button('编辑档案', () => editProfile(site)), button(site.active ? '停用单位' : '恢复单位', async () => {
      if (!confirm(site.active ? '停用后不能新关联，历史警情仍保留引用版本。确认停用？' : '确认恢复此单位？')) return;
      await api(`/key-sites/${id}`, { ...site, active: !site.active }, 'PUT'); dirty = false; await open(id);
    })); const summary = node('p'); summary.id = 'site-summary'; manager.append(head, summary); updateSummary();
    const notice = node('div', '按分项表单填写后保存。草稿仅维护人员可见，发布后 App 中的已认证有效成员可查看。', 'notice'); manager.append(notice, standardGuide());
    const tabs = node('nav', '', 'module-tabs'); tabs.setAttribute('aria-label', '资料分类');
    for (const key of ['cards','maps','plans','organization','hazards']) tabs.append(button(labels[key], () => { if (mayLeave()) { module = key; renderModule(); dirty = false; } }, key === module ? 'active' : ''));
    manager.append(tabs); const content = node('div'); content.id = 'module-content'; manager.append(content);
    renderModule();
    const actions = node('div', '', 'publish-actions');
    actions.append(button('发布到 App', publish, 'primary'), button('放弃当前草稿', async () => {
      if (!confirm('将草稿恢复为最新已发布内容（尚未发布时清空）。已发布版本和地图文件保留，确认继续？')) return;
      await api(`/key-sites/${id}/draft/discard`, { revision: current.draft.revision }); dirty = false; await open(id);
    }), button('查看发布历史', history)); manager.append(actions);

  }
  const repeatable = new Set(['productionUnit', 'warehouseStock', 'storageTank', 'contact']);
  const multilineFields = new Set(['notes','useAndZones','firePumps','escapeRoutes','extinguishingAgents','processFlow','specialWarnings','confidentiality','risk','response','responsibilities','onsiteHydrants','municipalHydrants','naturalWater']);
  function renderModule() {
    const root = $('module-content'); root.replaceChildren();
    root.append(node('h3', labels[module]), node('p', '填写已掌握的信息，未知项留空；保存后点击「发布到 App」即可共享。', 'muted'));
    const form = node('form', '', 'standard-form'), sections = node('div'), records = [];
    form.append(sections);
    function addRecord(kind, existing) {
      const spec = schema.kinds[kind], keys = recordFields(module, kind);
      const entry = existing || { title: spec?.label || labels[module], body: '', fields: {}, sources: [] };
      const section = node('fieldset', '', 'form-section');
      section.append(node('legend', spec?.label || labels[module]));
      const controls = {}, titleLabel = repeatable.has(kind) ? `${spec.label}名称` : '分项名称';
      const title = input(section, titleLabel, entry.title, { required: true }); title.maxLength = 200;
      const grid = node('div', '', 'standard-fields'); section.append(grid);
      for (const key of keys) {
        controls[key] = input(grid, fieldLabels[key], entry.fields?.[key] || '', { multiline: multilineFields.has(key) });
        controls[key].maxLength = 5000;
      }
      let body;
      if (entry.body) body = input(section, '补充内容', entry.body, { multiline: true });
      const record = { kind, entry, title, controls, body, removed: false, existing: !!existing }; records.push(record);
      if (module === 'maps') {
        const label = node('label', '地图文件（选填）'), select = node('select');
        select.append(new Option('暂不关联地图文件', ''));
        for (const file of current.attachments.filter(file => file.status === 'ready' && file.metadata?.map)) select.append(new Option(file.filename, file.id));
        select.value = entry.sources?.[0]?.attachmentId || ''; select.onchange = () => { dirty = true; };
        label.append(select); section.append(label);
        record.file = select; record.page = input(section, '地图页码', entry.sources?.[0]?.page || 1, { type: 'number' }); record.page.min = '1'; record.page.max = String(limits.pages);
      }
      section.append(button('移除此分项', () => { record.removed = true; section.remove(); dirty = true; }));
      sections.append(section);
    }
    const existing = current.draft.content[module] || [];
    for (const [kind, spec] of Object.entries(schema.kinds).filter(([, spec]) => spec.module === module)) {
      const matched = existing.filter(entry => entry.kind === kind);
      if (matched.length) matched.forEach(entry => addRecord(kind, entry)); else addRecord(kind);
    }
    existing.filter(entry => !entry.kind).forEach(entry => addRecord('', entry));
    if (!Object.values(schema.kinds).some(spec => spec.module === module) && !existing.length) addRecord('');
    const add = node('div', '', 'record-tools');
    for (const [kind, spec] of Object.entries(schema.kinds).filter(([, spec]) => spec.module === module)) add.append(button(`＋ 添加${spec.label}`, () => { addRecord(kind); dirty = true; }));
    if (!Object.values(schema.kinds).some(spec => spec.module === module)) add.append(button(`＋ 添加${labels[module]}分项`, () => { addRecord(''); dirty = true; }));
    const submit = node('button', `保存${labels[module]}`, 'primary'); submit.type = 'submit';
    form.append(add, submit); root.append(form);
    form.onsubmit = async event => {
      event.preventDefault(); submit.disabled = true;
      try {
        const next = structuredClone(current.draft.content);
        next[module] = records.filter(record => !record.removed).flatMap(record => {
          const values = Object.fromEntries(Object.entries(record.controls).map(([key, control]) => [key, control.value.trim()]));
          const body = record.body?.value || '';
          const sources = record.file?.value ? [{ attachmentId: record.file.value, page: Number(record.page.value) || 1, paragraph: '' }] : [];
          if (!record.existing && !Object.values(values).some(Boolean) && !body && !sources.length && record.title.value === record.entry.title) return [];
          return [{ ...(record.kind ? { kind: record.kind } : {}), title: record.title.value.trim(), body, fields: values, sources }];
        });
        current.draft = await api(`/key-sites/${current.site.id}/draft`, { revision: current.draft.revision, content: next }, 'PUT');
        dirty = false; updateSummary(); $('error').textContent = '已保存。发布后 App 可查看。'; renderModule();
      } catch (error) { report(error); } finally { submit.disabled = false; }
    };
    if (module === 'maps') { const assets = node('div'); assets.id = 'assets'; root.append(assets); renderMapFiles(); }
    for (const b of manager.querySelectorAll('.module-tabs button')) b.classList.toggle('active', b.textContent === labels[module]);
  }
  function renderMapFiles() {
    const root = $('assets'); if (!root || !current) return;
    root.replaceChildren(node('h3', '地图文件（可选）'), node('p', '需要在 App 查看地图时，可上传 PDF、JPG 或 PNG，处理完成后在地图分项中选择文件和页码。选择文件后保存表单，再发布即可在 App 查看。', 'muted'));
    const upload = node('input'); upload.type = 'file'; upload.accept = '.pdf,.jpg,.jpeg,.png'; upload.setAttribute('aria-label', '选择地图文件'); root.append(upload);
    root.append(button('上传地图', async () => {
      if (dirty) throw new Error('请先保存表单，再上传地图');
      const file = upload.files[0]; if (!file) throw new Error('请先选择地图文件');
      if (file.size > limits.fileBytes) throw new Error('文件超过大小限制');
      const epoch = authGeneration, id = current.site.id, form = new FormData(); form.append('file', file);
      const response = await fetch(`/api/admin/key-sites/${id}/attachments/maps`, { method: 'POST', credentials: 'same-origin', headers: { 'X-CSRF-Token': csrf }, body: form });
      const result = await response.json();
      if (epoch !== authGeneration) throw new Error('后台会话已失效，请重新扫码登录');
      if (response.status === 401) endSession();
      if (!response.ok) throw new Error(result.error || '上传失败');
      if (!current || current.site.id !== id) return;
      $('error').textContent = '地图已上传，请刷新处理状态后选择地图文件。'; await refreshMapFiles();
    }), button('刷新地图处理状态', refreshMapFiles));
    for (const file of current.attachments.filter(file => file.module === 'maps')) root.append(node('p', `${file.filename} · ${{ queued: '排队中', processing: '处理中', ready: '可使用', failed: '处理失败' }[file.status] || file.status}`));
  }
  async function refreshMapFiles() {
    if (dirty) throw new Error('请先保存表单，再刷新地图文件');
    const id = current.site.id, result = await api(`/key-sites/${id}`, undefined, 'GET');
    if (!current || current.site.id !== id) return;
    current.attachments = result.attachments; current.tasks = result.tasks; renderModule();
  }
  async function publish() {
    if (dirty) throw new Error('请先保存当前表单，再发布');
    const target = { id: current.site.id, name: current.site.name, revision: current.draft.revision, profileRevision: current.site.revision };
    if (!confirm(`发布「${target.name}」到 App？发布后全平台已认证有效成员可查看，未发布的草稿不会展示。`)) return;
    const result = await api(`/key-sites/${target.id}/publish`, { revision: target.revision, profileRevision: target.profileRevision, confirmPlatformSharing: true });
    if (current?.site.id === target.id) await open(target.id);
    $('error').textContent = `${target.name} 已发布 v${result.version}，App 可查看。`;
  }
  async function history() {
    const result = await api(`/key-sites/${current.site.id}/history`, undefined, 'GET');
    const panel = node('section', '', 'history'); panel.append(node('h3', '发布历史'));
    for (const version of result.versions) {
      panel.append(node('p', `v${version.version} · ${version.profile.name} · ${date(version.published_at)} · 发布人 ${version.publisher_name || '维护人员'}`));
      panel.append(button('查看此版本内容', async () => {
        const saved = await api(`/key-sites/${current.site.id}/history/${version.version}`, undefined, 'GET');
        const preview = node('section', '', 'version-preview');
        preview.append(node('h3', `${saved.profile.name} · v${saved.version}（只读）`), node('p', saved.profile.address));
        for (const key of Object.keys(labels)) {
          preview.append(node('h4', labels[key]));
          if (!saved.content[key].length) preview.append(node('p', '暂无资料'));
          for (const entry of saved.content[key]) {
            preview.append(node('strong', entry.title), node('p', entry.body));
            for (const field of recordFields(key, entry.kind)) if (entry.fields[field]) preview.append(node('p', `${fieldLabels[field] || field}：${entry.fields[field]}`));
          }
        }
        panel.querySelector('.version-preview')?.remove(); panel.append(preview); preview.scrollIntoView({ block: 'nearest' });
      }));
    }
    if (!result.versions.length) panel.append(node('p', '暂无发布记录')); manager.querySelector('.history')?.remove(); manager.append(panel); panel.scrollIntoView({ block: 'nearest' });
  }
  document.addEventListener('admin-ready', event => start(event.detail).catch(report));
  document.addEventListener('admin-ended', () => { clearTimeout(taskTimer); member = null; current = null; dirty = false; });
  window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });
})();
