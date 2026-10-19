'use strict';
(() => {
  const labels = { maps: '地图', plans: '应急预案', cards: '作战信息卡', organization: '组织架构', hazards: '危险品' };
  const fieldLabels = { capturedAt: '拍摄日期', versionLabel: '地图版本', area: '区域', scope: '适用范围', risk: '风险', keyLocations: '重点部位', access: '通行条件', water: '水源', response: '处置信息', parent: '上级组织或岗位', position: '岗位', contact: '联系人', phone: '联系方式', responsibilities: '岗位职责', location: '存放位置', quantity: '数量（含单位）', storage: '存放条件', notes: '待核对事项或补充说明' };
  const fields = { maps: ['capturedAt','versionLabel','area'], plans: ['scope'], cards: ['risk','keyLocations','access','water','response'], organization: ['parent','position','contact','phone','responsibilities'], hazards: ['location','quantity','risk','storage','notes'] };
  const profileFields = { name: '重点单位名称', short_name: '简称', address: '地址', district: '辖区', site_type: '类型' };
  const taskErrors = { KEY_SITE_INTERRUPTED: '处理进程中断，可重试', KEY_SITE_CONVERTER_UNAVAILABLE: '服务器文档转换组件暂不可用', KEY_SITE_PROCESS_TIMEOUT: '处理超时，请缩小文件后重试', KEY_SITE_CONVERT_FAILED: '文件损坏、加密或无法转换', KEY_SITE_PAGE_LIMIT: '文档页数超过限制', KEY_SITE_ENCRYPTED: '不支持加密PDF', KEY_SITE_QUOTA_EXCEEDED: '处理结果超过资料存储配额', KEY_SITE_PROCESS_FAILED: '文件处理失败，请重试' };
  let member, units = [], limits, aiAvailable = false, current, module = 'cards', offset = 0, dirty = false, query = {}, taskTimer;
  const aiCache = new Map();
  let activeAI = null;
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
    const capabilities = await api('/key-sites/limits', undefined, 'GET');
    limits = capabilities.limits; aiAvailable = capabilities.aiAvailable;
    const p = $('workspace').querySelector(':scope > p:last-of-type');
    if (p?.textContent.includes('随阶段')) p.remove();
    await list();
  }
  function mayLeave() {
    if (!dirty) return true;
    if (!confirm('有尚未保存的编辑，确认放弃本次未保存内容？')) return false;
    if (activeAI) aiCache.delete(activeAI);
    return true;
  }
  function updateSummary() {
    if (!current || !$('site-summary')) return;
    const { site, draft } = current;
    $('site-summary').textContent = `${site.address} · ${site.published_version ? `当前已发布 v${site.published_version}` : '尚未发布'} · 草稿更新 ${date(draft.updated_at)}`;
  }
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
    clearTimeout(taskTimer); current = await api(`/key-sites/${id}`, undefined, 'GET'); dirty = false; activeAI = null;
    manager.replaceChildren();
    const { site } = current;
    manager.append(button('← 返回单位列表', () => mayLeave() ? list() : undefined));
    const head = node('div', '', 'section-head'); head.append(node('h2', site.name), button('编辑档案', () => editProfile(site)), button(site.active ? '停用单位' : '恢复单位', async () => {
      if (!confirm(site.active ? '停用后不能新关联，历史警情仍保留引用版本。确认停用？' : '确认恢复此单位？')) return;
      await api(`/key-sites/${id}`, { ...site, active: !site.active }, 'PUT'); dirty = false; await open(id);
    })); const summary = node('p'); summary.id = 'site-summary'; manager.append(head, summary); updateSummary();
    const notice = node('div', '草稿仅维护人员可见。请逐项核对原件；主动发布后，全平台已认证有效成员均可查阅。', 'notice'); manager.append(notice);
    const tabs = node('nav', '', 'module-tabs'); tabs.setAttribute('aria-label', '资料分类');
    for (const key of ['cards','maps','plans','organization','hazards']) tabs.append(button(labels[key], () => { if (mayLeave()) { manager.querySelector('.ai-review')?.remove(); activeAI = null; module = key; renderModule(); dirty = false; } }, key === module ? 'active' : ''));
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
    updateSummary();
    dirty = false; $('error').textContent = '草稿已保存，尚未发布';
  }
  function editEntry(index) {
    if (!mayLeave()) return;
    manager.querySelector('.ai-review')?.remove(); activeAI = null;
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
      for (const file of current.attachments.filter(file => file.status === 'ready' && (module !== 'maps' || file.metadata.map))) { const option = node('option', file.filename); option.value = file.id; select.append(option); }
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
    root.append(node('p', aiAvailable ? `AI每批最多${limits.aiPages}页，仅生成待核对建议，不自动写入或发布。长文档请明确选择页码分批整理。` : 'AI服务尚未配置，可继续人工录入和核对发布。', 'muted'));
    const statuses = { queued: '排队中', processing: '处理中', ready: '可核对', failed: '处理失败', succeeded: '处理完成', partial: '部分页面失败', cancelled: '已放弃' };
    for (const file of current.attachments.filter(file => file.module === module)) {
      const row = node('div', '', 'asset-row'); row.append(node('strong', file.filename), node('span', statuses[file.status] || file.status));
      if (file.status === 'ready') row.append(link('阅读', `/api/admin/key-sites/${current.site.id}/attachments/${file.id}/${file.mime.startsWith('image/') ? 'pages/1.jpg' : 'document.pdf'}`));
      row.append(link('下载原件', `/api/admin/key-sites/${current.site.id}/attachments/${file.id}/source`));
      const task = current.tasks.find(task => task.attachment_id === file.id && task.kind !== 'ai');
      if (task?.status === 'failed') row.append(node('span', `失败原因：${taskErrors[task.error_code] || '文件处理失败，请重试或联系维护人员'}`), button('重试', async () => { await api(`/key-sites/tasks/${task.id}/retry`, {}); await refreshAssets(); }));
      if (file.status === 'ready') {
        const aiButton = button('AI整理', () => requestAI(file)); aiButton.disabled = !aiAvailable; row.append(aiButton);
      }
      for (const job of current.tasks.filter(task => task.attachment_id === file.id && task.kind === 'ai')) {
        const jobRow = node('div', '', 'ai-job');
        jobRow.append(node('span', `AI整理 · ${statuses[job.status]} · 已完成 ${job.completed_pages || 0}/${job.page_count || 0} 页`),
          button('查看与核对', () => reviewAI(job.id)));
        if (job.status !== 'cancelled') jobRow.append(button('放弃此任务', async () => {
          if (!confirm('放弃AI整理任务？已保存的人工草稿和已发布资料保留。')) return;
          await api(`/key-sites/tasks/${job.id}/ai-cancel`, {}); aiCache.delete(job.id);
          if (activeAI === job.id) { manager.querySelector('.ai-review')?.remove(); activeAI = null; dirty = false; }
          await refreshAssets();
        }));
        row.append(jobRow);
      }
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
  async function requestAI(file) {
    const root = manager.querySelector('.ai-request') || node('section', '', 'ai-request'); root.replaceChildren();
    root.append(node('h3', `AI整理：${file.filename}`), node('p', `共${file.metadata.pages}页。每批最多${limits.aiPages}页；只处理明确选择的页面，其他页面不会被静默跳过。`));
    const pageText = input(root, '待处理页码（如 1-3,5）', file.metadata.pages === 1 ? '1' : `1-${Math.min(file.metadata.pages, limits.aiPages)}`);
    pageText.oninput = () => {};
    root.append(button('开始AI整理', async () => {
      const selected = [];
      for (const token of pageText.value.replace(/，/g, ',').split(',')) {
        const match = /^(\d+)(?:-(\d+))?$/.exec(token.trim());
        if (!match) throw new Error('页码格式无效，请填写如 1-3,5');
        const first = Number(match[1]), last = Number(match[2] || match[1]);
        if (first < 1 || last < first || last > file.metadata.pages || last - first >= limits.aiPages) throw new Error('页码超出附件或单批限制');
        for (let page = first; page <= last; page++) selected.push(page);
      }
      if (!selected.length || selected.length > limits.aiPages || new Set(selected).size !== selected.length) throw new Error('请选择不重复的页码，且不超过单批限制');
      const task = await api(`/key-sites/${current.site.id}/attachments/${file.id}/ai`, { pages: selected });
      root.remove(); await refreshAssets(); await reviewAI(task.id);
    }), button('取消', () => root.remove()));
    manager.append(root); root.scrollIntoView({ block: 'nearest' });
  }
  async function reviewAI(taskId) {
    if (activeAI !== taskId && !mayLeave()) return;
    if (activeAI !== taskId) { $('entry-editor')?.replaceChildren(); dirty = false; }
    const siteId = current.site.id;
    const task = await api(`/key-sites/tasks/${taskId}`, undefined, 'GET');
    if (!current || current.site.id !== siteId) return;
    activeAI = taskId;
    if (!aiCache.has(taskId) && aiCache.size >= 20) {
      const old = [...aiCache].find(([id, saved]) => id !== taskId && saved.changed.size === 0);
      if (old) aiCache.delete(old[0]);
      else throw new Error('请先保存或关闭已有核对编辑，再打开更多任务');
    }
    const cache = aiCache.get(taskId) || { edits: new Map(), selected: new Set(), page: task.result.pages[0].page, changed: new Set() };
    aiCache.set(taskId, cache);
    const known = new Set(task.summary.entries.map(candidate => candidate.id));
    for (const id of cache.selected) if (!known.has(id) || task.result.applied.includes(id)) cache.selected.delete(id);
    const panel = node('section', '', 'ai-review'); panel.append(node('h2', '原文核对 · AI建议'));
    panel.append(node('p', '左侧原件为核对依据，右侧为逐页摘录。缺失、识别不清和冲突须人工核对；AI不提供未经原文支持的处置结论。', 'notice'));
    const controls = node('div', '', 'actions');
    controls.append(button('刷新建议（保留本页编辑）', () => reviewAI(taskId)), button('关闭核对', () => {
      if (!mayLeave()) return; panel.remove(); activeAI = null; dirty = false;
    })); panel.append(controls);
    const errors = { KEY_SITE_AI_REQUEST_FAILED: '识别请求失败或超时', KEY_SITE_AI_UPSTREAM_FAILED: 'AI服务暂不可用', KEY_SITE_AI_RESULT_INVALID: '识别结果不完整', KEY_SITE_AI_INTERRUPTED: '处理进程中断，可重试', KEY_SITE_AI_RESULT_LIMIT: '结果超过大小限制，请减少单批页数', KEY_SITE_AI_UNAVAILABLE: 'AI服务尚未配置', KEY_SITE_AI_ACCESS_REVOKED: '提交者授权或维护归属已变化，需由当前维护人员重试' };
    const failed = task.result.pages.filter(page => page.status === 'failed');
    if (failed.length) {
      const retry = node('div', '', 'notice'); retry.append(node('strong', '以下页面未完成，不会作为已识别资料使用'));
      for (const page of failed) retry.append(node('p', `第${page.page}页：${errors[page.errorCode] || '处理失败，请核对原件后重试'}`));
      retry.append(button('仅重试这些失败页面', async () => {
        await api(`/key-sites/tasks/${taskId}/ai-retry`, { pages: failed.map(page => page.page) });
        await refreshAssets(); await reviewAI(taskId);
      })); panel.append(retry);
    }
    if (task.summary.conflicts.length) {
      const conflicts = node('div', '', 'notice'); conflicts.append(node('strong', '同名条目的不同原文内容，须人工判断，不自动合并'));
      for (const conflict of task.summary.conflicts) conflicts.append(node('p', `${conflict.title} · ${fieldLabels[conflict.field] || '正文'} · 第${conflict.pages.join('、')}页：${conflict.values.join(' / ')}`));
      panel.append(conflicts);
    }
    const pageLabel = node('label', '核对页码'), pageSelect = node('select');
    for (const page of task.result.pages) { const option = node('option', `第${page.page}页 · ${({ queued:'排队中',processing:'识别中',succeeded:'可核对',failed:'失败' })[page.status]}`); option.value = page.page; pageSelect.append(option); }
    pageSelect.value = cache.page; pageLabel.append(pageSelect); panel.append(pageLabel);
    const layout = node('div', '', 'ai-compare'); panel.append(layout);
    const renderPage = () => {
      const page = task.result.pages.find(page => page.page === Number(pageSelect.value)); cache.page = page.page; layout.replaceChildren();
      const original = node('div', '', 'doc-preview'), image = node('img'); image.alt = `原件第${page.page}页`;
      image.src = `/api/admin/key-sites/${siteId}/attachments/${task.attachment_id}/pages/${page.page}.jpg`;
      image.onerror = () => { original.append(node('p', '原文页加载失败，请刷新重试')); };
      const zoom = node('div', '', 'actions'); zoom.append(button('放大原件', () => { image.style.width = '200%'; image.style.maxWidth = 'none'; }), button('恢复全页', () => { image.style.width = '100%'; image.style.maxWidth = '100%'; }));
      original.append(zoom, image); layout.append(original); const proposed = node('div', '', 'ai-proposed'); layout.append(proposed);
      if (page.status !== 'succeeded') { proposed.append(node('p', '本页尚无可核对建议；可等待识别或重试失败页面。')); return; }
      proposed.append(node('p', `建议分类：${page.extraction.classification.map(key => labels[key]).join('、') || '未确定'}`));
      for (const note of page.extraction.toConfirm) proposed.append(node('p', `待核对：${note}`, 'review-note'));
      const raw = node('details'); raw.append(node('summary', '识别原文（仍需与原件逐字核对）'), node('pre', page.extraction.rawText)); proposed.append(raw);
      if (!page.extraction.entries.length) proposed.append(node('p', '本页未提取到可核实条目，请人工核对或录入。'));
      for (const candidate of page.extraction.entries) {
        const box = node('div', '', 'ai-candidate'), adopted = task.result.applied.includes(candidate.id);
        const edit = cache.edits.get(candidate.id) || { module: candidate.module, title: candidate.entry.title, body: candidate.entry.body, fields: { ...candidate.entry.fields } };
        cache.edits.set(candidate.id, edit);
        const choose = node('label', adopted ? '已采用（后续修改请编辑人工草稿）' : '选择此条目加入草稿'), check = node('input'); check.type = 'checkbox'; check.disabled = adopted; check.checked = cache.selected.has(candidate.id); choose.prepend(check); box.append(choose);
        check.onchange = () => { check.checked ? cache.selected.add(candidate.id) : cache.selected.delete(candidate.id); reviewed.checked = false; };
        const classificationLabel = node('label', '资料分类'), classification = node('select');
        for (const [key, label] of Object.entries(labels)) { const option = node('option', label); option.value = key; classification.append(option); }
        classification.value = edit.module; classificationLabel.append(classification); box.append(classificationLabel);
        const title = input(box, '标题', edit.title), body = input(box, '正文原文摘录', edit.body, { multiline: true });
        const changed = () => { dirty = true; cache.changed.add(candidate.id); reviewed.checked = false; };
        title.oninput = () => { edit.title = title.value; changed(); }; body.oninput = () => { edit.body = body.value; changed(); };
        const fieldRoot = node('div'); box.append(fieldRoot);
        const renderFields = () => {
          fieldRoot.replaceChildren();
          for (const key of fields[edit.module]) {
            const control = input(fieldRoot, fieldLabels[key], edit.fields[key] || '', { multiline: ['risk','response','responsibilities','notes'].includes(key) });
            control.oninput = () => { edit.fields[key] = control.value; changed(); };
          }
          if (adopted) for (const control of fieldRoot.querySelectorAll('input,textarea')) control.disabled = true;
        };
        classification.onchange = () => { edit.module = classification.value; changed(); renderFields(); }; renderFields();
        classification.disabled = adopted; title.disabled = adopted; body.disabled = adopted;
        for (const note of candidate.toConfirm) box.append(node('p', `待核对：${note}`, 'review-note'));
        proposed.append(box);
      }
    };
    pageSelect.onchange = renderPage; renderPage();
    const comparison = node('details'); comparison.append(node('summary', `当前人工草稿：修订 ${current.draft.revision}（只追加，不替换）`));
    const showDraft = () => {
      comparison.querySelector('div')?.remove(); const list = node('div');
      for (const key of Object.keys(labels)) for (const entry of current.draft.content[key]) list.append(node('p', `${labels[key]} · ${entry.title}：${entry.body}`));
      comparison.append(list);
    }; showDraft(); panel.append(comparison);
    panel.append(button('重新载入人工草稿（保留核对编辑）', async () => {
      const result = await api(`/key-sites/${siteId}`, undefined, 'GET'); current.draft = result.draft;
      updateSummary();
      reviewed.checked = false;
      comparison.querySelector('summary').textContent = `当前人工草稿：修订 ${current.draft.revision}（请重新核对）`; comparison.open = true; showDraft();
    }));
    const confirmLabel = node('label', '我已核对所选条目的原件、缺失及冲突，并确认人工修订内容'), reviewed = node('input'); reviewed.type = 'checkbox'; confirmLabel.prepend(reviewed); panel.append(confirmLabel);
    const apply = button('将所选已核对条目追加到草稿', async () => {
      if (!reviewed.checked) throw new Error('请先逐项核对原件并勾选确认');
      const ids = [...cache.selected]; if (!ids.length) throw new Error('请选择需要加入草稿的条目');
      const draft = await api(`/key-sites/tasks/${taskId}/ai-apply`, { revision: current.draft.revision, generation: task.generation,
        reviewed: true, ids, edits: Object.fromEntries(ids.map(id => [id, cache.edits.get(id)])) });
      current.draft = draft; updateSummary(); ids.forEach(id => { cache.selected.delete(id); cache.changed.delete(id); });
      dirty = cache.changed.size > 0; renderModule(); await refreshAssets(); await reviewAI(taskId);
      $('error').textContent = '已追加到人工草稿，已有修改保留；尚未发布。';
    }, 'primary'); apply.disabled = !['succeeded','partial'].includes(task.status); panel.append(apply);
    manager.querySelector('.ai-review')?.remove(); manager.append(panel); panel.scrollIntoView({ block: 'start' });
  }
  async function publish() {
    if (dirty) throw new Error('请先保存当前正在编辑的条目，再核对发布');
    const target = { id: current.site.id, name: current.site.name, revision: current.draft.revision, profileRevision: current.site.revision };
    manager.querySelector('.publish-confirmation')?.remove();
    const panel = node('section', '', 'publish-confirmation notice');
    panel.append(node('h3', `发布确认：${current.site.name}`), node('p', current.site.address),
      node('p', `将发布 v${current.site.published_version + 1}。资料和引用附件将向全平台已认证有效成员开放查阅。请先确认所有条目及出处已人工核对。`));
    const referenced = [...new Set(Object.values(current.draft.content).flatMap(entries => entries.flatMap(entry => entry.sources.map(source => source.attachmentId))))];
    if (referenced.length) {
      panel.append(node('p', '以下文件的完整正式阅读版本将共享，并非仅摘录页。原始上传文件仍仅维护人员可下载。'));
      for (const id of referenced) {
        const attachment = current.attachments.find(file => file.id === id);
        if (!attachment) throw new Error('来源附件已变化，请重新加载核对');
        panel.append(node('p', `${attachment.filename} · ${attachment.metadata.pages || 1}页`));
      }
    } else panel.append(node('p', '当前资料未引用附件。'));
    const label = node('label', '我已核对资料，并确认向全平台已认证有效成员共享'), checkbox = node('input'); checkbox.type = 'checkbox'; label.prepend(checkbox); panel.append(label);
    const submit = button('确认向全平台发布', async () => {
      if (!checkbox.checked) throw new Error('请先确认本次发布的共享范围');
      if (dirty) throw new Error('请先保存编辑，再重新核对发布');
      submit.disabled = true;
      try {
        const result = await api(`/key-sites/${target.id}/publish`, { revision: target.revision, profileRevision: target.profileRevision, confirmPlatformSharing: true });
        $('error').textContent = `${target.name} 已发布 v${result.version}`; if (current?.site.id === target.id) await open(target.id);
      } finally { submit.disabled = false; }
    }, 'primary'); submit.disabled = true; checkbox.onchange = () => { submit.disabled = !checkbox.checked; };
    panel.append(submit, button('取消发布', () => panel.remove())); manager.append(panel); panel.scrollIntoView({ block: 'nearest' });
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
  document.addEventListener('admin-ended', () => { clearTimeout(taskTimer); member = null; current = null; dirty = false; activeAI = null; aiCache.clear(); });
  window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });
})();
