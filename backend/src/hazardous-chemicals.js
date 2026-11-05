const crypto = require('node:crypto');
const xlsx = require('xlsx');

function cleanString(val) {
  return typeof val === 'string' ? val.trim() : (val === null || val === undefined ? '' : String(val).trim());
}

function cleanAliases(val) {
  if (Array.isArray(val)) {
    return Array.from(new Set(val.map(cleanString).filter(Boolean)));
  }
  if (typeof val === 'string') {
    const parts = val.split(/[;,，；|/、\n\r]+/).map(s => s.trim()).filter(Boolean);
    return Array.from(new Set(parts));
  }
  return [];
}

function normalizeWaterReactivity(val, forbiddenText = '') {
  const s = cleanString(val).toLowerCase();
  const f = cleanString(forbiddenText).toLowerCase();
  if (s === 'forbidden' || s.includes('严禁用水') || s.includes('禁水') || f.includes('严禁用水') || f.includes('禁水')) {
    return 'forbidden';
  }
  if (s === 'reactive' || s.includes('遇水') || s.includes('水解') || f.includes('遇水') || f.includes('水解')) {
    return 'reactive';
  }
  return 'normal';
}

function normalizeSignColor(category = '', explicitColor = '') {
  const color = cleanString(explicitColor).toLowerCase();
  if (['red', 'blue', 'yellow', 'white', 'black_white'].includes(color)) return color;
  const cat = cleanString(category);
  if (cat.includes('4.3') || cat.includes('遇水') || cat.includes('遇湿')) return 'blue';
  if (cat.includes('3') || cat.includes('易燃') || cat.includes('2.1')) return 'red';
  if (cat.includes('5') || cat.includes('氧化') || cat.includes('过氧化')) return 'yellow';
  if (cat.includes('6') || cat.includes('2.3') || cat.includes('毒')) return 'white';
  if (cat.includes('8') || cat.includes('腐蚀')) return 'black_white';
  return '';
}

function createHazardousChemicals(store) {
  async function query(sql, params) {
    return store.query(sql, params);
  }

  async function resolveActorId(actorId) {
    if (!actorId) return null;
    try {
      const res = await query('SELECT id FROM unit_members WHERE id = $1 LIMIT 1', [actorId]);
      return res.rows[0]?.id || null;
    } catch {
      return null;
    }
  }

  return {
    async list({ query: q = '', category = '', water = '', limit = 50, offset = 0, activeOnly = true } = {}) {
      const conditions = [];
      const params = [];
      let idx = 1;

      if (activeOnly) {
        conditions.push(`active = true`);
      }

      const trimmedQ = cleanString(q);
      if (trimmedQ) {
        params.push(`%${trimmedQ}%`);
        conditions.push(`(
          name_cn ILIKE $${idx} OR
          name_en ILIKE $${idx} OR
          un_number ILIKE $${idx} OR
          cas_number ILIKE $${idx} OR
          array_to_string(aliases, ' ') ILIKE $${idx}
        )`);
        idx++;
      }

      if (cleanString(category)) {
        params.push(`%${cleanString(category)}%`);
        conditions.push(`danger_category ILIKE $${idx}`);
        idx++;
      }

      if (cleanString(water)) {
        params.push(cleanString(water));
        conditions.push(`water_reactivity = $${idx}`);
        idx++;
      }

      const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

      const countSql = `SELECT COUNT(*) AS total FROM hazardous_chemicals ${whereClause}`;
      const countRes = await query(countSql, params);
      const total = parseInt(countRes.rows[0]?.total || '0', 10);

      const pageParams = [...params, limit, offset];
      const dataSql = `
        SELECT * FROM hazardous_chemicals
        ${whereClause}
        ORDER BY updated_at DESC
        LIMIT $${idx} OFFSET $${idx + 1}
      `;
      const dataRes = await query(dataSql, pageParams);

      const items = dataRes.rows.map(row => {
        let matchedAlias = '';
        if (trimmedQ && Array.isArray(row.aliases)) {
          const lowerQ = trimmedQ.toLowerCase();
          const found = row.aliases.find(a => a.toLowerCase().includes(lowerQ));
          if (found && !row.name_cn.toLowerCase().includes(lowerQ)) {
            matchedAlias = found;
          }
        }
        return {
          ...row,
          matched_alias: matchedAlias
        };
      });

      return { total, items, limit, offset };
    },

    async getById(id) {
      const res = await query('SELECT * FROM hazardous_chemicals WHERE id = $1', [id]);
      return res.rows[0] || null;
    },

    async create(data, actorId = null) {
      const nameCn = cleanString(data.name_cn);
      if (!nameCn) {
        const err = new Error('危化品中文名称不能为空');
        err.status = 400;
        err.code = 'HAZMAT_NAME_REQUIRED';
        throw err;
      }

      const id = cleanString(data.id) || crypto.randomUUID();
      const now = Date.now();
      const aliases = cleanAliases(data.aliases);
      const waterReactivity = normalizeWaterReactivity(data.water_reactivity, data.forbidden_agents);
      const dangerSignColor = normalizeSignColor(data.danger_category, data.danger_sign_color);
      const validActorId = await resolveActorId(actorId);

      const sql = `
        INSERT INTO hazardous_chemicals (
          id, name_cn, name_en, aliases, un_number, cas_number,
          danger_category, danger_sign_color, water_reactivity, danger_summary,
          forbidden_agents, extinguishing_agents, firefighting_tips,
          protective_level, isolation_distance, leak_handling, first_aid,
          appearance, flash_point, explosion_limit, vapor_density, notes,
          active, created_by, updated_by, created_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, $5, $6,
          $7, $8, $9, $10,
          $11, $12, $13,
          $14, $15, $16, $17,
          $18, $19, $20, $21, $22,
          true, $23, $23, $24, $24
        ) RETURNING *
      `;

      const values = [
        id,
        nameCn,
        cleanString(data.name_en),
        aliases,
        cleanString(data.un_number),
        cleanString(data.cas_number),
        cleanString(data.danger_category),
        dangerSignColor,
        waterReactivity,
        cleanString(data.danger_summary),
        cleanString(data.forbidden_agents),
        cleanString(data.extinguishing_agents),
        cleanString(data.firefighting_tips),
        cleanString(data.protective_level),
        cleanString(data.isolation_distance),
        cleanString(data.leak_handling),
        cleanString(data.first_aid),
        cleanString(data.appearance),
        cleanString(data.flash_point),
        cleanString(data.explosion_limit),
        cleanString(data.vapor_density),
        cleanString(data.notes),
        validActorId,
        now
      ];

      const res = await query(sql, values);
      return res.rows[0];
    },

    async update(id, data, actorId = null) {
      const existing = await this.getById(id);
      if (!existing) {
        const err = new Error('危化品记录不存在');
        err.status = 404;
        err.code = 'HAZMAT_NOT_FOUND';
        throw err;
      }

      const nameCn = data.name_cn !== undefined ? cleanString(data.name_cn) : existing.name_cn;
      if (!nameCn) {
        const err = new Error('危化品中文名称不能为空');
        err.status = 400;
        err.code = 'HAZMAT_NAME_REQUIRED';
        throw err;
      }

      const aliases = data.aliases !== undefined ? cleanAliases(data.aliases) : existing.aliases;
      const forbiddenAgents = data.forbidden_agents !== undefined ? cleanString(data.forbidden_agents) : existing.forbidden_agents;
      const waterReactivity = data.water_reactivity !== undefined
        ? normalizeWaterReactivity(data.water_reactivity, forbiddenAgents)
        : existing.water_reactivity;
      const dangerCategory = data.danger_category !== undefined ? cleanString(data.danger_category) : existing.danger_category;
      const dangerSignColor = data.danger_sign_color !== undefined
        ? normalizeSignColor(dangerCategory, data.danger_sign_color)
        : normalizeSignColor(dangerCategory, existing.danger_sign_color);

      const now = Date.now();
      const validActorId = await resolveActorId(actorId);
      const sql = `
        UPDATE hazardous_chemicals SET
          name_cn = $1,
          name_en = $2,
          aliases = $3,
          un_number = $4,
          cas_number = $5,
          danger_category = $6,
          danger_sign_color = $7,
          water_reactivity = $8,
          danger_summary = $9,
          forbidden_agents = $10,
          extinguishing_agents = $11,
          firefighting_tips = $12,
          protective_level = $13,
          isolation_distance = $14,
          leak_handling = $15,
          first_aid = $16,
          appearance = $17,
          flash_point = $18,
          explosion_limit = $19,
          vapor_density = $20,
          notes = $21,
          updated_by = $22,
          updated_at = $23
        WHERE id = $24
        RETURNING *
      `;

      const values = [
        nameCn,
        data.name_en !== undefined ? cleanString(data.name_en) : existing.name_en,
        aliases,
        data.un_number !== undefined ? cleanString(data.un_number) : existing.un_number,
        data.cas_number !== undefined ? cleanString(data.cas_number) : existing.cas_number,
        dangerCategory,
        dangerSignColor,
        waterReactivity,
        data.danger_summary !== undefined ? cleanString(data.danger_summary) : existing.danger_summary,
        forbiddenAgents,
        data.extinguishing_agents !== undefined ? cleanString(data.extinguishing_agents) : existing.extinguishing_agents,
        data.firefighting_tips !== undefined ? cleanString(data.firefighting_tips) : existing.firefighting_tips,
        data.protective_level !== undefined ? cleanString(data.protective_level) : existing.protective_level,
        data.isolation_distance !== undefined ? cleanString(data.isolation_distance) : existing.isolation_distance,
        data.leak_handling !== undefined ? cleanString(data.leak_handling) : existing.leak_handling,
        data.first_aid !== undefined ? cleanString(data.first_aid) : existing.first_aid,
        data.appearance !== undefined ? cleanString(data.appearance) : existing.appearance,
        data.flash_point !== undefined ? cleanString(data.flash_point) : existing.flash_point,
        data.explosion_limit !== undefined ? cleanString(data.explosion_limit) : existing.explosion_limit,
        data.vapor_density !== undefined ? cleanString(data.vapor_density) : existing.vapor_density,
        data.notes !== undefined ? cleanString(data.notes) : existing.notes,
        validActorId,
        now,
        id
      ];

      const res = await query(sql, values);
      return res.rows[0];
    },

    async remove(id, actorId = null) {
      const existing = await this.getById(id);
      if (!existing) {
        const err = new Error('危化品记录不存在');
        err.status = 404;
        err.code = 'HAZMAT_NOT_FOUND';
        throw err;
      }
      const now = Date.now();
      await query(
        'UPDATE hazardous_chemicals SET active = false, updated_by = $1, updated_at = $2 WHERE id = $3',
        [actorId, now, id]
      );
      return { ok: true, id };
    },

    async importBatch(buffer, filename = '', actorId = null, { overwrite = false } = {}) {
      let workbook;
      try {
        workbook = xlsx.read(buffer, { type: 'buffer' });
      } catch (err) {
        const error = new Error('文件解析失败，请确保上传有效的 Excel 或 CSV 文件');
        error.status = 400;
        error.code = 'HAZMAT_FILE_INVALID';
        throw error;
      }

      const sheetName = workbook.SheetNames[0];
      if (!sheetName) {
        return { totalRows: 0, imported: 0, updated: 0, skipped: 0, errors: [] };
      }

      const rows = xlsx.utils.sheet_to_json(workbook.Sheets[sheetName], { defval: '' });
      if (!rows || rows.length === 0) {
        return { totalRows: 0, imported: 0, updated: 0, skipped: 0, errors: [] };
      }

      const columnMap = {
        name_cn: ['中文名', '品名', '中文品名', '化学品名称', 'name_cn', '名称'],
        name_en: ['英文名', '英文名称', 'name_en'],
        aliases: ['别名', '俗名', '商品名', '别名/俗名', 'aliases'],
        un_number: ['UN号', 'UN编号', '联合国编号', 'un_number', 'UN代码'],
        cas_number: ['CAS号', 'CAS编号', 'cas_number'],
        danger_category: ['危险类别', '危险性类别', 'danger_category', '分类'],
        danger_sign_color: ['类别颜色', '色标', 'danger_sign_color'],
        water_reactivity: ['水反应性', '禁水标志', '禁水', 'water_reactivity'],
        danger_summary: ['核心风险', '危险概述', '危险性概述', 'danger_summary'],
        forbidden_agents: ['禁用灭火剂', '禁忌灭火剂', '严禁灭火剂', 'forbidden_agents'],
        extinguishing_agents: ['推荐灭火剂', '有效灭火剂', '灭火剂', 'extinguishing_agents'],
        firefighting_tips: ['扑救要点', '灭火要点', '战术要点', 'firefighting_tips'],
        protective_level: ['防护等级', '防护要求', '个体防护', 'protective_level'],
        isolation_distance: ['隔离距离', '疏散距离', '警戒距离', 'isolation_distance'],
        leak_handling: ['泄漏处置', '泄漏处理', '堵漏处置', 'leak_handling'],
        first_aid: ['急救措施', '急救洗消', '洗消急救', 'first_aid'],
        appearance: ['外观气味', '外观与性状', '外观', 'appearance'],
        flash_point: ['闪点', '自燃点', 'flash_point'],
        explosion_limit: ['爆炸极限', '爆炸范围', 'explosion_limit'],
        vapor_density: ['蒸气密度', '相对蒸气密度', '气密', 'vapor_density'],
        notes: ['备注', '注意事项', '补充说明', 'notes']
      };

      function extractFields(row) {
        const item = {};
        const keys = Object.keys(row);
        for (const [field, aliasesList] of Object.entries(columnMap)) {
          const matchedKey = keys.find(k => {
            const cleanKey = k.trim().toLowerCase();
            return aliasesList.some(a => a.toLowerCase() === cleanKey);
          });
          if (matchedKey) {
            item[field] = row[matchedKey];
          }
        }
        return item;
      }

      let imported = 0;
      let updated = 0;
      let skipped = 0;
      const errors = [];

      for (let i = 0; i < rows.length; i++) {
        const rawRow = rows[i];
        const rowData = extractFields(rawRow);
        const nameCn = cleanString(rowData.name_cn);

        if (!nameCn) {
          skipped++;
          continue;
        }

        try {
          const existingRes = await query(
            'SELECT id FROM hazardous_chemicals WHERE name_cn = $1 AND active = true LIMIT 1',
            [nameCn]
          );
          const existing = existingRes.rows[0];

          if (existing) {
            if (overwrite) {
              await this.update(existing.id, rowData, actorId);
              updated++;
            } else {
              skipped++;
            }
          } else {
            await this.create(rowData, actorId);
            imported++;
          }
        } catch (err) {
          errors.push({ row: i + 2, name: nameCn, message: err.message });
        }
      }

      return {
        totalRows: rows.length,
        imported,
        updated,
        skipped,
        errors
      };
    },

    generateTemplate(format = 'csv') {
      const sampleData = [
        {
          '中文名': '三氯甲烷',
          '英文名': 'Chloroform',
          '别名/俗名': '氯仿; 三氯代甲烷; CHCl3',
          'UN号': '1888',
          'CAS号': '67-66-3',
          '危险类别': '第6.1项 毒性物质',
          '水反应性': 'normal',
          '核心风险': '高毒不燃；遇明火高温光解生成剧毒光气',
          '禁用灭火剂': '严禁直接高压水枪强力冲击液体飞溅',
          '推荐灭火剂': '雾状水、二氧化碳、干粉、砂土',
          '扑救要点': '处于上风向；防光气中毒，严格防范次生剧毒',
          '防护等级': '正压式空气呼吸器 + 一级全封闭特级防化服',
          '隔离距离': '小泄漏初期隔离60米；火灾着火下风向疏散300米',
          '泄漏处置': '砂土或惰性吸附材料吸收，禁止冲入公共下水道',
          '急救措施': '立即移至空气新鲜处；脱去被污染衣物流动清水冲洗',
          '外观气味': '无色透明易挥发液体，有特殊甜味',
          '闪点': '不燃',
          '爆炸极限': '无',
          '相对蒸气密度': '4.12（显著沉降滞留于地表低洼处）',
          '备注': '遇明火产生剧毒光气'
        },
        {
          '中文名': '金属钠',
          '英文名': 'Sodium',
          '别名/俗名': '钠; Na',
          'UN号': '1428',
          'CAS号': '7440-23-5',
          '危险类别': '第4.3项 遇水放出易燃气体的物质',
          '水反应性': 'forbidden',
          '核心风险': '极度剧烈遇水反应！放出大量氢气和高热引发特大爆炸',
          '禁用灭火剂': '严禁用水、泡沫、二氧化碳、酸碱灭火剂！',
          '推荐灭火剂': '干砂、D类金属专用灭火干粉、石墨粉',
          '扑救要点': '绝对严禁出水！周围火势用水扑救时严防水滴溅入钠体',
          '防护等级': '正压式空气呼吸器 + 防静电灭火防护服',
          '隔离距离': '起火初期隔离100米；特大火灾周围隔离800米',
          '泄漏处置': '严禁水冲！用干燥砂土覆盖收集，放入干燥专用桶封闭',
          '急救措施': '皮肤接触切忌直接大量水冲，先用植物油或软纸擦去残渣后就医',
          '外观气味': '银白色蜡状软金属',
          '闪点': '易燃',
          '爆炸极限': '遇水产氢易爆炸',
          '相对蒸气密度': '0.97',
          '备注': '储存须浸于煤油或液体石蜡中'
        }
      ];

      const ws = xlsx.utils.json_to_sheet(sampleData);
      const wb = xlsx.utils.book_new();
      xlsx.utils.book_append_sheet(wb, ws, '危化品导入模板');

      if (format === 'xlsx') {
        return xlsx.write(wb, { type: 'buffer', bookType: 'xlsx' });
      } else {
        return xlsx.write(wb, { type: 'buffer', bookType: 'csv' });
      }
    }
  };
}

module.exports = {
  createHazardousChemicals,
  cleanAliases,
  normalizeWaterReactivity,
  normalizeSignColor
};
