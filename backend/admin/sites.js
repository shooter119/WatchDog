'use strict';
(() => {
  const labels = { maps: '地图', plans: '应急预案', cards: '作战信息卡', organization: '组织架构', hazards: '危险品' };
  const fieldLabels = { capturedAt: '拍摄日期', versionLabel: '地图版本', area: '区域', scope: '适用范围', risk: '风险', keyLocations: '重点部位', access: '通行条件', water: '水源', response: '处置信息', parent: '上级组织或岗位', position: '岗位', contact: '联系人', phone: '联系方式', responsibilities: '岗位职责', location: '存放位置', quantity: '数量（含单位）', storage: '存放条件', notes: '待核对事项或补充说明' };
  const fields = { maps: ['capturedAt','versionLabel','area'], plans: ['scope'], cards: ['risk','keyLocations','access','water','response'], organization: ['parent','position','contact','phone','responsibilities'], hazards: ['location','quantity','risk','storage','notes'] };
  const profileFields = { name: '重点单位名称', short_name: '简称', address: '地址', district: '辖区', site_type: '类型' };
  const taskErrors = { KEY_SITE_INTERRUPTED: '处理进程中断，可重试', KEY_SITE_CONVERTER_UNAVAILABLE: '服务器文档转换组件暂不可用', KEY_SITE_PROCESS_TIMEOUT: '处理超时，请缩小文件后重试', KEY_SITE_CONVERT_FAILED: '文件损坏、加密或无法转换', KEY_SITE_PAGE_LIMIT: '文档页数超过限制', KEY_SITE_ENCRYPTED: '不支持加密PDF', KEY_SITE_QUOTA_EXCEEDED: '处理结果超过资料存储配额', KEY_SITE_PROCESS_FAILED: '文件处理失败，请重试' };
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
  function link(text, url) { const a = node('a', text); a.href = url; a.target = '_blank'; a.rel = 'noopener'; return a; }
  async function start(next) {
    if (member?.id === next.id) { member = next; return; }
    member = next;
    manager = $('site-manager');
    if (!manager) { manager = node('section'); manager.id = 'site-manager'; $('workspace').append(manager); }
    units = (await api('/units', undefined, 'GET')).units;
    limits = (await api('/key-sites/limits', undefined, 'GET')).limits;
    const p = $('workspace').querySelector(':scope > p:last-of-type');
    if (p?.textContent.includes('随阶段')) p.remove();
    await list();
  }
  function mayLeave() { return !dirty || confirm('有尚未保存的编辑，确认放弃本次未保存内容？'); }
  async function list() {
    clearTimeout(taskTimer); current = null; dirty = false; manager.replaceChildren();
    const head = node('div', '', 'section-head'); head.append(node('h2', '重点单位档案'), button('新建重点单位', () => editProfile())); manager.append(head);
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
    })); manager.append(head, node('p', `${site.address} · ${site.published_version ? `当前已发布 v${site.published_version}` : '尚未发布'} · 草稿更新 ${date(current.draft.updated_at)}`));
    const notice = node('div', '草稿仅维护人员可见。请逐项核对原件；主动发布后，全平台已认证有效成员均可查阅。', 'notice'); manager.append(notice);
    const tabs = node('nav', '', 'module-tabs'); tabs.setAttribute('aria-label', '资料分类');
    for (const key of ['cards','maps','plans','organization','hazards']) tabs.append(button(labels[key], () => { if (mayLeave()) { module = key; renderModule(); dirty = false; } }, key === module ? 'active' : ''));
    manager.append(tabs); const content = node('div'); content.id = 'module-content'; manager.append(content);
    renderModule();
    const actions = node('div', '', 'publish-actions');
    actions.append(button('核对并发布新版本', publish, 'primary'), button('放弃当前草稿', async () => {
      if (!confirm('将草稿恢复为最新已发布内容（尚未发布时清空）。已发布版本和来源附件保留，确认继续？')) return;
      await api(`/key-sites/${id}/draft/discard`, { revision: current.draft.revision }); dirty = false; await open(id);
    }), button('查看发布历史', history)); manager.append(actions);
    await refreshAssets();
  }
  function renderModule() {
    const root = $('module-content'); root.replaceChildren(node('h3', labels[module]));
    root.append(button('添加资料条目', () => editEntry()));
    const entries = current.draft.content[module] || [];
    if (!entries.length) root.append(node('p', '暂无资料', 'empty'));
    entries.forEach((entry, index) => {
      const card = node('article', '', 'entry-card'); card.append(node('h3', entry.title), node('p', entry.body));
      for (const [key, value] of Object.entries(entry.fields || {})) if (value) card.append(node('p', `${fieldLabels[key]}：${value}`));
      for (const source of entry.sources) {
        const file = current.attachments.find(file => file.id === source.attachmentId);
        if (file) card.append(link(`查看出处：${file.filename}${source.page ? ` · 第${source.page}页` : ''}`, `/api/admin/key-sites/${current.site.id}/attachments/${file.id}/${file.mime.startsWith('image/') ? `pages/${source.page || 1}.jpg` : `document.pdf#page=${source.page || 1}`}`));
      }
      card.append(node('div', '', 'actions')); const actions = card.lastChild;
      actions.append(button('编辑', () => editEntry(index)), button('移出草稿', async () => {
        if (!confirm(`确认将“${entry.title}”移出草稿？已发布版本不受影响。`)) return;
        const next = structuredClone(current.draft.content); next[module].splice(index, 1); await save(next); renderModule();
      })); root.append(card);
    });
    const editor = node('div'); editor.id = 'entry-editor'; root.append(editor);
    const assets = node('div'); assets.id = 'assets'; root.append(assets); renderAssets();
    for (const b of manager.querySelectorAll('.module-tabs button')) b.classList.toggle('active', b.textContent === labels[module]);
  }
  async function save(content) {
    current.draft = await api(`/key-sites/${current.site.id}/draft`, { revision: current.draft.revision, content }, 'PUT');
    dirty = false; $('error').textContent = '草稿已保存，尚未发布';
  }
  function editEntry(index) {
    if (!mayLeave()) return;
    const entry = index === undefined ? { title: '', body: '', fields: {}, sources: [] } : current.draft.content[module][index];
    const root = $('entry-editor'); root.replaceChildren(); const form = node('form', '', 'entry-form');
    form.append(node('h3', index === undefined ? `添加${labels[module]}` : `编辑${labels[module]}`));
    const title = input(form, module === 'hazards' ? '危险品名称' : module === 'organization' ? '组织或岗位名称' : '标题', entry.title, { required: true });
    const body = input(form, module === 'plans' ? '预案正文（可按章节分条录入，标题组成目录）' : '正文或补充说明', entry.body, { multiline: true });
    const controls = {};
    for (const key of fields[module]) controls[key] = input(form, fieldLabels[key], entry.fields[key] || '', { multiline: ['response','responsibilities','risk','notes'].includes(key) });
    form.append(node('h4', '原文出处')); const sourceRoot = node('div'), sources = []; form.append(sourceRoot);
    const addSource = (source = {}) => {
      const line = node('div', '', 'source-row'), select = node('select'); select.setAttribute('aria-label', '来源附件');
      const empty = node('option', '选择已上传附件'); empty.value = ''; select.append(empty);
      for (const file of current.attachments.filter(file => file.module === module && file.status === 'ready')) { const option = node('option', file.filename); option.value = file.id; select.append(option); }
      select.value = source.attachmentId || ''; const page = input(line, '页码', source.page || '', { type: 'number' }); page.min = '1'; page.max = '200';
      select.onchange = () => { dirty = true; }; page.max = String(limits.pages);
      const paragraph = input(line, '段落或说明', source.paragraph || ''); line.prepend(select); sourceRoot.append(line);
      const item = { select, page, paragraph, removed: false }; sources.push(item);
      line.append(button('移除出处', () => { item.removed = true; line.remove(); dirty = true; }));
    };
    entry.sources.forEach(addSource); form.append(button('添加出处', () => { addSource(); dirty = true; }));
    const submit = node('button', '保存草稿条目', 'primary'); submit.type = 'submit'; form.append(submit, button('取消编辑', () => { dirty = false; root.replaceChildren(); }));
    form.onsubmit = async event => {
      event.preventDefault();
      try {
        const next = structuredClone(current.draft.content), edited = { title: title.value, body: body.value, fields: Object.fromEntries(Object.entries(controls).map(([key, control]) => [key, control.value])), sources: sources.filter(item => !item.removed && item.select.value).map(item => ({ attachmentId: item.select.value, page: item.page.value ? Number(item.page.value) : null, paragraph: item.paragraph.value })) };
        if (index === undefined) next[module].push(edited); else next[module][index] = edited;
        await save(next); renderModule();
      } catch (error) { report(error); }
    };
    root.append(form); root.scrollIntoView({ block: 'start', behavior: 'smooth' }); dirty = false;
  }
  function renderAssets() {
    const root = $('assets'); if (!root || !current) return;
    const existingUpload = root.querySelector('input[type="file"]');
    root.replaceChildren(node('h3', '来源附件与处理任务'));
    root.append(node('p', `支持PDF、DOCX、JPG、PNG；单文件不超过${limits.fileBytes / 1024 / 1024}MB，最多${limits.pages}页，图片不超过${limits.pixels / 1000000}百万像素；每消防单位存储上限${limits.quotaBytes / 1024 ** 3}GB。多页地图按来源页码分别查看。`, 'muted'));
    const upload = existingUpload || node('input'); upload.type = 'file'; upload.accept = '.pdf,.docx,.jpg,.jpeg,.png'; upload.setAttribute('aria-label', `上传${labels[module]}来源附件`); root.append(upload);
    root.append(button('上传并处理', async () => {
      const file = upload.files[0]; if (!file) throw new Error('请先选择文件');
      if (file.size > limits.fileBytes) throw new Error('文件超过大小限制');
      const epoch = authGeneration, siteId = current.site.id;
      const form = new FormData(); form.append('file', file);
      const response = await fetch(`/api/admin/key-sites/${siteId}/attachments/${module}`, { method: 'POST', credentials: 'same-origin', headers: { 'X-CSRF-Token': csrf }, body: form });
      const result = await response.json();
      if (epoch !== authGeneration) throw new Error('后台会话已失效，请重新扫码登录');
      if (response.status === 401) endSession();
      if (!response.ok) throw new Error(result.error || '上传失败');
      if (!current || current.site.id !== siteId) return;
      $('error').textContent = '上传成功，后台处理中；处理完成后可在条目中添加出处。'; await refreshAssets();
    }), button('刷新处理状态', refreshAssets));
    const statuses = { queued: '排队中', processing: '处理中', ready: '可核对', failed: '处理失败', succeeded: '处理完成', cancelled: '已放弃' };
    for (const file of current.attachments.filter(file => file.module === module)) {
      const row = node('div', '', 'asset-row'); row.append(node('strong', file.filename), node('span', statuses[file.status] || file.status));
      if (file.status === 'ready') row.append(link('阅读', `/api/admin/key-sites/${current.site.id}/attachments/${file.id}/${file.mime.startsWith('image/') ? 'pages/1.jpg' : 'document.pdf'}`));
      row.append(link('下载原件', `/api/admin/key-sites/${current.site.id}/attachments/${file.id}/source`));
      const task = current.tasks.find(task => task.attachment_id === file.id && task.kind !== 'ai');
      if (task?.status === 'failed') row.append(node('span', `失败原因：${taskErrors[task.error_code] || '文件处理失败，请重试或联系维护人员'}`), button('重试', async () => { await api(`/key-sites/tasks/${task.id}/retry`, {}); await refreshAssets(); }));
      root.append(row);
    }
  }
  async function refreshAssets(poll = false) {
    if (!current) return;
    const id = current.site.id, result = await api(`/key-sites/${id}`, undefined, 'GET', poll);
    if (!current || current.site.id !== id) return;
    current.attachments = result.attachments; current.tasks = result.tasks; renderAssets();
    clearTimeout(taskTimer);
    if (result.tasks.some(task => ['queued','processing'].includes(task.status))) taskTimer = setTimeout(() => refreshAssets(true).catch(report), 4000);
  }
  async function publish() {
    if (dirty) throw new Error('请先保存当前正在编辑的条目，再核对发布');
    if (!confirm('请确认所有资料及出处已人工核对。本次资料和引用附件将向全平台已认证有效成员开放查阅。确认发布新版本？')) return;
    const result = await api(`/key-sites/${current.site.id}/publish`, { revision: current.draft.revision, profileRevision: current.site.revision, confirmPlatformSharing: true });
    $('error').textContent = `已发布 v${result.version}`; await open(current.site.id);
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
            for (const [field, value] of Object.entries(entry.fields || {})) if (value) preview.append(node('p', `${fieldLabels[field]}：${value}`));
            for (const source of entry.sources) {
              const file = current.attachments.find(item => item.id === source.attachmentId);
              if (file) preview.append(link(`查看出处：${file.filename} · 第${source.page || 1}页`, `/api/admin/key-sites/${current.site.id}/attachments/${file.id}/${file.mime.startsWith('image/') ? `pages/${source.page || 1}.jpg` : `document.pdf#page=${source.page || 1}`}`));
            }
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
