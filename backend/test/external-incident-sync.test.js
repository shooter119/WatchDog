const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

const {
  computeExternalDetailSyncPatch,
  findNewDispatchedForces,
  markManualEditedFields,
} = require('../src/external-incident-sync');
const policeApiService = require('../src/police-api-service');
const app = require('../src/server');

async function startTestServer() {
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return { server, base: `http://127.0.0.1:${port}` };
}

test('computeExternalDetailSyncPatch: 状态演进与灾情增量字段自动合并，不清空已有值', () => {
  const initial = {
    external_id: 'ext-sync-1',
    incident_status: '出动',
    level: '一级',
    dispatch_summary: '2车 1站 (主调: 示例一站)',
    location: '示例县工业路18号',
    situation: '厂房冒烟',
  };

  const upstream1 = {
    incident_status: '到场',
    incident_level: '二级',
    dispatch_summary: '4车 2站 (主调: 示例一站)',
    dispatch_vehicle: '4',
    dispatch_organization: '2',
    squadron_name: '示例一站',
    trapped: '1人被困',
    situation_detail: '厂房冒烟，二层堆垛起火，1人被困',
    crime_address: '', // 上游空值不应清空已有 location
  };

  const res1 = computeExternalDetailSyncPatch(initial, upstream1, { version: 1, updatedBy: 'device-1' });
  assert.equal(res1.changed, true);
  assert.equal(res1.nextData.incident_status, '到场');
  assert.equal(res1.nextData.level, '二级');
  assert.equal(res1.nextData.trapped, '1人被困');
  assert.equal(res1.nextData.dispatch_summary, '4车 2站 (主调: 示例一站)');
  assert.equal(res1.nextData.location, '示例县工业路18号', '上游空值绝不清空现有地址');
  assert.equal(res1.nextData.situation, '厂房冒烟，二层堆垛起火，1人被困');
  assert.ok(res1.nextData._external_synced);

  // 二次无变化时返回 changed=false（幂等不刷写）
  const resSame = computeExternalDetailSyncPatch(res1.nextData, upstream1, { version: 2, updatedBy: 'police_api_sync' });
  assert.equal(resSame.changed, false);
});

test('computeExternalDetailSyncPatch: 人工编辑过的字段（_manual_fields）绝不被上游同步覆盖', () => {
  const before = {
    external_id: 'ext-sync-2',
    incident_status: '出动',
    location: '示例路旧地址',
    level: '一级',
    situation: '初始报警描述',
    _external_synced: {
      incident_status: '出动',
      location: '示例路旧地址',
      level: '一级',
      situation: '初始报警描述',
    },
  };
  const afterManual = markManualEditedFields(
    before,
    { location: '示例路88号西门仓库（人工核实）', situation: '现场核实为配电箱起火' },
    {
      ...before,
      location: '示例路88号西门仓库（人工核实）',
      situation: '现场核实为配电箱起火',
    },
  );
  assert.deepEqual(afterManual._manual_fields.sort(), ['location', 'situation']);

  const upstream = {
    incident_status: '到场',
    incident_level: '二级',
    crime_address: '示例路粗略地址',
    incident_describe: '上游旧描述补充',
  };

  const synced = computeExternalDetailSyncPatch(afterManual, upstream, { version: 2, updatedBy: 'device-human' });
  assert.equal(synced.changed, true);
  assert.equal(synced.nextData.incident_status, '到场', '官方状态正常同步');
  assert.equal(synced.nextData.level, '二级', '未人工改过的等级随上游升级');
  assert.equal(synced.nextData.location, '示例路88号西门仓库（人工核实）', '人工核实地址不被覆盖');
  assert.equal(synced.nextData.situation, '现场核实为配电箱起火', '人工核实情况不被覆盖');
});

test('findNewDispatchedForces: 仅追加新队站、同名规范化去重、绝不删除已有力量', () => {
  const existing = [
    { id: 'f1', station_name: '示例一站', vehicle_count: 2 },
    { id: 'f2', station_name: '现场手动补充队', vehicle_count: 1 },
  ];
  const upstream = [
    { station_name: '示例一站', vehicle_count: 2 },
    { station_name: '示例二站', vehicle_count: 3 },
    { station_name: '示例二站', vehicle_count: 3 },
  ];
  const additions = findNewDispatchedForces(existing, upstream);
  assert.equal(additions.length, 1);
  assert.equal(additions[0].station_name, '示例二站');
});

test('后台轮询 syncActiveIncidentsFromExternal: 建档时为出动，上游演进到场并新增增援队站后自动更新档案', async () => {
  const { server, base } = await startTestServer();
  try {
    const ts = Date.now();
    const extId = `ext-dyn-${ts}`;
    const extNum = `POL-DYN-${ts}`;
    const initialExt = {
      external_id: extId,
      incident_number: extNum,
      crime_address: '示例省示例市示例县示范大道66号',
      district_name: '示例县',
      incident_type: '火灾扑救',
      incident_status: '出动',
      incident_level: '一级',
      incident_describe: '厂房外墙起火',
      squadron_name: '示例一站',
      dispatch_vehicle: '2',
      dispatch_organization: '1',
      dispatched_forces: [{ station_name: '示例一站', vehicle_count: 2, deployment_status: 'dispatched' }],
      register_time: ts - 600000,
    };

    // 1. 10 分钟前以「出动」状态建档进入
    const claimRes = await fetch(`${base}/api/incidents/claim-external`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Id': 'device-dyn-1',
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
        'X-Op-Id': `claim-dyn-${ts}`,
      },
      body: JSON.stringify({ external_incident: initialExt, actor_name: '张三' }),
    });
    assert.equal(claimRes.status, 201);
    const created = await claimRes.json();
    assert.equal(created.info.incident_status, '出动');
    assert.equal(created.forces.length, 1);

    // 2. 10 分钟后后台轮询抓到上游最新动态：到场 + 二级 + 增援示例二站
    const updatedExt = {
      ...initialExt,
      incident_status: '到场',
      official_status: '到场',
      incident_level: '二级',
      dispatch_vehicle: '5',
      dispatch_organization: '2',
      dispatch_summary: '5车 2站 (主调: 示例一站)',
      dispatched_forces: [
        { station_name: '示例一站', vehicle_count: 2, deployment_status: 'dispatched' },
        { station_name: '示例二站', vehicle_count: 3, deployment_status: 'dispatched' },
      ],
    };
    policeApiService._setCacheForTest({ data: [updatedExt], fetchedAt: Date.now() });

    const summary = await app._syncActiveIncidentsFromExternalForTest([updatedExt]);
    assert.equal(summary.synced, 1);
    assert.equal(summary.updated, 1);
    assert.equal(summary.forcesAdded, 1);

    // 3. 校验档案详情与参战力量已动态更新（无需任何人打开选警情页）
    const viewRes = await fetch(`${base}/api/incidents/${created.id}`, {
      headers: {
        'X-Device-Id': 'device-dyn-1',
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
      },
    });
    assert.equal(viewRes.status, 200);
    const refreshed = await viewRes.json();
    assert.equal(refreshed.info.incident_status, '到场');
    assert.equal(refreshed.info.level, '二级');
    assert.equal(refreshed.info.dispatch_summary, '5车 2站 (主调: 示例一站)');
    assert.equal(refreshed.forces.length, 2);
    assert.ok(refreshed.forces.some((f) => f.station_name === '示例二站'));
  } finally {
    policeApiService._resetCacheForTest();
    server.close();
  }
});
