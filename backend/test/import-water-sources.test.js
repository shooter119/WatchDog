'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Pool } = require('pg');

process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';

const {
  CONFLICTS_CSV_HEADERS,
  parseCsv,
  stringifyCsv,
  mapColorToStatus,
  classifyWaterSource,
  parseCoordinates,
  computeSourceKey,
  distanceMeters,
  detectColorNoteConflict,
  runDryRun,
  loadOverridesCsv,
  mergeImportRecords,
  runApply,
  parseCliArgs,
} = require('../scripts/import-water-sources');
const { createWaterSources } = require('../src/water-sources');

const FIXTURE_CSV = path.join(__dirname, 'fixtures', 'water-sources.example.csv');
const baseUrl = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const pool = new Pool({ connectionString: baseUrl });
const schema = `water_import_test_${process.pid}_${Date.now()}`;

let store;
let waterSources;

before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();

  store = require('../src/postgres-store');
  await store.ready;

  await store.query(
    "INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES('unit_import_1','示例消防救援大队','1001',1,1)",
  );

  waterSources = createWaterSources(store);
});

after(async () => {
  if (store && typeof store.close === 'function') {
    await store.close();
  }
  await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await pool.end();
});

test('parseCsv 支持 UTF-8 BOM、双引号转义与引号内嵌换行符', () => {
  const input = '\uFEFF名称,描述,位置编码\r\n"示例""A""点","第一行\n第二行","120.15,30.25"\r\n普通点,无换行,"120.16,30.26"';
  const rows = parseCsv(input);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows[0], ['名称', '描述', '位置编码']);
  assert.deepEqual(rows[1], ['示例"A"点', '第一行\n第二行', '120.15,30.25']);
  assert.deepEqual(rows[2], ['普通点', '无换行', '120.16,30.26']);
});

test('mapColorToStatus 遵循高德工作地图默认颜色映射', () => {
  assert.equal(mapColorToStatus('#FF6968'), 'available');
  assert.equal(mapColorToStatus('#7e97ff'), 'available');
  assert.equal(mapColorToStatus('7AB1F5'), 'available');
  assert.equal(mapColorToStatus('#FFBF00'), 'unavailable');
  assert.equal(mapColorToStatus('#00CC66'), null);
  assert.equal(mapColorToStatus(''), null);
});

test('classifyWaterSource 准确区分三类水源并按固定顺序提取取水方式', () => {
  assert.deepEqual(
    classifyWaterSource('测试广场水泵接合器', '高区喷淋'),
    { category: 'pump_connector', intake_methods: [] },
  );
  assert.deepEqual(
    classifyWaterSource('示例湖消防水池', '可远程供水，也支持消防车靠近和手抬泵吸水'),
    { category: 'natural', intake_methods: ['portable_pump', 'fire_truck', 'remote_supply'] },
  );
  assert.deepEqual(
    classifyWaterSource('星河鱼塘', '水深3米'),
    { category: 'natural', intake_methods: [] },
  );
  assert.deepEqual(
    classifyWaterSource('振兴路1号消火栓', '地上式'),
    { category: 'hydrant', intake_methods: [] },
  );
});

test('detectColorNoteConflict 准确识别矛盾且不被「无损坏」「不可用」否定词误判', () => {
  assert.equal(detectColorNoteConflict('available', '接口损坏无水'), true);
  assert.equal(detectColorNoteConflict('available', '阀门锈死'), true);
  assert.equal(detectColorNoteConflict('available', '巡检无损坏，压力正常'), false);
  assert.equal(detectColorNoteConflict('unavailable', '复检无损坏有水'), true);
  assert.equal(detectColorNoteConflict('unavailable', '正常出水'), true);
  assert.equal(detectColorNoteConflict('unavailable', '阀门锈死，暂时无水'), false);
  assert.equal(detectColorNoteConflict('unavailable', '不可用，待维修'), false);
});

test('parseCoordinates 与 distanceMeters 边界校验', () => {
  assert.deepEqual(parseCoordinates('120.150000,30.250000'), {
    valid: true,
    lat: 30.25,
    lng: 120.15,
    rawCoordString: '120.150000,30.250000',
  });
  assert.equal(parseCoordinates('0,0').valid, false);
  assert.equal(parseCoordinates('120.15,60.0').valid, false);
  assert.equal(parseCoordinates('无效坐标').valid, false);

  const d = distanceMeters(30.25, 120.15, 30.25001, 120.150015);
  assert.ok(d > 0 && d < 5, `期望距离在 0-5 米内，实际为 ${d}`);
});

test('computeSourceKey 基于原始未修改名称与原始经纬度生成不可变指纹', () => {
  const k1 = computeSourceKey('示例点A', '120.150000,30.250000');
  const k2 = computeSourceKey('示例点A', '120.150000,30.250000');
  const k3 = computeSourceKey('示例点A ', '120.150000,30.250000');
  const k4 = computeSourceKey('示例点A', '120.150000,30.250000', 2);
  assert.equal(k1, k2);
  assert.notEqual(k1, k3);
  assert.equal(k4, `${k1}#2`);
});

test('analyzeAmapCsv 与 --dry-run 完整覆盖样例：四类冲突、表尾截断、照片丢弃与同距不同类不误报', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-water-dryrun-'));
  try {
    const out = runDryRun({ csvPath: FIXTURE_CSV, outDir: tmpDir });

    assert.equal(out.stats.stopped_at_footer, true);
    assert.equal(out.stats.total_parsed, 14);
    assert.equal(out.stats.clean_count, 6);
    assert.equal(out.stats.conflict_count, 8);

    // 验证 clean.json 内容与照片列已彻底丢弃
    const cleanJsonText = fs.readFileSync(out.cleanPath, 'utf8');
    assert.equal(cleanJsonText.includes('amap-photo'), false);
    const cleanPayload = JSON.parse(cleanJsonText);
    assert.equal(cleanPayload.items.length, 6);

    const byName = new Map(cleanPayload.items.map((item) => [item.name, item]));
    // 验证引号内嵌换行符保留
    assert.equal(byName.get('示例大道1号市政消火栓').note, '地面式消火栓\n压力正常 0.4MPa');
    assert.equal(byName.get('示例大道1号市政消火栓').category, 'hydrant');
    // 验证 10 米内不同类别（水泵接合器 vs 消火栓）不误报重复
    assert.equal(byName.get('示例大道1号水泵接合器').category, 'pump_connector');
    assert.equal(byName.get('测试广场南侧消火栓').status, 'unavailable');
    assert.deepEqual(
      byName.get('示例湖西岸消防水池').intake_methods,
      ['portable_pump', 'fire_truck'],
    );
    assert.deepEqual(
      byName.get('星河河道天然水源').intake_methods,
      ['remote_supply'],
    );

    // 验证 conflicts.csv 列头与四类冲突精准检出
    const conflictsCsvText = fs.readFileSync(out.conflictsPath, 'utf8');
    assert.equal(conflictsCsvText.startsWith('\uFEFF'), true);
    assert.equal(conflictsCsvText.includes('amap-photo'), false);
    assert.equal(conflictsCsvText.includes('不应被解析'), false);

    const conflictRows = parseCsv(conflictsCsvText);
    assert.deepEqual(conflictRows[0], CONFLICTS_CSV_HEADERS);
    assert.equal(conflictRows.length, 9); // 1 header + 8 conflicts

    const conflictByName = new Map(conflictRows.slice(1).map((r) => [r[6], r]));
    assert.equal(conflictByName.get('矛盾点A消火栓')[1], 'color_note_conflict');
    assert.equal(conflictByName.get('矛盾点B消火栓')[1], 'color_note_conflict');
    assert.equal(conflictByName.get('未知颜色消火栓')[1], 'unknown_color');
    assert.equal(conflictByName.get('重复点甲消火栓')[1], 'duplicate_within_10m');
    assert.equal(conflictByName.get('重复点乙消火栓')[1], 'duplicate_within_10m');
    assert.equal(conflictByName.get('坐标异常文本点')[1], 'invalid_coordinates');
    assert.equal(conflictByName.get('坐标越界零点')[1], 'invalid_coordinates');
    assert.equal(conflictByName.get('红星园区消防水池')[1], 'missing_intake_methods');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('loadOverridesCsv 仅保留 decision=keep 行、支持 | 分隔取水方式并校验非法字段', () => {
  const csv = stringifyCsv(CONFLICTS_CSV_HEADERS, [
    {
      source_key: 'amap_v1:k1',
      reason: 'missing_intake_methods',
      decision: 'keep',
      category: 'natural',
      status: 'available',
      intake_methods: 'fire_truck|portable_pump',
      name: '红星园区消防水池',
      lat: '30.259',
      lng: '120.168',
      note: '人工核定可消防车和手抬泵取水',
    },
    {
      source_key: 'amap_v1:k2',
      reason: 'duplicate_within_10m',
      decision: 'drop',
      category: 'hydrant',
      status: 'available',
      intake_methods: '',
      name: '重复点乙消火栓',
      lat: '30.257015',
      lng: '120.16502',
      note: '确认重复',
    },
    {
      source_key: 'amap_v1:k3',
      reason: 'unknown_color',
      decision: '',
      category: 'hydrant',
      status: '',
      intake_methods: '',
      name: '未裁定点',
      lat: '30.256',
      lng: '120.163',
      note: '待确认',
    },
  ]);

  const parsed = loadOverridesCsv(csv);
  assert.equal(parsed.kept.length, 1);
  assert.equal(parsed.droppedCount, 1);
  assert.equal(parsed.skippedCount, 1);
  assert.deepEqual(parsed.kept[0].intake_methods, ['portable_pump', 'fire_truck']);

  const merged = mergeImportRecords([
    {
      import_key: 'amap_v1:clean1',
      category: 'hydrant',
      name: '示例点',
      lat: 30.25,
      lng: 120.15,
      status: 'available',
      intake_methods: [],
      note: '',
    },
  ], parsed.kept);
  assert.equal(merged.length, 2);

  // decision=keep 但天然水源仍缺取水方式时应抛错拦截
  const invalidCsv = stringifyCsv(CONFLICTS_CSV_HEADERS, [{
    source_key: 'amap_v1:bad',
    reason: 'missing_intake_methods',
    decision: 'keep',
    category: 'natural',
    status: 'available',
    intake_methods: '',
    name: '缺取水方式水池',
    lat: '30.259',
    lng: '120.168',
    note: '',
  }]);
  assert.throws(() => loadOverridesCsv(invalidCsv), /天然水源必须至少包含 1 项取水方式/);
});

test('parseCliArgs 正确解析 --dry-run 与 --apply 参数', () => {
  const dry = parseCliArgs(['--dry-run', '--csv', 'a.csv', '--out-dir', 'out']);
  assert.deepEqual(dry, {
    mode: 'dry-run',
    csvPath: 'a.csv',
    outDir: 'out',
    unitId: null,
    cleanPath: null,
    overridesPath: null,
    forceOverwrite: false,
    help: false,
  });

  const apply = parseCliArgs([
    '--apply',
    '--unit-id', 'unit_demo',
    '--clean', 'out/clean.json',
    '--overrides', 'out/overrides.csv',
    '--force-overwrite',
  ]);
  assert.deepEqual(apply, {
    mode: 'apply',
    csvPath: null,
    outDir: null,
    unitId: 'unit_demo',
    cleanPath: 'out/clean.json',
    overridesPath: 'out/overrides.csv',
    forceOverwrite: true,
    help: false,
  });
});

test('--apply 两阶段全链路：合并 overrides 幂等入库、重复运行 0 新增且绝不覆盖一线人工修改与软删除', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-water-apply-'));
  try {
    // 阶段一：dry-run 生成 clean.json 与 conflicts.csv
    const dryOut = runDryRun({ csvPath: FIXTURE_CSV, outDir: tmpDir });

    // 模拟人工裁定 overrides.csv：保留 3 条修复后的冲突，丢弃 1 条重复点，其余留空跳过
    const conflictByName = new Map(dryOut.conflicts.map((c) => [c.name, c]));
    const overridesRows = dryOut.conflicts.map((row) => {
      if (row.name === '矛盾点A消火栓') {
        return { ...row, decision: 'keep', status: 'unavailable', note: '人工复核确认无水不可用' };
      }
      if (row.name === '重复点甲消火栓') {
        return { ...row, decision: 'keep', note: '人工复核保留主点' };
      }
      if (row.name === '重复点乙消火栓') {
        return { ...row, decision: 'drop' };
      }
      if (row.name === '红星园区消防水池') {
        return { ...row, decision: 'keep', intake_methods: 'fire_truck|portable_pump' };
      }
      return row;
    });
    const overridesPath = path.join(tmpDir, 'overrides.csv');
    fs.writeFileSync(overridesPath, stringifyCsv(CONFLICTS_CSV_HEADERS, overridesRows), 'utf8');

    // 阶段二第一次执行：6 clean + 3 keep = 9 条入库
    const firstApply = await runApply({
      unitId: 'unit_import_1',
      cleanPath: dryOut.cleanPath,
      overridesPath,
      waterSources,
    });
    assert.equal(firstApply.clean_count, 6);
    assert.equal(firstApply.overrides_kept, 3);
    assert.equal(firstApply.overrides_dropped, 1);
    assert.equal(firstApply.total_submitted, 9);
    assert.deepEqual(firstApply.result, { total: 9, inserted: 9, updated: 0, skipped: 0 });

    const listed1 = await waterSources.listByUnit('unit_import_1');
    assert.equal(listed1.items.length, 9);
    assert.equal(listed1.summary.total, 9);
    assert.equal(listed1.summary.by_category.hydrant, 5);
    assert.equal(listed1.summary.by_category.natural, 3);
    assert.equal(listed1.summary.by_category.pump_connector, 1);
    assert.equal(listed1.items.some((it) => it.name === '重复点乙消火栓'), false);

    const poolItem = listed1.items.find((it) => it.name === '红星园区消防水池');
    assert.ok(poolItem);
    assert.deepEqual(poolItem.intake_methods, ['portable_pump', 'fire_truck']);
    assert.equal(poolItem.created_by, 'import_script');
    assert.equal(conflictByName.has('红星园区消防水池'), true);

    // 阶段二第二次执行（默认 DO NOTHING）：验证幂等，0 新增 0 更新 9 跳过
    const secondApply = await runApply({
      unitId: 'unit_import_1',
      cleanPath: dryOut.cleanPath,
      overridesPath,
      waterSources,
    });
    assert.deepEqual(secondApply.result, { total: 9, inserted: 0, updated: 0, skipped: 9 });

    // 模拟一线消防员人工编辑与软删除
    const hydrantA = listed1.items.find((it) => it.name === '示例大道1号市政消火栓');
    const hydrantB = listed1.items.find((it) => it.name === '振兴路北口消火栓');
    await waterSources.update(
      'unit_import_1',
      hydrantA.id,
      { status: 'unavailable', note: '实战巡检确认管网停水' },
      { actorId: 'member_demo_1', actorName: '张三' },
    );
    await waterSources.softDelete(
      'unit_import_1',
      hydrantB.id,
      { actorId: 'member_demo_2', actorName: '李四' },
    );

    // 修改 clean.json 中的备注，测试默认模式与 --force-overwrite 模式
    const modifiedClean = JSON.parse(fs.readFileSync(dryOut.cleanPath, 'utf8'));
    modifiedClean.items = modifiedClean.items.map((it) => ({
      ...it,
      note: `${it.note}（二次清洗修正）`,
    }));
    const modifiedCleanPath = path.join(tmpDir, 'clean.modified.json');
    fs.writeFileSync(modifiedCleanPath, JSON.stringify(modifiedClean, null, 2), 'utf8');

    // 默认模式：全部跳过，绝不覆盖任何记录
    const thirdApply = await runApply({
      unitId: 'unit_import_1',
      cleanPath: modifiedCleanPath,
      overridesPath,
      forceOverwrite: false,
      waterSources,
    });
    assert.deepEqual(thirdApply.result, { total: 9, inserted: 0, updated: 0, skipped: 9 });

    // --force-overwrite 模式：仅覆盖未被人工编辑且未软删除的 7 条，保护 1 条人工编辑 + 1 条软删除
    const forceApply = await runApply({
      unitId: 'unit_import_1',
      cleanPath: modifiedCleanPath,
      overridesPath,
      forceOverwrite: true,
      waterSources,
    });
    assert.deepEqual(forceApply.result, { total: 9, inserted: 0, updated: 7, skipped: 2 });

    const afterHydrantA = await waterSources.getById('unit_import_1', hydrantA.id, { includeDeleted: true });
    assert.equal(afterHydrantA.status, 'unavailable');
    assert.equal(afterHydrantA.note, '实战巡检确认管网停水');
    assert.equal(afterHydrantA.updated_by, 'member_demo_1');

    const afterHydrantB = await waterSources.getById('unit_import_1', hydrantB.id, { includeDeleted: true });
    assert.ok(afterHydrantB.deleted_at > 0);
    assert.equal(afterHydrantB.deleted_by, 'member_demo_2');

    const afterConnector = (await waterSources.listByUnit('unit_import_1')).items
      .find((it) => it.name === '示例大道1号水泵接合器');
    assert.equal(afterConnector.note, '对应主楼高区喷淋系统（二次清洗修正）');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
