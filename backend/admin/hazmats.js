'use strict';

(function () {
  const $ = (id) => document.getElementById(id);
  const container = () => $('hazmat-manager');

  let currentQuery = '';
  let currentCategory = '';
  let currentWater = '';
  let currentPage = 0;
  const pageSize = 15;
  let totalCount = 0;
  let activeModal = null;
  let activeDrawerItem = null;

  function textNode(tag, text, className) {
    const el = document.createElement(tag);
    if (text !== undefined && text !== null) el.textContent = String(text);
    if (className) el.className = className;
    return el;
  }

  function formatVaporDensity(val) {
    const s = String(val || '').trim();
    if (!s) return '-';
    const num = parseFloat(s);
    if (!isNaN(num)) {
      if (num > 1.05) return `${s} (⬇️ 显著重于空气，沉降于下水道/低洼)`;
      if (num < 0.95) return `${s} (⬆️ 显著轻于空气，上升积聚于顶部)`;
      return `${s} (≈ 与空气比重相近)`;
    }
    return s;
  }

  function getSignBadge(color, text) {
    return textNode('span', text, `pill-badge pill-color-${color || 'default'}`);
  }

  function getWaterBadge(reactivity) {
    if (reactivity === 'forbidden') {
      return textNode('span', '🚫 严禁用水', 'pill-badge pill-water-forbidden');
    }
    if (reactivity === 'reactive') {
      return textNode('span', '⚠️ 遇水反应', 'pill-badge pill-water-reactive');
    }
    return textNode('span', '💧 可规程用水', 'pill-badge pill-water-normal');
  }

  async function loadHazmats() {
    const parent = container();
    if (!parent || parent.hidden) return;

    const listContainer = $('hazmat-table-wrapper');
    if (!listContainer) return;
    listContainer.replaceChildren(textNode('p', '正在加载危化品数据…', 'empty-state'));

    try {
      const params = new URLSearchParams({
        limit: String(pageSize),
        offset: String(currentPage * pageSize)
      });
      if (currentQuery) params.set('q', currentQuery);
      if (currentCategory) params.set('category', currentCategory);
      if (currentWater) params.set('water', currentWater);

      const res = await api(`/hazmats?${params.toString()}`, undefined, 'GET');
      totalCount = res.total || 0;
      renderTable(res.items || []);
      renderPagination();
    } catch (err) {
      listContainer.replaceChildren(textNode('p', `加载失败：${err.message}`, 'error-banner'));
    }
  }

  function renderPagination() {
    const pager = $('hazmat-pager');
    if (!pager) return;
    pager.replaceChildren();

    const maxPage = Math.max(0, Math.ceil(totalCount / pageSize) - 1);
    const summary = textNode('span', `共 ${totalCount} 条记录，第 ${currentPage + 1} / ${maxPage + 1} 页`, 'pagination-info');

    const btnGroup = document.createElement('div');
    btnGroup.className = 'button-group';

    const prevBtn = textNode('button', '上一页', 'btn btn-subtle btn-sm');
    prevBtn.disabled = currentPage <= 0;
    prevBtn.onclick = () => {
      if (currentPage > 0) {
        currentPage--;
        loadHazmats();
      }
    };

    const nextBtn = textNode('button', '下一页', 'btn btn-subtle btn-sm');
    nextBtn.disabled = currentPage >= maxPage;
    nextBtn.onclick = () => {
      if (currentPage < maxPage) {
        currentPage++;
        loadHazmats();
      }
    };

    btnGroup.append(prevBtn, nextBtn);
    pager.append(summary, btnGroup);
  }

  function renderTable(items) {
    const listContainer = $('hazmat-table-wrapper');
    if (!listContainer) return;
    listContainer.replaceChildren();

    if (items.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'empty-state';
      empty.append(
        textNode('p', '暂无符合条件的危化品记录'),
        textNode('p', '可点击上方“+ 新增危化品”或“批量导入”进行数据录入', 'muted')
      );
      listContainer.append(empty);
      return;
    }

    const table = document.createElement('table');
    table.className = 'data-table';

    const thead = document.createElement('thead');
    const headerRow = document.createElement('tr');
    headerRow.innerHTML = `
      <th style="width: 110px;">UN 编号</th>
      <th>品名 / 别名 / CAS</th>
      <th style="width: 140px;">危险类别</th>
      <th style="width: 130px;">水反应性</th>
      <th style="width: 180px;">禁忌灭火剂</th>
      <th style="width: 150px;">推荐药剂</th>
      <th style="width: 120px; text-align: right;">操作</th>
    `;
    thead.append(headerRow);
    table.append(thead);

    const tbody = document.createElement('tbody');
    for (const item of items) {
      const tr = document.createElement('tr');
      tr.className = 'clickable';
      tr.onclick = (e) => {
        if (e.target.closest('button')) return;
        openDrawer(item);
      };

      // 1. UN号
      const tdUn = document.createElement('td');
      if (item.un_number) {
        tdUn.append(textNode('span', `UN ${item.un_number}`, 'pill-badge pill-un'));
      } else {
        tdUn.append(textNode('span', '-', 'muted'));
      }

      // 2. 品名、CAS与别名
      const tdName = document.createElement('td');
      const nameDiv = document.createElement('div');
      const titleSpan = textNode('strong', item.name_cn);
      titleSpan.style.marginRight = '8px';
      nameDiv.append(titleSpan);

      if (item.cas_number) {
        nameDiv.append(textNode('span', `CAS: ${item.cas_number}`, 'pill-badge pill-cas'));
      }
      tdName.append(nameDiv);

      if (Array.isArray(item.aliases) && item.aliases.length > 0) {
        const aliasDiv = document.createElement('div');
        aliasDiv.className = 'aliases-wrapper';
        for (const a of item.aliases.slice(0, 3)) {
          aliasDiv.append(textNode('span', a, 'alias-tag'));
        }
        if (item.aliases.length > 3) {
          aliasDiv.append(textNode('span', `+${item.aliases.length - 3}`, 'alias-tag'));
        }
        tdName.append(aliasDiv);
      }

      // 3. 危险类别
      const tdCat = document.createElement('td');
      if (item.danger_category) {
        tdCat.append(getSignBadge(item.danger_sign_color, item.danger_category));
      } else {
        tdCat.append(textNode('span', '-', 'muted'));
      }

      // 4. 水反应性
      const tdWater = document.createElement('td');
      tdWater.append(getWaterBadge(item.water_reactivity));

      // 5. 禁忌灭火剂
      const tdForbidden = document.createElement('td');
      if (item.forbidden_agents) {
        const forbidSpan = textNode('span', item.forbidden_agents);
        forbidSpan.style.color = 'var(--alarm)';
        forbidSpan.style.fontWeight = '600';
        forbidSpan.style.fontSize = '13px';
        tdForbidden.append(forbidSpan);
      } else {
        tdForbidden.append(textNode('span', '无特殊禁忌', 'muted'));
      }

      // 6. 推荐药剂
      const tdAgent = document.createElement('td');
      const agentSpan = textNode('span', item.extinguishing_agents || '按常规规程');
      agentSpan.style.fontSize = '13px';
      agentSpan.style.color = 'var(--text-secondary)';
      tdAgent.append(agentSpan);

      // 7. 操作列
      const tdActions = document.createElement('td');
      tdActions.style.textAlign = 'right';

      const viewBtn = textNode('button', '详情', 'btn btn-subtle btn-xs');
      viewBtn.onclick = () => openDrawer(item);

      const editBtn = textNode('button', '编辑', 'btn btn-subtle btn-xs');
      editBtn.onclick = () => openEditModal(item);

      const delBtn = textNode('button', '删除', 'btn btn-subtle btn-xs');
      delBtn.style.color = 'var(--alarm)';
      delBtn.onclick = async () => {
        if (!confirm(`确定要删除危化品「${item.name_cn}」(UN ${item.un_number || '-'}) 吗？`)) return;
        try {
          await api(`/hazmats/${encodeURIComponent(item.id)}`, undefined, 'DELETE');
          if (activeDrawerItem?.id === item.id) closeDrawer();
          loadHazmats();
        } catch (err) {
          alert(`删除失败：${err.message}`);
        }
      };

      const actionsWrapper = document.createElement('div');
      actionsWrapper.className = 'button-group';
      actionsWrapper.style.justifyContent = 'flex-end';
      actionsWrapper.append(viewBtn, editBtn, delBtn);
      tdActions.append(actionsWrapper);

      tr.append(tdUn, tdName, tdCat, tdWater, tdForbidden, tdAgent, tdActions);
      tbody.append(tr);
    }

    table.append(tbody);
    listContainer.append(table);
  }

  // ==========================================
  // 右侧滑出抽屉 (Drawer) 模块
  // ==========================================
  function closeDrawer() {
    activeDrawerItem = null;
    const overlay = $('hazmat-drawer-overlay');
    const panel = $('hazmat-drawer-panel');
    if (overlay) overlay.classList.remove('active');
    if (panel) panel.classList.remove('active');
    setTimeout(() => {
      if (overlay) overlay.hidden = true;
    }, 280);
  }

  function openDrawer(item) {
    activeDrawerItem = item;
    let overlay = $('hazmat-drawer-overlay');
    let panel = $('hazmat-drawer-panel');

    if (!overlay) {
      overlay = document.createElement('div');
      overlay.id = 'hazmat-drawer-overlay';
      overlay.className = 'drawer-overlay';
      overlay.onclick = closeDrawer;

      panel = document.createElement('div');
      panel.id = 'hazmat-drawer-panel';
      panel.className = 'drawer-panel';
      panel.onclick = (e) => e.stopPropagation();

      document.body.append(overlay, panel);
    }

    panel.replaceChildren();

    // 抽屉头部
    const header = document.createElement('div');
    header.className = 'drawer-header';

    const titleGroup = document.createElement('div');
    titleGroup.className = 'drawer-title-group';

    const tagLine = document.createElement('div');
    tagLine.style.display = 'flex';
    tagLine.style.gap = '6px';
    tagLine.style.marginBottom = '8px';
    if (item.un_number) tagLine.append(textNode('span', `UN ${item.un_number}`, 'pill-badge pill-un'));
    if (item.danger_category) tagLine.append(getSignBadge(item.danger_sign_color, item.danger_category));
    tagLine.append(getWaterBadge(item.water_reactivity));
    titleGroup.append(tagLine);

    titleGroup.append(textNode('h3', item.name_cn));
    if (item.name_en) {
      const enP = textNode('p', item.name_en, 'muted');
      enP.style.fontSize = '13px';
      enP.style.margin = '4px 0 0 0';
      titleGroup.append(enP);
    }
    if (item.cas_number) {
      const casP = textNode('p', `CAS 登记号：${item.cas_number}`, 'muted');
      casP.style.fontSize = '12px';
      casP.style.margin = '2px 0 0 0';
      titleGroup.append(casP);
    }

    const closeBtn = textNode('button', '×', 'drawer-close');
    closeBtn.onclick = closeDrawer;

    header.append(titleGroup, closeBtn);

    // 抽屉内容主体
    const body = document.createElement('div');
    body.className = 'drawer-body';

    // 1. 核心危险与红线警示
    const sec1 = document.createElement('div');
    sec1.className = 'drawer-section';
    sec1.append(textNode('div', '现场首要禁令与核心危险', 'drawer-section-title'));

    if (item.forbidden_agents || item.water_reactivity === 'forbidden') {
      const alertBox = document.createElement('div');
      alertBox.className = 'drawer-forbidden-alert';
      alertBox.append(
        textNode('div', '🚫 禁忌灭火剂（红线绝不能碰！）', 'alert-title'),
        textNode('div', item.forbidden_agents || '严禁直接用水灭火！遇水剧烈反应或发生强烈爆炸！', 'alert-content')
      );
      sec1.append(alertBox);
    }

    if (item.danger_summary) {
      const sumDiv = document.createElement('div');
      sumDiv.style.marginTop = '10px';
      sumDiv.style.fontSize = '14px';
      sumDiv.style.lineHeight = '1.6';
      sumDiv.append(
        textNode('strong', '核心危害：'),
        textNode('span', ` ${item.danger_summary}`)
      );
      sec1.append(sumDiv);
    }
    body.append(sec1);

    // 2. 灭火与防护部署
    const sec2 = document.createElement('div');
    sec2.className = 'drawer-section';
    sec2.append(textNode('div', '现场灭火战术与安全防护', 'drawer-section-title'));

    const grid1 = document.createElement('div');
    grid1.className = 'drawer-grid';

    function addKv(parent, label, value) {
      const kv = document.createElement('div');
      kv.className = 'drawer-kv';
      kv.append(textNode('span', label, 'drawer-kv-label'));
      kv.append(textNode('span', value || '-', 'drawer-kv-value'));
      parent.append(kv);
    }

    addKv(grid1, '推荐扑救药剂', item.extinguishing_agents || '雾状水、干粉、抗溶性泡沫');
    addKv(grid1, '个人防护装备等级', item.protective_level || '全封闭防化服 / 正压空呼器');
    addKv(grid1, '应急隔离与警戒距离', item.isolation_distance || '现场划定至少100米警戒圈');
    addKv(grid1, '火场战术扑救要点', item.firefighting_tips || '充分冷却容器壁，防止受热破裂');

    sec2.append(grid1);
    body.append(sec2);

    // 3. 理化特性与泄漏急救
    const sec3 = document.createElement('div');
    sec3.className = 'drawer-section';
    sec3.append(textNode('div', '理化特性与泄漏急救', 'drawer-section-title'));

    const grid2 = document.createElement('div');
    grid2.className = 'drawer-grid';

    addKv(grid2, '蒸气相对密度 (空气=1)', formatVaporDensity(item.vapor_density));
    addKv(grid2, '闪点 / 爆炸极限', `${item.flash_point || '无'} / ${item.explosion_limit || '无'}`);
    addKv(grid2, '外观性状与气味', item.appearance || '无色液体或气体');
    addKv(grid2, '应急洗消与医疗急救', item.first_aid || '脱离污染区，大量清水彻底冲洗');

    sec3.append(grid2);

    if (item.leak_handling) {
      const leakKv = document.createElement('div');
      leakKv.className = 'drawer-kv';
      leakKv.style.marginTop = '12px';
      leakKv.append(
        textNode('span', '泄漏应急堵漏与围堤', 'drawer-kv-label'),
        textNode('span', item.leak_handling, 'drawer-kv-value')
      );
      sec3.append(leakKv);
    }
    body.append(sec3);

    // 4. 多别名全称
    if (Array.isArray(item.aliases) && item.aliases.length > 0) {
      const sec4 = document.createElement('div');
      sec4.className = 'drawer-section';
      sec4.append(textNode('div', '已知同义词与商品俗名', 'drawer-section-title'));
      const aliasWrap = document.createElement('div');
      aliasWrap.className = 'aliases-wrapper';
      for (const a of item.aliases) {
        aliasWrap.append(textNode('span', a, 'alias-tag'));
      }
      sec4.append(aliasWrap);
      body.append(sec4);
    }

    // 抽屉底部
    const footer = document.createElement('div');
    footer.className = 'drawer-footer';

    const editBtn = textNode('button', '编辑此条目', 'btn btn-primary btn-sm');
    editBtn.onclick = () => {
      closeDrawer();
      openEditModal(item);
    };

    const delBtn = textNode('button', '删除', 'btn btn-subtle btn-sm');
    delBtn.style.color = 'var(--alarm)';
    delBtn.onclick = async () => {
      if (!confirm(`确定要删除危化品「${item.name_cn}」吗？`)) return;
      try {
        await api(`/hazmats/${encodeURIComponent(item.id)}`, undefined, 'DELETE');
        closeDrawer();
        loadHazmats();
      } catch (err) {
        alert(`删除失败：${err.message}`);
      }
    };

    const doneBtn = textNode('button', '关闭抽屉', 'btn btn-subtle btn-sm');
    doneBtn.onclick = closeDrawer;

    footer.append(editBtn, delBtn, doneBtn);
    panel.append(header, body, footer);

    overlay.hidden = false;
    requestAnimationFrame(() => {
      overlay.classList.add('active');
      panel.classList.add('active');
    });
  }

  // ==========================================
  // 初始化界面主入口
  // ==========================================
  function initHazmatUI() {
    const parent = container();
    if (!parent) return;

    parent.replaceChildren();

    // 头部大标题与说明
    const header = document.createElement('div');
    header.className = 'section-head';
    header.style.marginBottom = '16px';
    header.innerHTML = `
      <div>
        <h2 style="font-size: 20px; font-weight: 700; margin-bottom: 4px;">危化品应急速查库</h2>
        <p class="muted" style="font-size: 13px; margin: 0;">专为灭火救援一线安全决策打造。重点核查水反应禁忌、灭火药剂选型与疏散隔离圈。点击表格行可展开完整处置指引。</p>
      </div>
    `;

    // 检索过滤与操作工具条
    const toolbar = document.createElement('div');
    toolbar.className = 'action-toolbar';

    const filterGroup = document.createElement('div');
    filterGroup.className = 'filter-group';

    // 搜索框
    const searchWrap = document.createElement('div');
    searchWrap.className = 'search-input-wrap';
    const searchInput = document.createElement('input');
    searchInput.type = 'search';
    searchInput.placeholder = '搜索中文名、别名(如氯仿)、UN号(如1203)、CAS号…';
    searchInput.className = 'search-input';
    let searchDebounce;
    searchInput.oninput = () => {
      clearTimeout(searchDebounce);
      searchDebounce = setTimeout(() => {
        currentQuery = searchInput.value.trim();
        currentPage = 0;
        loadHazmats();
      }, 250);
    };
    searchWrap.append(searchInput);

    // 水反应性筛选
    const waterSelect = document.createElement('select');
    waterSelect.className = 'select-filter';
    waterSelect.append(
      textNode('option', '全部水反应性'),
      Object.assign(textNode('option', '🚫 严禁用水'), { value: 'forbidden' }),
      Object.assign(textNode('option', '⚠️ 遇水反应'), { value: 'reactive' }),
      Object.assign(textNode('option', '💧 可规程用水'), { value: 'normal' })
    );
    waterSelect.onchange = () => {
      currentWater = waterSelect.value;
      currentPage = 0;
      loadHazmats();
    };

    // 类别筛选
    const catSelect = document.createElement('select');
    catSelect.className = 'select-filter';
    catSelect.append(
      textNode('option', '全部危险类别'),
      Object.assign(textNode('option', '易燃液体 (第3类)'), { value: '3' }),
      Object.assign(textNode('option', '遇水易燃 (第4.3项)'), { value: '4.3' }),
      Object.assign(textNode('option', '有毒品 (第6.1/2.3项)'), { value: '毒' }),
      Object.assign(textNode('option', '腐蚀品 (第8类)'), { value: '腐蚀' }),
      Object.assign(textNode('option', '氧化剂 (第5类)'), { value: '氧化' })
    );
    catSelect.onchange = () => {
      currentCategory = catSelect.value;
      currentPage = 0;
      loadHazmats();
    };

    filterGroup.append(searchWrap, waterSelect, catSelect);

    // 按钮组
    const btnGroup = document.createElement('div');
    btnGroup.className = 'button-group';

    const addBtn = textNode('button', '+ 新增危化品', 'btn btn-primary btn-sm');
    addBtn.onclick = () => openEditModal(null);

    const importBtn = textNode('button', '批量导入 (Excel/CSV)', 'btn btn-secondary btn-sm');
    importBtn.onclick = () => openImportModal();

    const tmplBtn = textNode('button', '下载标准模板', 'btn btn-subtle btn-sm');
    tmplBtn.onclick = () => {
      window.location.href = '/api/admin/hazmats/template?format=xlsx';
    };

    btnGroup.append(addBtn, importBtn, tmplBtn);
    toolbar.append(filterGroup, btnGroup);

    // 表格容器
    const tableWrapper = document.createElement('div');
    tableWrapper.id = 'hazmat-table-wrapper';
    tableWrapper.style.background = 'var(--surface)';
    tableWrapper.style.border = '1px solid var(--border)';
    tableWrapper.style.borderRadius = 'var(--radius-md)';
    tableWrapper.style.overflow = 'hidden';
    tableWrapper.style.marginBottom = '20px';

    // 分页条
    const pager = document.createElement('div');
    pager.id = 'hazmat-pager';
    pager.className = 'action-toolbar';
    pager.style.marginTop = '12px';

    parent.append(header, toolbar, tableWrapper, pager);
  }

  // ==========================================
  // 手工录入与编辑模态框
  // ==========================================
  function closeModal() {
    if (activeModal) {
      activeModal.remove();
      activeModal = null;
    }
  }

  function openEditModal(item) {
    closeModal();
    const isEdit = Boolean(item);

    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';

    const modal = document.createElement('div');
    modal.className = 'modal-window';

    const modalHeader = document.createElement('div');
    modalHeader.className = 'modal-header';
    modalHeader.append(textNode('h3', isEdit ? `编辑危化品：${item.name_cn}` : '手工录入新危化品档案'));

    const closeBtn = textNode('button', '×', 'modal-close');
    closeBtn.onclick = closeModal;
    modalHeader.append(closeBtn);

    const form = document.createElement('form');
    const content = document.createElement('div');
    content.className = 'modal-content';

    // 1. 基础标识区
    const sec1 = document.createElement('div');
    sec1.className = 'drawer-section';
    sec1.append(textNode('div', '一、基础标识与多别名检索', 'drawer-section-title'));

    const row1 = document.createElement('div');
    row1.className = 'form-grid-2';

    const nameCnField = document.createElement('div');
    nameCnField.className = 'form-field';
    nameCnField.append(textNode('label', '中文品名 (必填)*'));
    const nameCnInput = document.createElement('input');
    nameCnInput.required = true;
    nameCnInput.value = item?.name_cn || '';
    nameCnInput.placeholder = '例：金属钠、三氯甲烷';
    nameCnField.append(nameCnInput);

    const nameEnField = document.createElement('div');
    nameEnField.className = 'form-field';
    nameEnField.append(textNode('label', '英文名称'));
    const nameEnInput = document.createElement('input');
    nameEnInput.value = item?.name_en || '';
    nameEnInput.placeholder = '例：Sodium, Chloroform';
    nameEnField.append(nameEnInput);

    row1.append(nameCnField, nameEnField);

    const row2 = document.createElement('div');
    row2.className = 'form-grid-2';
    row2.style.marginTop = '12px';

    const unField = document.createElement('div');
    unField.className = 'form-field';
    unField.append(textNode('label', 'UN 编号 (4位代码)'));
    const unInput = document.createElement('input');
    unInput.value = item?.un_number || '';
    unInput.placeholder = '例：1428、1203';
    unField.append(unInput);

    const casField = document.createElement('div');
    casField.className = 'form-field';
    casField.append(textNode('label', 'CAS 登记号'));
    const casInput = document.createElement('input');
    casInput.value = item?.cas_number || '';
    casInput.placeholder = '例：7440-23-5';
    casField.append(casInput);

    row2.append(unField, casField);

    // 多别名 Tag 胶囊录入器
    const aliasField = document.createElement('div');
    aliasField.className = 'form-field';
    aliasField.style.marginTop = '12px';
    aliasField.append(textNode('label', '多别名 / 俗名 / 化学式 (输入后按回车或逗号添加)'));

    let aliasList = Array.isArray(item?.aliases) ? [...item.aliases] : [];
    const tagContainer = document.createElement('div');
    tagContainer.className = 'tag-input-container';

    function renderTags() {
      tagContainer.replaceChildren();
      for (let i = 0; i < aliasList.length; i++) {
        const tag = textNode('span', aliasList[i], 'tag-item');
        const delTag = textNode('span', '×', 'tag-item-del');
        delTag.onclick = () => {
          aliasList.splice(i, 1);
          renderTags();
        };
        tag.append(delTag);
        tagContainer.append(tag);
      }
      const tagInput = document.createElement('input');
      tagInput.type = 'text';
      tagInput.className = 'tag-input-field';
      tagInput.placeholder = '输入别名按回车 (如：氯仿、三氯代甲烷)';
      tagInput.onkeydown = (e) => {
        if (e.key === 'Enter' || e.key === ',' || e.key === '，' || e.key === ';') {
          e.preventDefault();
          const v = tagInput.value.trim();
          if (v && !aliasList.includes(v)) {
            aliasList.push(v);
            renderTags();
          }
        }
      };
      tagContainer.append(tagInput);
    }
    renderTags();

    aliasField.append(tagContainer);
    sec1.append(row1, row2, aliasField);

    // 2. 危险等级与水反应性
    const sec2 = document.createElement('div');
    sec2.className = 'drawer-section';
    sec2.style.marginTop = '16px';
    sec2.append(textNode('div', '二、危险等级与水反应特性', 'drawer-section-title'));

    const row3 = document.createElement('div');
    row3.className = 'form-grid-2';

    const catField = document.createElement('div');
    catField.className = 'form-field';
    catField.append(textNode('label', '危险性类别'));
    const catInput = document.createElement('input');
    catInput.value = item?.danger_category || '';
    catInput.placeholder = '例：第4.3项 遇水放出易燃气体的物质';
    catField.append(catInput);

    const waterField = document.createElement('div');
    waterField.className = 'form-field';
    waterField.append(textNode('label', '水反应特性 (灭火决策核心！)*'));
    const waterInput = document.createElement('select');
    waterInput.append(
      Object.assign(textNode('option', '💧 可规程用水灭火'), { value: 'normal' }),
      Object.assign(textNode('option', '⚠️ 遇水反应/剧烈水解'), { value: 'reactive' }),
      Object.assign(textNode('option', '🚫 严禁用水！(剧烈爆炸或产毒)'), { value: 'forbidden' })
    );
    waterInput.value = item?.water_reactivity || 'normal';
    waterField.append(waterInput);

    row3.append(catField, waterField);

    const summaryField = document.createElement('div');
    summaryField.className = 'form-field';
    summaryField.style.marginTop = '12px';
    summaryField.append(textNode('label', '核心危险概述 (现场一句话播报)'));
    const summaryInput = document.createElement('textarea');
    summaryInput.rows = 2;
    summaryInput.value = item?.danger_summary || '';
    summaryInput.placeholder = '例：剧烈遇水反应生成氢气并引发爆炸，极易燃烧，燃烧火焰呈黄色。';
    summaryField.append(summaryInput);

    sec2.append(row3, summaryField);

    // 3. 救援行动字段
    const sec3 = document.createElement('div');
    sec3.className = 'drawer-section';
    sec3.style.marginTop = '16px';
    sec3.append(textNode('div', '三、火场灭火与救援行动红线', 'drawer-section-title'));

    const forbidField = document.createElement('div');
    forbidField.className = 'form-field';
    const forbidLabel = textNode('label', '🚫 禁忌灭火剂 (红线禁令，严禁使用！)*');
    forbidLabel.style.color = 'var(--alarm)';
    forbidField.append(forbidLabel);
    const forbidInput = document.createElement('input');
    forbidInput.style.borderColor = 'var(--alarm)';
    forbidInput.value = item?.forbidden_agents || '';
    forbidInput.placeholder = '例：严禁用水、水基灭火剂、泡沫、二氧化碳、卤代烷！';
    forbidField.append(forbidInput);

    const agentField = document.createElement('div');
    agentField.className = 'form-field';
    agentField.style.marginTop = '12px';
    agentField.append(textNode('label', '🧯 推荐灭火药剂'));
    const agentInput = document.createElement('input');
    agentInput.value = item?.extinguishing_agents || '';
    agentInput.placeholder = '例：干粉、D类专用干粉灭火剂、干燥砂土、食盐';
    agentField.append(agentInput);

    const row4 = document.createElement('div');
    row4.className = 'form-grid-2';
    row4.style.marginTop = '12px';

    const protField = document.createElement('div');
    protField.className = 'form-field';
    protField.append(textNode('label', '🛡️ 防护装备要求'));
    const protInput = document.createElement('input');
    protInput.value = item?.protective_level || '';
    protInput.placeholder = '例：全封闭重型防化服、正压式空气呼吸器';
    protField.append(protInput);

    const distField = document.createElement('div');
    distField.className = 'form-field';
    distField.append(textNode('label', '📏 应急隔离警戒距离'));
    const distInput = document.createElement('input');
    distInput.value = item?.isolation_distance || '';
    distInput.placeholder = '例：初始隔离至少150米，下风向疏散500米';
    distField.append(distInput);

    row4.append(protField, distField);
    sec3.append(forbidField, agentField, row4);

    // 4. 理化与处置详情
    const sec4 = document.createElement('div');
    sec4.className = 'drawer-section';
    sec4.style.marginTop = '16px';
    sec4.append(textNode('div', '四、理化特性与急救洗消 (选填)', 'drawer-section-title'));

    const row5 = document.createElement('div');
    row5.className = 'form-grid-2';

    const vaporField = document.createElement('div');
    vaporField.className = 'form-field';
    vaporField.append(textNode('label', '蒸气相对密度 (空气=1)'));
    const vaporInput = document.createElement('input');
    vaporInput.value = item?.vapor_density || '';
    vaporInput.placeholder = '例：4.12 (空气=1)';
    vaporField.append(vaporInput);

    const flashField = document.createElement('div');
    flashField.className = 'form-field';
    flashField.append(textNode('label', '闪点 / 爆炸极限'));
    const flashInput = document.createElement('input');
    flashInput.value = item?.flash_point || '';
    flashInput.placeholder = '例：-11°C / 1.2% - 7.5%';
    flashField.append(flashInput);

    row5.append(vaporField, flashField);

    const leakField = document.createElement('div');
    leakField.className = 'form-field';
    leakField.style.marginTop = '12px';
    leakField.append(textNode('label', '泄漏处置要点'));
    const leakInput = document.createElement('textarea');
    leakInput.rows = 2;
    leakInput.value = item?.leak_handling || '';
    leakInput.placeholder = '例：切断火源，砂土围堵，禁止冲入下水道';
    leakField.append(leakInput);

    const aidField = document.createElement('div');
    aidField.className = 'form-field';
    aidField.style.marginTop = '12px';
    aidField.append(textNode('label', '急救洗消措施'));
    const aidInput = document.createElement('textarea');
    aidInput.rows = 2;
    aidInput.value = item?.first_aid || '';
    aidInput.placeholder = '例：脱离现场，大量流动清水彻底冲洗皮肤15分钟以上';
    aidField.append(aidInput);

    sec4.append(row5, leakField, aidField);

    content.append(sec1, sec2, sec3, sec4);

    // 底部操作栏
    const modalFooter = document.createElement('div');
    modalFooter.className = 'modal-footer';

    const cancelBtn = textNode('button', '取消', 'btn btn-subtle');
    cancelBtn.type = 'button';
    cancelBtn.onclick = closeModal;

    const saveBtn = textNode('button', isEdit ? '保存修改' : '确认新增', 'btn btn-primary');
    saveBtn.type = 'submit';

    modalFooter.append(cancelBtn, saveBtn);

    form.onsubmit = async (e) => {
      e.preventDefault();
      const payload = {
        name_cn: nameCnInput.value.trim(),
        name_en: nameEnInput.value.trim(),
        un_number: unInput.value.trim(),
        cas_number: casInput.value.trim(),
        aliases: aliasList,
        danger_category: catInput.value.trim(),
        danger_summary: summaryInput.value.trim(),
        water_reactivity: waterInput.value,
        forbidden_agents: forbidInput.value.trim(),
        extinguishing_agents: agentInput.value.trim(),
        protective_level: protInput.value.trim(),
        isolation_distance: distInput.value.trim(),
        vapor_density: vaporInput.value.trim(),
        flash_point: flashInput.value.trim(),
        leak_handling: leakInput.value.trim(),
        first_aid: aidInput.value.trim()
      };

      try {
        saveBtn.disabled = true;
        saveBtn.textContent = '正在保存…';
        if (isEdit) {
          await api(`/hazmats/${encodeURIComponent(item.id)}`, payload, 'PUT');
        } else {
          await api('/hazmats', payload, 'POST');
        }
        closeModal();
        loadHazmats();
      } catch (err) {
        alert(`保存失败：${err.message}`);
        saveBtn.disabled = false;
        saveBtn.textContent = isEdit ? '保存修改' : '确认新增';
      }
    };

    form.append(content, modalFooter);
    modal.append(modalHeader, form);
    overlay.append(modal);

    document.body.append(overlay);
    activeModal = overlay;
  }

  // ==========================================
  // 批量导入模态框 (Excel / CSV)
  // ==========================================
  function openImportModal() {
    closeModal();

    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';

    const modal = document.createElement('div');
    modal.className = 'modal-window';

    const modalHeader = document.createElement('div');
    modalHeader.className = 'modal-header';
    modalHeader.append(textNode('h3', '批量导入危化品数据 (Excel / CSV)'));

    const closeBtn = textNode('button', '×', 'modal-close');
    closeBtn.onclick = closeModal;
    modalHeader.append(closeBtn);

    const content = document.createElement('div');
    content.className = 'modal-content';

    const tips = document.createElement('div');
    tips.className = 'drawer-section';
    tips.style.background = '#F0F9FF';
    tips.style.borderColor = '#BAE6FD';
    tips.innerHTML = `
      <strong style="color: #0369A1;">💡 批量导入说明：</strong>
      <ol style="margin: 6px 0 0 18px; padding: 0; font-size: 13px; color: #0C4A6E; line-height: 1.6;">
        <li>支持 <code>.xlsx</code>、<code>.xls</code> 和 <code>.csv</code> 表格文件。</li>
        <li>以“中文品名”或“UN编号”为比对键，库内已存在时将自动覆盖更新。</li>
        <li>“别名”列支持用逗号、分号或斜杠分隔，导入时自动切分为独立检索热词。</li>
        <li>水反应性若填写“严禁用水”，系统将自动加注灭火禁令红标与红框提示。</li>
      </ol>
    `;

    const dropzone = document.createElement('div');
    dropzone.className = 'file-dropzone';
    dropzone.style.marginTop = '12px';

    const fileInput = document.createElement('input');
    fileInput.type = 'file';
    fileInput.accept = '.xlsx, .xls, .csv';

    const dropText = textNode('p', '点击此处选择 Excel 文件，或将表格拖拽到这里');
    const fileHint = textNode('small', '支持 .xlsx / .xls / .csv 格式', 'muted');
    dropzone.append(fileInput, dropText, fileHint);

    dropzone.onclick = () => fileInput.click();

    const previewArea = document.createElement('div');
    previewArea.style.marginTop = '12px';
    previewArea.hidden = true;

    let selectedFile = null;

    fileInput.onchange = (e) => {
      selectedFile = e.target.files[0];
      if (selectedFile) {
        dropText.textContent = `已选定文件：${selectedFile.name} (${Math.round(selectedFile.size / 1024)} KB)`;
        dropzone.style.borderColor = 'var(--brand)';
        dropzone.style.background = '#FFF7ED';
      }
    };

    const modalFooter = document.createElement('div');
    modalFooter.className = 'modal-footer';

    const downloadBtn = textNode('button', '下载标准 Excel 导入模板', 'btn btn-subtle');
    downloadBtn.type = 'button';
    downloadBtn.onclick = () => {
      window.location.href = '/api/admin/hazmats/template?format=xlsx';
    };

    const cancelBtn = textNode('button', '取消', 'btn btn-subtle');
    cancelBtn.type = 'button';
    cancelBtn.onclick = closeModal;

    const startBtn = textNode('button', '开始执行导入', 'btn btn-primary');
    startBtn.onclick = async () => {
      if (!selectedFile) {
        alert('请先选择要导入的 Excel 或 CSV 文件');
        return;
      }

      startBtn.disabled = true;
      startBtn.textContent = '正在上传并解析…';
      previewArea.hidden = false;
      previewArea.replaceChildren(textNode('p', '正在处理数据，请稍候…', 'muted'));

      try {
        const formData = new FormData();
        formData.append('file', selectedFile);

        const response = await fetch('/api/admin/hazmats/import', {
          method: 'POST',
          credentials: 'same-origin',
          headers: {
            'X-CSRF-Token': csrf
          },
          body: formData
        });

        const res = await response.json();
        if (!response.ok) {
          throw new Error(res.error || '导入请求处理失败');
        }

        previewArea.replaceChildren();
        const successBox = document.createElement('div');
        successBox.style.padding = '12px';
        successBox.style.background = 'var(--safe-bg)';
        successBox.style.border = '1px solid var(--safe-border)';
        successBox.style.borderRadius = 'var(--radius-sm)';
        successBox.innerHTML = `
          <strong style="color: var(--safe); font-size: 15px;">🎉 批量导入完成！</strong>
          <p style="margin: 6px 0 0 0; font-size: 13px; color: var(--text-secondary);">
            总条目：${res.total} 条 ｜ 新增：${res.created} 条 ｜ 更新：${res.updated} 条 ｜ 失败：${res.failed} 条
          </p>
        `;

        if (Array.isArray(res.errors) && res.errors.length > 0) {
          const errList = document.createElement('div');
          errList.style.marginTop = '8px';
          errList.style.fontSize = '12px';
          errList.style.color = 'var(--alarm)';
          errList.append(textNode('strong', '失败详情：'));
          for (const err of res.errors) {
            errList.append(textNode('p', `第 ${err.row || '-'} 行：${err.error}`));
          }
          successBox.append(errList);
        }

        previewArea.append(successBox);
        startBtn.textContent = '导入完成';
        loadHazmats();
      } catch (err) {
        previewArea.replaceChildren(textNode('p', `导入失败：${err.message}`, 'error-banner'));
        startBtn.disabled = false;
        startBtn.textContent = '重新尝试导入';
      }
    };

    modalFooter.append(downloadBtn, cancelBtn, startBtn);

    content.append(tips, dropzone, previewArea);
    modal.append(modalHeader, content, modalFooter);
    overlay.append(modal);

    document.body.append(overlay);
    activeModal = overlay;
  }

  // 监听导航事件
  document.addEventListener('hazmat-tab-activated', () => {
    initHazmatUI();
    currentPage = 0;
    loadHazmats();
  });

  // 监听会话就绪
  document.addEventListener('admin-ready', () => {
    if ($('workspace') && !$('workspace').hidden && workspaceView === 'hazmats') {
      initHazmatUI();
      loadHazmats();
    }
  });

  // 支持键盘 Esc 关闭抽屉与弹窗
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (activeModal) closeModal();
      else if (activeDrawerItem) closeDrawer();
    }
  });

})();
