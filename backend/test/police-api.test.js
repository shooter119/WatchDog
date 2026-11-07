process.env.NODE_ENV = 'test';
process.env.WATCHDOG_SESSION_AUTH_REQUIRED = '0';
process.env.WATCHDOG_MEMBER_AUTH_REQUIRED = '0';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const policeApiService = require('../src/police-api-service');
const app = require('../src/server');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((r) => server.close(r)));

test('衢州警情过滤逻辑', () => {
  // 衢州支队或辖区大队
  assert.equal(policeApiService.isQuzhouIncident({ detachmentOrgName: '衢州支队' }), true);
  assert.equal(policeApiService.isQuzhouIncident({ brigadeOrganizationName: '龙游大队' }), true);
  assert.equal(policeApiService.isQuzhouIncident({ districtName: '江山市' }), true);
  assert.equal(policeApiService.isQuzhouIncident({ districtName: '开化县' }), true);
  assert.equal(policeApiService.isQuzhouIncident({ brigadeOrganizationName: '柯城大队' }), true);

  // 虽属衢州支队但异地跨市演练/拉动必须排除
  assert.equal(policeApiService.isQuzhouIncident({
    detachmentOrgName: '衢州支队',
    brigadeOrganizationName: '衢州智慧新城大队',
    crimeAddress: '（拉动）绍兴市越城区马山街道',
  }), false);
  assert.equal(policeApiService.isQuzhouIncident({
    detachmentOrgName: '衢州支队',
    crimeAddress: '杭州市滨江区江南大道',
  }), false);

  // 非衢州单位排除
  assert.equal(policeApiService.isQuzhouIncident({ detachmentOrgName: '嘉兴支队', brigadeOrganizationName: '南湖大队' }), false);
  assert.equal(policeApiService.isQuzhouIncident({ detachmentOrgName: '杭州支队' }), false);
  assert.equal(policeApiService.isQuzhouIncident(null), false);
});

test('官方警情规范化映射', () => {
  const raw = {
    id: 'test-ext-123',
    incidentNumber: '2026110712345678',
    detachmentOrgName: '衢州支队',
    brigadeOrganizationName: '龙游大队',
    districtName: '龙游县',
    incidentTypeName: '火灾扑救',
    incidentLevelName: '一级',
    incidentStatusName: '出动',
    crimeAddress: '龙游县文化路1号',
    incidentDescribe: '某住宅起火',
    registerIncidentTime: 1786177140421,
    latitude: 29.0232,
    longitude: 119.1653,
  };
  const normalized = policeApiService.normalizeExternalIncident(raw);
  assert.equal(normalized.external_id, 'test-ext-123');
  assert.equal(normalized.incident_number, '2026110712345678');
  assert.equal(normalized.detachment_name, '衢州支队');
  assert.equal(normalized.crime_address, '龙游县文化路1号');
  assert.equal(normalized.register_time, 1786177140421);
});

test('HTTP GET /api/external-incidents 接口返回与认领状态标记', async (t) => {
  const now = Date.now();
  const mockUpstreamServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      errorCode: 0,
      data: {
        list: [
          {
            id: 'mock-qz-recent',
            incidentNumber: '20261107001',
            detachmentOrgName: '衢州支队',
            brigadeOrganizationName: '柯城大队',
            crimeAddress: '柯城区三江路10号',
            incidentTypeName: '抢险救援',
            registerIncidentTime: now - 3600 * 1000,
          },
          {
            id: 'mock-qz-old',
            incidentNumber: '20261101002',
            detachmentOrgName: '衢州支队',
            crimeAddress: '超过3天的旧警情',
            registerIncidentTime: now - 5 * 24 * 3600 * 1000,
          },
          {
            id: 'mock-other-city',
            incidentNumber: '20261107999',
            detachmentOrgName: '宁波支队',
            crimeAddress: '宁波市海曙区',
            registerIncidentTime: now - 3600 * 1000,
          },
        ],
        pagination: { total: 3 },
      },
    }));
  });

  await new Promise((resolve) => mockUpstreamServer.listen(0, resolve));
  const port = mockUpstreamServer.address().port;
  const mockUrl = `http://127.0.0.1:${port}/mock-orglist`;

  t.after(() => {
    mockUpstreamServer.close();
    policeApiService._resetCacheForTest();
  });

  policeApiService._resetCacheForTest();
  const result = await policeApiService.getQuzhouIncidents({
    forceRefresh: true,
    upstreamUrl: mockUrl,
  });

  assert.equal(result.list.length, 1);
  assert.equal(result.list[0].external_id, 'mock-qz-recent');
  assert.equal(result.list[0].crime_address, '柯城区三江路10号');
});

test('POST /api/incidents/claim-external 认领建档与幂等防重', async () => {
  try {
    const extIncident = {
      external_id: `ext-${Date.now()}`,
      incident_number: `POLICE-${Date.now()}`,
      crime_address: '衢州市柯城区新桥街88号商铺',
      incident_type: '火灾扑救',
      district_name: '柯城区',
      incident_describe: '商铺电线短路起火，无人员被困',
      register_time: Date.now() - 1000 * 60,
    };

    // 1. 首次认领建档
    const res1 = await fetch(`${base}/api/incidents/claim-external`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Id': 'device-test-1',
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
        'X-Op-Id': `claim-op-${Date.now()}`,
      },
      body: JSON.stringify({ external_incident: extIncident, actor_name: '张建国' }),
    });

    const body1 = await res1.json();
    assert.equal(res1.status, 201, `Status should be 201, got ${res1.status}: ${JSON.stringify(body1)}`);
    assert.ok(body1.id);
    assert.equal(body1.number, extIncident.incident_number);
    assert.equal(body1.title, extIncident.crime_address);

    // 2. 第二位队员点击同一官方警情，幂等返回已有警情 (状态码 200)
    const res2 = await fetch(`${base}/api/incidents/claim-external`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Id': 'device-test-2',
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
        'X-Op-Id': `claim-op-2-${Date.now()}`,
      },
      body: JSON.stringify({ external_incident: extIncident, actor_name: '李卫东' }),
    });

    const body2 = await res2.json();
    assert.equal(res2.status, 200, `Status should be 200, got ${res2.status}: ${JSON.stringify(body2)}`);
    assert.equal(body2.id, body1.id, '二次认领应返回相同警情档案ID');
    assert.equal(body2.number, body1.number);
  } catch (e) {
    console.error('TEST ERROR:', e);
    throw e;
  }
});

test('buildSituationDescription 与 detailPatch 后到智能覆盖', () => {
  const { buildSituationDescription, normalizeExternalIncident } = require('../src/police-api-service');
  const { detailPatch } = require('../src/incident-import-repository');

  // 1. buildSituationDescription
  assert.equal(buildSituationDescription({ incident_type: '抢险救援', disposal_object_name: '公路' }), '抢险救援（公路）');
  assert.equal(buildSituationDescription({ incident_type: '抢险救援', disposal_object_name: '其他' }), '抢险救援');
  assert.equal(buildSituationDescription({ incident_type: '火灾扑救', incident_describe: '油锅起火' }), '油锅起火');

  // 2. detailPatch 智能非空覆盖
  const currentData = {
    location: '莲湖雅苑2栋3单元',
    administrative_area: '龙游县',
    situation: '抢险救援',
    received_at: '2026-11-06T06:13:46.000Z',
  };
  const newData = {
    location: '龙游县莲湖雅苑2栋3单元502室',
    situation: '502厨房起火，烟雾较大，无人员被困',
    trapped: '无人员被困',
    // 未提及的字段为空字符串
    hazardous_materials: '',
  };
  const merged = detailPatch(newData, currentData);
  assert.equal(merged.location, '龙游县莲湖雅苑2栋3单元502室', '详细地址应覆盖旧简略地址');
  assert.equal(merged.situation, '502厨房起火，烟雾较大，无人员被困', '详尽灾情应覆盖旧概要');
  assert.equal(merged.trapped, '无人员被困');
  assert.equal(merged.administrative_area, '龙游县', '未提及字段应保留已有值');
  assert.equal(merged.received_at, '2026-11-06T06:13:46.000Z', '未提及字段应保留已有时间');
});
