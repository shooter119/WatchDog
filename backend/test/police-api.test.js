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
      body: JSON.stringify({
        external_incident: {
          ...extIncident,
          alarm_person_phone: '13812345678',
          alarm_phone: '0110',
          alarm_person_name: '李四',
          dispatch_vehicle: '4',
          dispatch_organization: '2',
          squadron_name: '双塔站',
          latitude: '28.8693',
          longitude: '118.9805',
        },
        actor_name: '张建国',
      }),
    });

    const body1 = await res1.json();
    assert.equal(res1.status, 201, `Status should be 201, got ${res1.status}: ${JSON.stringify(body1)}`);
    assert.ok(body1.id);
    assert.equal(body1.number, extIncident.incident_number);
    assert.equal(body1.title, extIncident.crime_address);
    assert.equal(body1.info.latitude, '28.8693');
    assert.equal(body1.info.longitude, '118.9805');
    assert.equal(body1.info.dispatch_summary, '4车 2站 (主调: 双塔站)');

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

test('extractContacts、buildDispatchSummary 与 sanitizeCoordinates 容错逻辑', () => {
  const { extractContacts, buildDispatchSummary, sanitizeCoordinates } = require('../src/police-api-service');

  // 1. extractContacts: 优先 alarm_person_phone，排除 0110
  const c1 = extractContacts({
    alarm_person_phone: '17613141617',
    alarm_phone: '0110',
    alarm_person_name: '王五',
  });
  assert.equal(c1.length, 1);
  assert.equal(c1[0].phone, '17613141617');
  assert.equal(c1[0].name, '王五');

  // 2. alarm_person_phone 为空，回退有效 alarm_phone，姓名缺省回退“报警人”
  const c2 = extractContacts({
    alarm_person_phone: '',
    alarm_phone: '0570-8888999',
    alarm_person_name: '',
  });
  assert.equal(c2.length, 1);
  assert.equal(c2[0].phone, '0570-8888999');
  assert.equal(c2[0].name, '报警人');

  // 3. 两个号码均为 110 转警或无效，返回空数组
  const c3 = extractContacts({
    alarm_person_phone: '110',
    alarm_phone: '0110',
  });
  assert.equal(c3.length, 0);

  // 4. buildDispatchSummary
  assert.equal(buildDispatchSummary({ dispatch_vehicle: '4', dispatch_organization: '2', squadron_name: '双塔站' }), '4车 2站 (主调: 双塔站)');
  assert.equal(buildDispatchSummary({ dispatch_vehicle: '2', dispatch_organization: '0' }), '2车');
  assert.equal(buildDispatchSummary({}), '');

  // 5. sanitizeCoordinates
  assert.deepEqual(sanitizeCoordinates('28.8693', '118.9805'), { latitude: '28.8693', longitude: '118.9805' });
  assert.deepEqual(sanitizeCoordinates('0.0', '0.0'), { latitude: null, longitude: null });
  assert.deepEqual(sanitizeCoordinates('99.99', '199.99'), { latitude: null, longitude: null });
});

test('官方警情二次清洗：地点去冗余、事件提炼与终态判定', () => {
  const {
    cleanIncidentLocation,
    cleanIncidentEvent,
    sanitizeOfficialStatus,
    isTerminalOfficialStatus,
  } = require('../src/police-api-service');

  // 地点清洗：剥离省前缀与有区县时的冗余市前缀，消除相邻重复区县
  assert.equal(cleanIncidentLocation('示例省示例市示例县文化路1号', '示例县'), '示例县文化路1号');
  assert.equal(cleanIncidentLocation('示例县示例县示例镇示例村12号', '示例县'), '示例县示例镇示例村12号');
  assert.equal(cleanIncidentLocation('新桥街88号', '示例区'), '示例区新桥街88号');
  assert.equal(cleanIncidentLocation('示例区新桥街88号', '示例区'), '示例区新桥街88号');

  // 事件清洗：去噪提取核心描述，缺省则组合大类与处置对象
  assert.equal(
    cleanIncidentEvent({
      incident_type: '火灾扑救',
      incident_describe: '商铺电线短路起火，无人员被困，电话报警',
    }),
    '商铺电线短路起火',
  );
  assert.equal(
    cleanIncidentEvent({
      incident_type: '抢险救援',
      disposal_object_name: '公路',
      incident_describe: '官方状态: 归队',
    }),
    '抢险救援（公路）',
  );
  assert.equal(
    cleanIncidentEvent({
      incident_type: '社会救助',
      disposal_object_name: '其他',
    }),
    '社会救助',
  );

  // 官方状态过滤与终态判定
  assert.equal(sanitizeOfficialStatus('真警'), '');
  assert.equal(sanitizeOfficialStatus('其他'), '');
  assert.equal(sanitizeOfficialStatus(' 归队 '), '归队');
  assert.equal(isTerminalOfficialStatus('归队'), true);
  assert.equal(isTerminalOfficialStatus('已结案'), true);
  assert.equal(isTerminalOfficialStatus('填报'), true);
  assert.equal(isTerminalOfficialStatus('出动'), false);
  assert.equal(isTerminalOfficialStatus('到场'), false);
});

test('认领官方警情独立透传 incident_status 且刷新缓存后实时反映最新状态', async (t) => {
  const extId = `ext-status-${Date.now()}`;
  const incNumber = `POLICE-ST-${Date.now()}`;
  const res = await fetch(`${base}/api/incidents/claim-external`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'device-status-test',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
      'X-Op-Id': `claim-status-${Date.now()}`,
    },
    body: JSON.stringify({
      external_incident: {
        external_id: extId,
        incident_number: incNumber,
        crime_address: '示例省示例市示例县示例镇示例村8号',
        district_name: '示例县',
        incident_type: '火灾扑救',
        incident_status: '出动',
        register_time: Date.now() - 60000,
      },
      actor_name: '张三',
    }),
  });
  const claimed = await res.json();
  assert.equal(res.status, 201);
  assert.equal(claimed.info.incident_status, '出动');
  assert.equal(claimed.info.location, '示例县示例镇示例村8号');

  // 模拟上游状态变更为“归队”并刷新缓存
  const mockUpstream = http.createServer((_req, response) => {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({
      errorCode: 0,
      data: {
        list: [
          {
            id: extId,
            incidentNumber: incNumber,
            detachmentOrgName: '衢州支队',
            brigadeOrganizationName: '龙游大队',
            crimeAddress: '龙游县示例镇示例村8号',
            incidentTypeName: '火灾扑救',
            incidentStatusName: '归队',
            registerIncidentTime: Date.now() - 30000,
          },
        ],
        pagination: { total: 1 },
      },
    }));
  });
  await new Promise((resolve) => mockUpstream.listen(0, resolve));
  const upstreamUrl = `http://127.0.0.1:${mockUpstream.address().port}/orglist`;
  t.after(() => {
    mockUpstream.close();
    policeApiService._resetCacheForTest();
  });

  await policeApiService.getQuzhouIncidents({ forceRefresh: true, upstreamUrl });
  const viewRes = await fetch(`${base}/api/incidents/${claimed.id}`, {
    headers: {
      'X-Device-Id': 'device-status-test',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
    },
  });
  const viewBody = await viewRes.json();
  assert.equal(viewRes.status, 200);
  assert.equal(viewBody.info.incident_status, '归队');
});
