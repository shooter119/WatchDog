'use strict';

(function () {
  const $ = (id) => document.getElementById(id);
  const container = () => $('hazmat-manager');

  let currentQuery = '';
  let currentCategory = '';
  let currentWater = '';
  let currentPage = 0;
  const pageSize = 20;
  let totalCount = 0;
  let activeModal = null;

  function textNode(tag, text, className) {
    const el = document.createElement(tag);
    if (text !== undefined && text !== null) el.textContent = String(text);
    if (className) el.className = className;
    return el;
  }

  function formatVaporDensity(val) {
    const s = String(val || '').trim();
    if (!s) return '';
    const num = parseFloat(s);
    if (!isNaN(num)) {
      if (num > 1.05) return `${s} (⬇️ 显著重于空气，沉降滞留于低洼及下水道)`;
      if (num < 0.95) return `${s} (⬆️ 显著轻于空气，上升扩散并易积聚于顶部)`;
      return `${s} (≈ 与空气相近)`;
    }
    return s;
  }

  function getSignBadge(color, text) {
    const span = textNode('span', text, `hazmat-badge badge-${color || 'default'}`);
    return span;
  }

  function getWaterBadge(reactivity) {
    if (reactivity === 'forbidden') {
      return textNode('span', '🚫 严禁用水！', 'hazmat-water-badge water-forbidden');
    }
    if (reactivity === 'reactive') {
      return textNode('span', '⚠️ 遇水剧烈反应', 'hazmat-water-badge water-reactive');
    }
    return textNode('span', '💧 可规程用水', 'hazmat-water-badge water-normal');
  }

  async function loadHazmats() {
    const parent = container();
    if (!parent || parent.hidden) return;

    const listContainer = $('hazmat-list');
    if (!listContainer) return;
    listContainer.replaceChildren(textNode('p', '正在加载危化品数据…', 'hazmat-loading'));

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
      renderList(res.items || []);
      renderPagination();
    } catch (err) {
      listContainer.replaceChildren(textNode('p', `加载失败：${err.message}`, 'hazmat-error'));
    }
  }

  function renderPagination() {
    const pager = $('hazmat-pager');
    if (!pager) return;
    pager.replaceChildren();

    const maxPage = Math.max(0, Math.ceil(totalCount / pageSize) - 1);
    const summary = textNode('span', `共 ${totalCount} 条记录，第 ${currentPage + 1} / ${maxPage + 1} 页`, 'hazmat-page-info');

    const prevBtn = textNode('button', '上一页', 'btn-subtle');
    prevBtn.disabled = currentPage <= 0;
    prevBtn.onclick = () => {
      if (currentPage > 0) {
        currentPage--;
        loadHazmats();
      }
    };

    const nextBtn = textNode('button', '下一页', 'btn-subtle');
    nextBtn.disabled = currentPage >= maxPage;
    nextBtn.onclick = () => {
      if (currentPage < maxPage) {
        currentPage++;
        loadHazmats();
      }
    };

    pager.append(summary, prevBtn, nextBtn);
  }

  function renderList(items) {
    const listContainer = $('hazmat-list');
    if (!listContainer) return;
    listContainer.replaceChildren();

    if (items.length === 0) {
      listContainer.append(textNode('p', '暂无符合条件的危化品记录。您可以点击右上角“+ 新增危化品”或“批量导入”。', 'hazmat-empty'));
      return;
    }

    for (const item of items) {
      const card = document.createElement('article');
      card.className = 'hazmat-card';

      // 顶部行：UN号、中文名、英文名、操作按钮
      const headerRow = document.createElement('div');
      headerRow.className = 'hazmat-card-header';

      const titleGroup = document.createElement('div');
      titleGroup.className = 'hazmat-title-group';

      if (item.un_number) {
        titleGroup.append(textNode('span', `UN ${item.un_number}`, 'hazmat-un-code'));
      }
      titleGroup.append(textNode('h3', item.name_cn, 'hazmat-name-cn'));
      if (item.name_en) {
        titleGroup.append(textNode('span', item.name_en, 'hazmat-name-en'));
      }
      if (item.cas_number) {
        titleGroup.append(textNode('span', `CAS: ${item.cas_number}`, 'hazmat-cas'));
      }

      const actions = document.createElement('div');
      actions.className = 'hazmat-card-actions';

      const editBtn = textNode('button', '编辑', 'btn-subtle');
      editBtn.onclick = () => openEditModal(item);

      const delBtn = textNode('button', '删除', 'btn-danger-subtle');
      delBtn.onclick = async () => {
        if (!confirm(`确定要删除危化品「${item.name_cn}」(UN ${item.un_number || '-'}) 吗？`)) return;
        try {
          await api(`/hazmats/${encodeURIComponent(item.id)}`, undefined, 'DELETE');
          loadHazmats();
        } catch (err) {
          alert(`删除失败：${err.message}`);
        }
      };

      actions.append(editBtn, delBtn);
      headerRow.append(titleGroup, actions);
      card.append(headerRow);

      // 别名与标签行
      const metaRow = document.createElement('div');
      metaRow.className = 'hazmat-meta-row';

      if (item.danger_category) {
        metaRow.append(getSignBadge(item.danger_sign_color, item.danger_category));
      }
      metaRow.append(getWaterBadge(item.water_reactivity));

      if (item.matched_alias) {
        const matchTag = textNode('span', `🎯 命中别名：${item.matched_alias}`, 'hazmat-alias-hit');
        metaRow.append(matchTag);
      }

      if (Array.isArray(item.aliases) && item.aliases.length > 0) {
        const aliasBox = document.createElement('div');
        aliasBox.className = 'hazmat-aliases-box';
        aliasBox.append(textNode('span', '别名/俗名: ', 'hazmat-alias-label'));
        for (const a of item.aliases) {
          aliasBox.append(textNode('span', a, 'hazmat-alias-pill'));
        }
        metaRow.append(aliasBox);
      }

      card.append(metaRow);

      // 核心处置区 (救援红黄绿卡)
      const actionGrid = document.createElement('div');
      actionGrid.className = 'hazmat-grid';

      if (item.danger_summary) {
        const summaryBox = document.createElement('div');
        summaryBox.className = 'hazmat-grid-full hazmat-summary-box';
        summaryBox.append(textNode('strong', '核心危险：'));
        summaryBox.append(textNode('span', item.danger_summary));
        actionGrid.append(summaryBox);
      }

      // 禁用灭火剂（红线强警示）
      const forbiddenBox = document.createElement('div');
      forbiddenBox.className = 'hazmat-grid-item hazmat-forbidden-box';
      forbiddenBox.append(textNode('div', '🚫 禁忌灭火剂（红线禁令）', 'hazmat-box-title title-forbidden'));
      forbiddenBox.append(textNode('div', item.forbidden_agents || '无特殊禁忌（按常规规程）', 'hazmat-box-content'));
      actionGrid.append(forbiddenBox);

      // 推荐有效灭火剂
      const agentBox = document.createElement('div');
      agentBox.className = 'hazmat-grid-item hazmat-agent-box';
      agentBox.append(textNode('div', '🧯 推荐灭火药剂', 'hazmat-box-title title-agent'));
      agentBox.append(textNode('div', item.extinguishing_agents || '干粉、二氧化碳、雾状水等', 'hazmat-box-content'));
      actionGrid.append(agentBox);

      // 防护与隔离
      const protectBox = document.createElement('div');
      protectBox.className = 'hazmat-grid-item';
      protectBox.append(textNode('div', '🛡️ 防护等级要求', 'hazmat-box-title'));
      protectBox.append(textNode('div', item.protective_level || '常规正压空呼器', 'hazmat-box-content'));
      actionGrid.append(protectBox);

      // 隔离距离
      const distBox = document.createElement('div');
      distBox.className = 'hazmat-grid-item';
      distBox.append(textNode('div', '📏 应急隔离警戒距离', 'hazmat-box-title'));
      distBox.append(textNode('div', item.isolation_distance || '依据现场实际划定', 'hazmat-box-content'));
      actionGrid.append(distBox);

      // 泄漏处置与急救折叠详情
      const details = document.createElement('details');
      details.className = 'hazmat-details';
      const summary = textNode('summary', '查看现场理化、泄漏处置与洗消急救详情…');
      details.append(summary);

      const detailContent = document.createElement('div');
      detailContent.className = 'hazmat-detail-content';

      if (item.vapor_density) {
        const p = document.createElement('p');
        p.append(textNode('strong', '蒸气相对密度：'));
        p.append(textNode('span', formatVaporDensity(item.vapor_density)));
        detailContent.append(p);
      }
      if (item.flash_point || item.explosion_limit) {
        const p = document.createElement('p');
        p.append(textNode('strong', '闪点 / 爆炸极限：'));
        p.append(textNode('span', `${item.flash_point || '无'} / ${item.explosion_limit || '无'}`));
        detailContent.append(p);
      }
      if (item.appearance) {
        const p = document.createElement('p');
        p.append(textNode('strong', '外观性状：'));
        p.append(textNode('span', item.appearance));
        detailContent.append(p);
      }
      if (item.leak_handling) {
        const p = document.createElement('p');
        p.append(textNode('strong', '泄漏处置要点：'));
        p.append(textNode('span', item.leak_handling));
        detailContent.append(p);
      }
      if (item.first_aid) {
        const p = document.createElement('p');
        p.append(textNode('strong', '现场急救洗消：'));
        p.append(textNode('span', item.first_aid));
        detailContent.append(p);
      }
      if (item.firefighting_tips) {
        const p = document.createElement('p');
        p.append(textNode('strong', '战术扑救要点：'));
        p.append(textNode('span', item.firefighting_tips));
        detailContent.append(p);
      }
      if (item.notes) {
        const p = document.createElement('p');
        p.append(textNode('strong', '补充备注：'));
        p.append(textNode('span', item.notes));
        detailContent.append(p);
      }

      details.append(detailContent);

      card.append(actionGrid, details);
      listContainer.append(card);
    }
  }

  function initHazmatUI() {
    const parent = container();
    if (!parent) return;

    parent.replaceChildren();

    // 头部大标题与功能说明
    const header = document.createElement('div');
    header.className = 'hazmat-header';
    header.append(
      textNode('h2', '危化品应急速查库', 'hazmat-title'),
      textNode('p', '专为消防灭火与抢险救援现场设计。重点核查水反应性、禁用灭火剂、防护装备与应急隔离圈。支持一品多别名即时检索。', 'muted')
    );

    // 检索与操作工具条
    const toolbar = document.createElement('div');
    toolbar.className = 'hazmat-toolbar';

    // 搜索框
    const searchInput = document.createElement('input');
    searchInput.type = 'search';
    searchInput.placeholder = '输入品名、多别名(如氯仿)、UN号(如1203)、CAS号检索…';
    searchInput.className = 'hazmat-search-input';
    let searchDebounce;
    searchInput.oninput = () => {
      clearTimeout(searchDebounce);
      searchDebounce = setTimeout(() => {
        currentQuery = searchInput.value.trim();
        currentPage = 0;
        loadHazmats();
      }, 300);
    };

    // 水反应性筛选
    const waterSelect = document.createElement('select');
    waterSelect.className = 'hazmat-select';
    waterSelect.append(
      textNode('option', '全部水反应性'),
      Object.assign(textNode('option', '🚫 严禁用水'), { value: 'forbidden' }),
      Object.assign(textNode('option', '⚠️ 遇水反应'), { value: 'reactive' }),
      Object.assign(textNode('option', '💧 常规可用水'), { value: 'normal' })
    );
    waterSelect.onchange = () => {
      currentWater = waterSelect.value;
      currentPage = 0;
      loadHazmats();
    };

    // 类别筛选
    const catSelect = document.createElement('select');
    catSelect.className = 'hazmat-select';
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

    // 按钮组
    const btnGroup = document.createElement('div');
    btnGroup.className = 'hazmat-btn-group';

    const addBtn = textNode('button', '+ 新增危化品', 'btn-primary');
    addBtn.onclick = () => openEditModal(null);

    const importBtn = textNode('button', '批量导入 (Excel/CSV)', 'btn-secondary');
    importBtn.onclick = () => openImportModal();

    const tmplBtn = textNode('button', '下载导入模板', 'btn-subtle');
    tmplBtn.onclick = () => {
      window.location.href = '/api/admin/hazmats/template?format=xlsx';
    };

    btnGroup.append(addBtn, importBtn, tmplBtn);
    toolbar.append(searchInput, waterSelect, catSelect, btnGroup);

    // 列表容器与分页条
    const list = document.createElement('div');
    list.id = 'hazmat-list';

    const pager = document.createElement('div');
    pager.id = 'hazmat-pager';
    pager.className = 'hazmat-pager';

    parent.append(header, toolbar, list, pager);
  }

  // 手工录入与编辑模态框
  function openEditModal(item) {
    closeModal();
    const isEdit = Boolean(item);

    const overlay = document.createElement('div');
    overlay.className = 'hazmat-modal-overlay';

    const modal = document.createElement('div');
    modal.className = 'hazmat-modal';

    const modalHeader = document.createElement('div');
    modalHeader.className = 'hazmat-modal-header';
    modalHeader.append(textNode('h3', isEdit ? `编辑危化品：${item.name_cn}` : '手工新增危化品'));

    const closeBtn = textNode('button', '×', 'hazmat-modal-close');
    closeBtn.onclick = closeModal;
    modalHeader.append(closeBtn);

    const form = document.createElement('form');
    form.className = 'hazmat-form';

    // 1. 基础标识区
    const sec1 = document.createElement('fieldset');
    sec1.append(textNode('legend', '一、基础标识与多别名'));

    const row1 = document.createElement('div');
    row1.className = 'hazmat-form-row';

    const nameCnLabel = textNode('label', '中文品名 (必填)*');
    const nameCnInput = document.createElement('input');
    nameCnInput.required = true;
    nameCnInput.value = item?.name_cn || '';
    nameCnInput.placeholder = '例：三氯甲烷、金属钠';
    nameCnLabel.append(nameCnInput);

    const nameEnLabel = textNode('label', '英文名称');
    const nameEnInput = document.createElement('input');
    nameEnInput.value = item?.name_en || '';
    nameEnInput.placeholder = '例：Chloroform';
    nameEnLabel.append(nameEnInput);

    row1.append(nameCnLabel, nameEnLabel);

    const row2 = document.createElement('div');
    row2.className = 'hazmat-form-row';

    const unLabel = textNode('label', 'UN 编号 (4位代码)');
    const unInput = document.createElement('input');
    unInput.value = item?.un_number || '';
    unInput.placeholder = '例：1888、1203';
    unLabel.append(unInput);

    const casLabel = textNode('label', 'CAS 登记号');
    const casInput = document.createElement('input');
    casInput.value = item?.cas_number || '';
    casInput.placeholder = '例：67-66-3';
    casLabel.append(casInput);

    row2.append(unLabel, casLabel);

    // 多别名 Tag 胶囊录入器
    const aliasBox = document.createElement('div');
    aliasBox.className = 'hazmat-alias-editor';
    aliasBox.append(textNode('label', '别名 / 俗名 / 商品名 / 化学式 (支持多个，输入后回车或逗号添加)'));

    let aliasList = Array.isArray(item?.aliases) ? [...item.aliases] : [];
    const tagContainer = document.createElement('div');
    tagContainer.className = 'hazmat-tag-container';

    function renderTags() {
      tagContainer.replaceChildren();
      for (let i = 0; i < aliasList.length; i++) {
        const tag = textNode('span', aliasList[i], 'hazmat-tag-pill');
        const delTag = textNode('span', '×', 'hazmat-tag-del');
        delTag.onclick = () => {
          aliasList.splice(i, 1);
          renderTags();
        };
        tag.append(delTag);
        tagContainer.append(tag);
      }
    }
    renderTags();

    const tagInput = document.createElement('input');
    tagInput.type = 'text';
    tagInput.placeholder = '输入别名按回车添加 (如：氯仿、三氯代甲烷、CHCl3)';
    tagInput.onkeydown = (e) => {
      if (e.key === 'Enter' || e.key === ',' || e.key === '，' || e.key === ';') {
        e.preventDefault();
        const v = tagInput.value.trim();
        if (v && !aliasList.includes(v)) {
          aliasList.push(v);
          tagInput.value = '';
          renderTags();
        }
      }
    };

    aliasBox.append(tagContainer, tagInput);
    sec1.append(row1, row2, aliasBox);

    // 2. 危险等级与水反应性
    const sec2 = document.createElement('fieldset');
    sec2.append(textNode('legend', '二、危险等级与水反应特性'));

    const row3 = document.createElement('div');
    row3.className = 'hazmat-form-row';

    const catLabel = textNode('label', '危险性类别');
    const catInput = document.createElement('input');
    catInput.value = item?.danger_category || '';
    catInput.placeholder = '例：第4.3项 遇水放出易燃气体的物质';
    catLabel.append(catInput);

    const waterLabel = textNode('label', '水反应特性 (灭火决策核心！)*');
    const waterInput = document.createElement('select');
    waterInput.append(
      Object.assign(textNode('option', '💧 可规程用水灭火'), { value: 'normal' }),
      Object.assign(textNode('option', '⚠️ 遇水反应/剧烈水解'), { value: 'reactive' }),
      Object.assign(textNode('option', '🚫 严禁用水！(剧烈爆炸或产毒)'), { value: 'forbidden' })
    );
    waterInput.value = item?.water_reactivity || 'normal';
    waterLabel.append(waterInput);

    row3.append(catLabel, waterLabel);

    const summaryLabel = textNode('label', '核心危险概述 (现场一眼看清)');
    const summaryInput = document.createElement('input');
    summaryInput.value = item?.danger_summary || '';
    summaryInput.placeholder = '例：剧烈遇水反应！放出大量氢气爆炸；遇明火产生剧毒光气';
    summaryLabel.append(summaryInput);

    sec2.append(row3, summaryLabel);

    // 3. 消防应急灭火（核心红线）
    const sec3 = document.createElement('fieldset');
    sec3.append(textNode('legend', '三、消防措施与现场防护（救命要点）'));

    const forbidLabel = textNode('label', '🚫 禁用灭火剂及禁忌物 (红线警示！)');
    const forbidInput = document.createElement('textarea');
    forbidInput.rows = 2;
    forbidInput.value = item?.forbidden_agents || '';
    forbidInput.placeholder = '例：严禁出水！严禁泡沫！严禁酸碱灭火剂！严禁直流水枪冲击液体飞溅！';
    forbidLabel.append(forbidInput);

    const agentLabel = textNode('label', '🧯 推荐灭火药剂 (注明是否需抗溶泡沫)');
    const agentInput = document.createElement('textarea');
    agentInput.rows = 2;
    agentInput.value = item?.extinguishing_agents || '';
    agentInput.placeholder = '例：干砂、D类金属专用干粉；极性溶剂请务必使用抗溶性泡沫(AR-AFFF)';
    agentLabel.append(agentInput);

    const row4 = document.createElement('div');
    row4.className = 'hazmat-form-row';

    const protLabel = textNode('label', '防护装备等级');
    const protInput = document.createElement('input');
    protInput.value = item?.protective_level || '';
    protInput.placeholder = '例：正压式空气呼吸器 + 一级全封闭特级防化服';
    protLabel.append(protInput);

    const distLabel = textNode('label', '应急隔离与疏散警戒距离');
    const distInput = document.createElement('input');
    distInput.value = item?.isolation_distance || '';
    distInput.placeholder = '例：小泄漏初期隔离60米；槽车大火周围隔离800米';
    distLabel.append(distInput);

    row4.append(protLabel, distLabel);

    sec3.append(forbidLabel, agentLabel, row4);

    // 4. 现场理化与急救
    const sec4 = document.createElement('fieldset');
    sec4.append(textNode('legend', '四、现场理化参数 (精炼) 与洗消急救'));

    const row5 = document.createElement('div');
    row5.className = 'hazmat-form-row';

    const vaporLabel = textNode('label', '蒸气相对密度 (空气=1)');
    const vaporInput = document.createElement('input');
    vaporInput.value = item?.vapor_density || '';
    vaporInput.placeholder = '例：4.12 (大于1沿地面沉降，小于1升空)';
    vaporLabel.append(vaporInput);

    const flashLabel = textNode('label', '闪点 / 爆炸极限');
    const flashInput = document.createElement('input');
    flashInput.value = item?.flash_point ? `${item.flash_point} / ${item.explosion_limit || ''}` : (item?.explosion_limit || '');
    flashInput.placeholder = '例：-20℃ / 1.2%～90.5%';
    flashLabel.append(flashInput);

    row5.append(vaporLabel, flashLabel);

    const row6 = document.createElement('div');
    row6.className = 'hazmat-form-row';

    const leakLabel = textNode('label', '泄漏堵漏与围堤要点');
    const leakInput = document.createElement('textarea');
    leakInput.rows = 2;
    leakInput.value = item?.leak_handling || '';
    leakInput.placeholder = '例：构筑砂土围堤防流入下水道；覆盖泡沫防挥发';
    leakLabel.append(leakInput);

    const aidLabel = textNode('label', '伤员现场洗消与急救');
    const aidInput = document.createElement('textarea');
    aidInput.rows = 2;
    aidInput.value = item?.first_aid || '';
    aidInput.placeholder = '例：脱去污染衣物，流动清水冲洗眼睛至少15分钟';
    aidLabel.append(aidInput);

    row6.append(leakLabel, aidLabel);
    sec4.append(row5, row6);

    // 底部保存按钮
    const footer = document.createElement('div');
    footer.className = 'hazmat-modal-footer';

    const cancelBtn = textNode('button', '取消', 'btn-subtle');
    cancelBtn.type = 'button';
    cancelBtn.onclick = closeModal;

    const saveBtn = textNode('button', isEdit ? '保存修改' : '确认录入', 'btn-primary');
    saveBtn.type = 'submit';

    footer.append(cancelBtn, saveBtn);

    form.append(sec1, sec2, sec3, sec4, footer);

    form.onsubmit = async (e) => {
      e.preventDefault();
      const payload = {
        name_cn: nameCnInput.value.trim(),
        name_en: nameEnInput.value.trim(),
        aliases: aliasList,
        un_number: unInput.value.trim(),
        cas_number: casInput.value.trim(),
        danger_category: catInput.value.trim(),
        water_reactivity: waterInput.value,
        danger_summary: summaryInput.value.trim(),
        forbidden_agents: forbidInput.value.trim(),
        extinguishing_agents: agentInput.value.trim(),
        protective_level: protInput.value.trim(),
        isolation_distance: distInput.value.trim(),
        vapor_density: vaporInput.value.trim(),
        flash_point: flashInput.value.trim(),
        leak_handling: leakInput.value.trim(),
        first_aid: aidInput.value.trim()
      };

      saveBtn.disabled = true;
      saveBtn.textContent = '正在保存…';
      try {
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
        saveBtn.textContent = isEdit ? '保存修改' : '确认录入';
      }
    };

    modal.append(modalHeader, form);
    overlay.append(modal);
    document.body.append(overlay);
    activeModal = overlay;
  }

  // 批量导入模态框
  function openImportModal() {
    closeModal();
    const overlay = document.createElement('div');
    overlay.className = 'hazmat-modal-overlay';

    const modal = document.createElement('div');
    modal.className = 'hazmat-modal hazmat-modal-import';

    const header = document.createElement('div');
    header.className = 'hazmat-modal-header';
    header.append(textNode('h3', '批量导入危险化学品数据'));

    const closeBtn = textNode('button', '×', 'hazmat-modal-close');
    closeBtn.onclick = closeModal;
    header.append(closeBtn);

    const body = document.createElement('div');
    body.className = 'hazmat-import-body';

    const tip = textNode('p', '支持上传 .xlsx 或 .csv 文件。多别名在“别名/俗名”列中使用分号、逗号或竖线分隔即可。建议先下载标准模板。', 'muted');

    const fileLabel = document.createElement('label');
    fileLabel.className = 'hazmat-file-dropzone';
    const fileInput = document.createElement('input');
    fileInput.type = 'file';
    fileInput.accept = '.xlsx,.xls,.csv';

    const dropText = textNode('span', '点击选择文件 或 将 Excel/CSV 文件拖拽至此处');
    fileLabel.append(fileInput, dropText);

    fileInput.onchange = () => {
      if (fileInput.files?.[0]) {
        dropText.textContent = `已选择文件：${fileInput.files[0].name} (${(fileInput.files[0].size / 1024).toFixed(1)} KB)`;
      }
    };

    const optLabel = document.createElement('label');
    optLabel.className = 'hazmat-checkbox-label';
    const overwriteBox = document.createElement('input');
    overwriteBox.type = 'checkbox';
    optLabel.append(overwriteBox, textNode('span', '如果中文品名已存在，覆盖更新已有危化品信息'));

    const resultBox = document.createElement('div');
    resultBox.className = 'hazmat-import-result';
    resultBox.hidden = true;

    const footer = document.createElement('div');
    footer.className = 'hazmat-modal-footer';

    const cancelBtn = textNode('button', '关闭', 'btn-subtle');
    cancelBtn.onclick = closeModal;

    const uploadBtn = textNode('button', '开始导入', 'btn-primary');
    uploadBtn.onclick = async () => {
      const file = fileInput.files?.[0];
      if (!file) {
        alert('请先选择要上传的 Excel 或 CSV 文件！');
        return;
      }

      uploadBtn.disabled = true;
      uploadBtn.textContent = '正在解析与导入…';
      resultBox.hidden = false;
      resultBox.replaceChildren(textNode('p', '正在上传并执行批量入库事务，请稍候…'));

      const formData = new FormData();
      formData.append('file', file);
      if (overwriteBox.checked) formData.append('overwrite', 'true');

      try {
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
          throw new Error(res.error || res.code || '导入请求失败');
        }

        resultBox.replaceChildren();
        const successTitle = textNode('h4', '🎉 导入完成报告', 'text-success');
        const stats = textNode('p', `总行数：${res.totalRows} | 成功新增：${res.imported} 条 | 覆盖更新：${res.updated} 条 | 跳过：${res.skipped} 条`);
        resultBox.append(successTitle, stats);

        if (Array.isArray(res.errors) && res.errors.length > 0) {
          const errList = document.createElement('ul');
          errList.className = 'hazmat-err-list';
          for (const err of res.errors) {
            errList.append(textNode('li', `第 ${err.row} 行「${err.name || '未知品名'}」: ${err.message}`));
          }
          resultBox.append(textNode('p', '⚠️ 异常行明细：', 'text-warning'), errList);
        }

        uploadBtn.textContent = '导入完成';
        loadHazmats();
      } catch (err) {
        resultBox.replaceChildren(textNode('p', `导入失败：${err.message}`, 'text-danger'));
        uploadBtn.disabled = false;
        uploadBtn.textContent = '重新导入';
      }
    };

    footer.append(cancelBtn, uploadBtn);
    body.append(tip, fileLabel, optLabel, resultBox);
    modal.append(header, body, footer);
    overlay.append(modal);
    document.body.append(overlay);
    activeModal = overlay;
  }

  function closeModal() {
    if (activeModal) {
      activeModal.remove();
      activeModal = null;
    }
  }

  // 挂载生命周期监听
  document.addEventListener('admin-ready', () => {
    initHazmatUI();
  });

  document.addEventListener('admin-ended', () => {
    closeModal();
    const parent = container();
    if (parent) parent.replaceChildren();
  });

  document.addEventListener('hazmat-tab-activated', () => {
    initHazmatUI();
    loadHazmats();
  });
})();
