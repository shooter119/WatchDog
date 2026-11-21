process.env.NODE_ENV = 'test';
process.env.WATCHDOG_SESSION_AUTH_REQUIRED = '0';
process.env.WATCHDOG_MEMBER_AUTH_REQUIRED = '0';
process.env.POLICE_API_REGION_KEYWORDS = '示例市,示例县,示例区,示例新城';
process.env.POLICE_API_EXCLUDE_CITIES = '异地市,异地市2,异地甲市,异地乙市';
process.env.POLICE_API_AUTHORIZED_UNITS = 'example-county-fire-rescue';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const policeApiService = require('../src/police-api-service');
const app = require('../src/server');

let server;
let base;

before(async () => {
  server = app.listen(0, '127.0.0.1');
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

function closeServerNow(srv) {
  if (!srv) return Promise.resolve();
  srv.closeAllConnections?.();
  return new Promise((r) => srv.close(() => r()));
}

after(() => closeServerNow(server));

test('辖区警情过滤逻辑', () => {
  const opts = {
    regionKeywords: ['示例市', '示例县', '示例区', '示例新城'],
    excludeCities: ['异地市', '异地市2', '异地甲市', '异地乙市'],
  };
  // 辖区支队或辖区大队
  assert.equal(policeApiService.isJurisdictionIncident({ detachmentOrgName: '示例市支队' }, opts), true);
  assert.equal(policeApiService.isJurisdictionIncident({ brigadeOrganizationName: '示例县大队' }, opts), true);
  assert.equal(policeApiService.isJurisdictionIncident({ districtName: '示例县' }, opts), true);
  assert.equal(policeApiService.isJurisdictionIncident({ districtName: '示例区' }, opts), true);
  assert.equal(policeApiService.isJurisdictionIncident({ brigadeOrganizationName: '示例区大队' }, opts), true);

  // 虽属辖区支队但异地跨市演练/拉动必须排除
  assert.equal(policeApiService.isJurisdictionIncident({
    detachmentOrgName: '示例市支队',
    brigadeOrganizationName: '示例新城大队',
    crimeAddress: '（拉动）异地市甲区示范街道',
  }, opts), false);
  assert.equal(policeApiService.isJurisdictionIncident({
    detachmentOrgName: '示例市支队',
    crimeAddress: '异地市乙区示范大道',
  }, opts), false);

  // 非辖区单位排除
  assert.equal(policeApiService.isJurisdictionIncident({ detachmentOrgName: '异地支队', brigadeOrganizationName: '异地大队' }, opts), false);
  assert.equal(policeApiService.isJurisdictionIncident({ detachmentOrgName: '异地支队2' }, opts), false);
  assert.equal(policeApiService.isJurisdictionIncident(null, opts), false);
});

test('官方警情规范化映射', () => {
  const raw = {
    id: 'test-ext-123',
    incidentNumber: '2026110712345678',
    detachmentOrgName: '示例市支队',
    brigadeOrganizationName: '示例县大队',
    districtName: '示例县',
    incidentTypeName: '火灾扑救',
    incidentLevelName: '一级',
    incidentStatusName: '出动',
    crimeAddress: '示例县文化路1号',
    incidentDescribe: '某住宅起火',
    registerIncidentTime: 1786177140421,
    latitude: 29.0232,
    longitude: 119.1653,
  };
  const normalized = policeApiService.normalizeExternalIncident(raw);
  assert.equal(normalized.external_id, 'test-ext-123');
  assert.equal(normalized.incident_number, '2026110712345678');
  assert.equal(normalized.detachment_name, '示例市支队');
  assert.equal(normalized.crime_address, '示例县文化路1号');
  assert.equal(normalized.register_time, 1786177140421);
});

test('isDispatchedIncident 已调派力量筛选逻辑', () => {
  const { isDispatchedIncident } = policeApiService;

  // 未调派阶段（接警/受理/立案/作废/注销/未调派）且无实际调派力量：排除
  assert.equal(isDispatchedIncident({ incidentStatusName: '接警' }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '电话报警', squadronOrganizationName: '示例路站' }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '受理', dispatchVehicle: '0', dispatchOrganization: '0' }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '立案', dispatchVehicle: 0, dispatchOrganization: 0 }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '作废' }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '注销', squadronOrganizationName: '示例路站' }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '未调派', squadronOrganizationName: '示例路站' }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '未调派', dispatchVehicle: '2' }), false);
  assert.equal(isDispatchedIncident({ dispatchStatusName: '待派警' }), false);
  assert.equal(isDispatchedIncident({ whetherDispatch: false, incidentStatusName: '真警' }), false);
  assert.equal(isDispatchedIncident({ incidentStatusName: '' }), false);
  assert.equal(isDispatchedIncident(null), false);

  // 已调派或处于作战/归队阶段（含测试/演练/假警已调派记录）：全部放行
  assert.equal(isDispatchedIncident({ incidentNatureName: '假警', dispatchVehicle: '2' }), true);
  assert.equal(isDispatchedIncident({ incidentStatusName: '作废', dispatchVehicle: '1' }), true);
  assert.equal(isDispatchedIncident({ whetherTestSign: 1, incidentNatureName: '测试警情', dispatchVehicle: '1' }), true);
  assert.equal(isDispatchedIncident({ whetherTestSign: true, dispatchTime: 1786177140421 }), true);
  assert.equal(isDispatchedIncident({ incidentStatusName: '立案', dispatchVehicle: '2', dispatchOrganization: '1' }), true);
  assert.equal(isDispatchedIncident({ dispatchOrganization: '示例路站' }), true);
  assert.equal(isDispatchedIncident({ dispatchStatusName: '已调派' }), true);
  assert.equal(isDispatchedIncident({ whetherDispatch: true }), true);
  assert.equal(isDispatchedIncident({ incidentStatusName: '调派' }), true);
  assert.equal(isDispatchedIncident({ incidentStatusName: '出动' }), true);
  assert.equal(isDispatchedIncident({ incidentStatusName: '到场' }), true);
  assert.equal(isDispatchedIncident({ incidentStatusName: '归队' }), true);
  assert.equal(isDispatchedIncident({ incidentStatusName: '结案' }), true);
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
            id: 'mock-ext-recent',
            incidentNumber: '20261107001',
            detachmentOrgName: '示例市支队',
            brigadeOrganizationName: '示例区大队',
            crimeAddress: '示例区示范路10号',
            incidentTypeName: '抢险救援',
            incidentStatusName: '出动',
            dispatchVehicle: '2',
            dispatchOrganization: '1',
            registerIncidentTime: now - 3600 * 1000,
          },
          {
            id: 'mock-ext-filing-only',
            incidentNumber: '20261107003',
            detachmentOrgName: '示例市支队',
            brigadeOrganizationName: '示例区大队',
            crimeAddress: '示例区示例街道18号',
            incidentTypeName: '火灾扑救',
            incidentStatusName: '立案',
            dispatchVehicle: '0',
            dispatchOrganization: '0',
            registerIncidentTime: now - 1800 * 1000,
          },
          {
            id: 'mock-ext-old',
            incidentNumber: '20261101002',
            detachmentOrgName: '示例市支队',
            crimeAddress: '超过3天的旧警情',
            incidentStatusName: '归队',
            registerIncidentTime: now - 5 * 24 * 3600 * 1000,
          },
          {
            id: 'mock-other-city',
            incidentNumber: '20261107999',
            detachmentOrgName: '异地支队',
            crimeAddress: '异地市丙区',
            incidentStatusName: '出动',
            registerIncidentTime: now - 3600 * 1000,
          },
        ],
        pagination: { total: 4 },
      },
    }));
  });

  await new Promise((resolve) => mockUpstreamServer.listen(0, '127.0.0.1', resolve));
  const port = mockUpstreamServer.address().port;
  const mockUrl = `http://127.0.0.1:${port}/mock-orglist`;

  t.after(() => {
    mockUpstreamServer.closeAllConnections?.();
    mockUpstreamServer.close();
    policeApiService._resetCacheForTest();
  });

  policeApiService._resetCacheForTest();
  const result = await policeApiService.getExternalIncidents({
    forceRefresh: true,
    upstreamUrl: mockUrl,
  });

  assert.equal(result.list.length, 1);
  assert.equal(result.list[0].external_id, 'mock-ext-recent');
  assert.equal(result.list[0].crime_address, '示例区示范路10号');
});

test('POST /api/incidents/claim-external 认领建档与幂等防重', async () => {
  try {
    const extIncident = {
      external_id: `ext-${Date.now()}`,
      incident_number: `POLICE-${Date.now()}`,
      crime_address: '示例省示例市示例区示范街88号商铺',
      incident_type: '火灾扑救',
      district_name: '示例区',
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
          squadron_name: '示例二站',
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
    assert.equal(body1.title, '商铺电线短路起火', '认领后主标题应为提炼后的灾情事件而非地址');
    assert.equal(body1.info.event_summary, '商铺电线短路起火');
    assert.equal(body1.info.disaster_category, 'fire');
    assert.equal(body1.info.latitude, '28.8693');
    assert.equal(body1.info.longitude, '118.9805');
    assert.equal(body1.info.dispatch_summary, '4车 2站 (主调: 示例二站)');
    assert.equal(body1.forces.length, 1);
    assert.equal(body1.forces[0].station_name, '示例二站');
    assert.equal(Boolean(body1.forces[0].vehicle_count_known), false, '多站总车数分摊未知时不编造单站车数');
    assert.equal(Boolean(body1.forces[0].personnel_count_known), false, '人数未提及时标记待补充');

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
    location: '示范小区2栋3单元',
    administrative_area: '示例县',
    situation: '抢险救援',
    received_at: '2026-11-06T06:13:46.000Z',
  };
  const newData = {
    location: '示例县示范小区2栋3单元502室',
    situation: '502厨房起火，烟雾较大，无人员被困',
    trapped: '无人员被困',
    // 未提及的字段为空字符串
    hazardous_materials: '',
  };
  const merged = detailPatch(newData, currentData);
  assert.equal(merged.location, '示例县示范小区2栋3单元502室', '详细地址应覆盖旧简略地址');
  assert.equal(merged.situation, '502厨房起火，烟雾较大，无人员被困', '详尽灾情应覆盖旧概要');
  assert.equal(merged.trapped, '无人员被困');
  assert.equal(merged.administrative_area, '示例县', '未提及字段应保留已有值');
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
    alarm_phone: '010-8888999',
    alarm_person_name: '',
  });
  assert.equal(c2.length, 1);
  assert.equal(c2[0].phone, '010-8888999');
  assert.equal(c2[0].name, '报警人');

  // 3. 两个号码均为 110 转警或无效，返回空数组；掩码号码严禁被还原或采信
  const c3 = extractContacts({
    alarm_person_phone: '110',
    alarm_phone: '0110',
  });
  assert.equal(c3.length, 0);
  const cMasked = extractContacts({
    alarm_person_phone: '138****5678',
    alarm_phone: '010-****999',
    alarm_person_name: '张*',
  });
  assert.equal(cMasked.length, 0, '含掩码星号的脱敏电话不得伪造成7位号码');

  // 4. buildDispatchSummary
  assert.equal(buildDispatchSummary({ dispatch_vehicle: '4', dispatch_organization: '2', squadron_name: '示例二站' }), '4车 2站 (主调: 示例二站)');
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
  assert.equal(cleanIncidentLocation('示范街88号', '示例区'), '示例区示范街88号');
  assert.equal(cleanIncidentLocation('示例区示范街88号', '示例区'), '示例区示范街88号');

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
            detachmentOrgName: '示例市支队',
            brigadeOrganizationName: '示例县大队',
            crimeAddress: '示例县示例镇示例村8号',
            incidentTypeName: '火灾扑救',
            incidentStatusName: '归队',
            registerIncidentTime: Date.now() - 30000,
          },
        ],
        pagination: { total: 1 },
      },
    }));
  });
  await new Promise((resolve) => mockUpstream.listen(0, '127.0.0.1', resolve));
  const upstreamUrl = `http://127.0.0.1:${mockUpstream.address().port}/orglist`;
  t.after(() => {
    mockUpstream.closeAllConnections?.();
    mockUpstream.close();
    policeApiService._resetCacheForTest();
  });

  await policeApiService.getExternalIncidents({ forceRefresh: true, upstreamUrl });
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

test('单站精确派车认领自动登记已知车辆数与待补充人数', async () => {
  const ts = Date.now();
  const res = await fetch(`${base}/api/incidents/claim-external`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'device-single-force',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
      'X-Op-Id': `claim-single-${ts}`,
    },
    body: JSON.stringify({
      external_incident: {
        external_id: `ext-single-${ts}`,
        incident_number: `POLICE-SF-${ts}`,
        event_summary: '沿街餐饮店厨房油烟管道起火',
        disaster_category: 'fire',
        crime_address: '示例省示例市示例县示范路16号',
        district_name: '示例县',
        incident_type: '火灾扑救',
        dispatch_vehicle: '3',
        dispatch_organization: '1',
        squadron_name: '示例路站',
        register_time: ts - 120000,
      },
      actor_name: '张三',
    }),
  });
  const body = await res.json();
  assert.equal(res.status, 201);
  assert.equal(body.title, '沿街餐饮店厨房油烟管道起火');
  assert.equal(body.forces.length, 1);
  assert.equal(body.forces[0].station_name, '示例路站');
  assert.equal(body.forces[0].vehicle_count, 3);
  assert.equal(Boolean(body.forces[0].vehicle_count_known), true);
  assert.equal(Boolean(body.forces[0].personnel_count_known), false);
});

test('external-incident-organizer 原始融合、AI JSON重组、hash缓存与重整接口', async () => {
  const {
    buildRawMergedText,
    buildRuleFallbackStructured,
    computeContentHash,
    createExternalIncidentOrganizer,
  } = require('../src/external-incident-organizer');

  const rawItem = {
    id: 'org-test-1',
    incidentNumber: '202611140001',
    detachmentOrgName: '示例支队',
    brigadeOrganizationName: '示例大队',
    squadronOrganizationName: '示例路站',
    districtName: '示例县',
    incidentTypeName: '抢险救援',
    disposalObjectName: '交通事故',
    incidentLevelName: '二级',
    incidentStatusName: '到场',
    crimeAddress: '示例省示例市示例县建设大道66号',
    incidentDescribe: '货车追尾驾驶室人员被困',
    registerIncidentTime: Date.now() - 60000,
    dispatchVehicle: '2',
    dispatchOrganization: '1',
  };

  const normalized = policeApiService.normalizeExternalIncident(rawItem);
  const mergedText = buildRawMergedText(rawItem, normalized);
  assert.ok(mergedText.includes('警情编号: 202611140001'));
  assert.ok(mergedText.includes('主调队站: 示例路站'));
  assert.ok(mergedText.includes('出动车辆数: 2车'));
  assert.ok(mergedText.includes('警情描述: 货车追尾驾驶室人员被困'));

  let llmCallCount = 0;
  const organizer = createExternalIncidentOrganizer({
    getLlmConfig: () => ({ apiKey: 'test-key', baseUrl: 'https://mock.llm', importModel: 'deepseek-chat' }),
    fetchImpl: async () => {
      llmCallCount++;
      return {
        ok: true,
        async json() {
          return {
            choices: [
              {
                message: {
                  content: JSON.stringify({
                    event_summary: '建设大道货车追尾致人员被困',
                    disaster_category: 'rescue',
                    specific_type: '交通事故救援',
                    location_display: '示例县建设大道66号',
                    district_name: '示例县',
                    situation_detail: '货车追尾，驾驶室1名人员被困',
                    trapped: '1名人员被困',
                    fact_highlights: ['有人员被困'],
                    dispatched_forces: [{ station_name: '示例路站', vehicle_count: 2, personnel_count: null }],
                  }),
                },
              },
            ],
          };
        },
      };
    },
  });

  // 1. 首次触发 AI 重组并等待结果
  const firstPass = await organizer.syncIncidents([normalized], { awaitAi: true, maxAwaitMs: 2000 });
  assert.equal(llmCallCount, 1);
  assert.equal(firstPass[0].ai_status, 'ready');
  assert.equal(firstPass[0].event_summary, '建设大道货车追尾致人员被困');
  assert.equal(firstPass[0].disaster_category, 'rescue');
  assert.equal(firstPass[0].dispatched_forces[0].vehicle_count, 2);

  // 2. 相同 content_hash 即使官方状态从“到场”变为“归队”，应命中缓存不重复调用 LLM 且实时反映“归队”
  const statusChanged = buildRuleFallbackStructured({ ...normalized, incident_status: '归队' }, { ...rawItem, incidentStatusName: '归队' });
  assert.equal(computeContentHash(statusChanged), firstPass[0].content_hash);
  const secondPass = await organizer.syncIncidents([statusChanged], { awaitAi: true, maxAwaitMs: 2000 });
  assert.equal(llmCallCount, 1, '纯状态字变更应复用缓存 AI 结构化事件');
  assert.equal(secondPass[0].official_status, '归队');
  assert.equal(secondPass[0].event_summary, '建设大道货车追尾致人员被困');

  // 3. POST /api/external-incidents/reorganize 端点返回可用结构
  const reorgRes = await fetch(`${base}/api/external-incidents/reorganize`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'device-reorg-test',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
    },
    body: JSON.stringify({ external_ids: ['mock-ext-recent'] }),
  });
  const reorgBody = await reorgRes.json();
  assert.equal(reorgRes.status, 200);
  assert.ok(Array.isArray(reorgBody.list));
});

test('querylist 请求体参数与扩展字段映射', async (t) => {
  let capturedMethod = '';
  let capturedBody = null;
  const mockQueryServer = http.createServer((req, res) => {
    capturedMethod = req.method;
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      capturedBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        errorCode: 0,
        data: { list: [], pagination: { total: 0 } },
      }));
    });
  });

  await new Promise((resolve) => mockQueryServer.listen(0, '127.0.0.1', resolve));
  const mockUrl = `http://127.0.0.1:${mockQueryServer.address().port}/querylist`;
  const originalScope = process.env.POLICE_API_SCOPE_SQUADRON_ID;
  process.env.POLICE_API_SCOPE_SQUADRON_ID = 'test-scope-squadron-id';
  t.after(() => {
    mockQueryServer.closeAllConnections?.();
    mockQueryServer.close();
    policeApiService._resetCacheForTest();
    if (originalScope !== undefined) {
      process.env.POLICE_API_SCOPE_SQUADRON_ID = originalScope;
    } else {
      delete process.env.POLICE_API_SCOPE_SQUADRON_ID;
    }
  });

  policeApiService._resetCacheForTest();
  await policeApiService.getExternalIncidents({ forceRefresh: true, upstreamUrl: mockUrl });

  assert.equal(capturedMethod, 'POST');
  assert.equal(capturedBody.whetherPage, true);
  assert.equal(capturedBody.scopeType, 1);
  assert.equal(typeof capturedBody.scopeSquadronId, 'string');
  assert.equal(capturedBody.scopeSquadronId, 'test-scope-squadron-id');
  assert.deepEqual(capturedBody.squadronIds, []);
  assert.ok(Number(capturedBody.startTime) > 0);
  assert.ok(Number(capturedBody.endTime) > Number(capturedBody.startTime));
  assert.deepEqual(capturedBody.pagination, { page: 1, size: 100 });
  assert.equal(typeof policeApiService.DEFAULT_QUERYLIST_URL, 'string');
  assert.equal(typeof policeApiService.DEFAULT_HOMEINFO_URL, 'string');

  const { buildRawMergedText } = require('../src/external-incident-organizer');
  const raw = {
    id: 'ext-map-1',
    incidentNumber: '202611140100',
    detachmentOrgName: '示例市支队',
    detachmentOrgId: 'det-example-01',
    brigadeOrganizationName: '示例县大队',
    squadronOrganizationName: '示例路站',
    districtName: '示例县',
    incidentTypeName: '火灾扑救',
    incidentStatusName: '到场',
    crimeAddress: '示例县示范路16号',
    incidentDescribe: '仓库杂物起火',
    registerIncidentTime: 1786177000000,
    dispatchTime: 1786177060000,
    siteVehicle: '3',
    siteOrganization: '示例路站、南湖专职队',
    whetherTestSign: 1,
  };
  const normalized = policeApiService.normalizeExternalIncident(raw);
  assert.equal(normalized.dispatch_time, 1786177060000);
  assert.equal(normalized.site_vehicle, '3');
  assert.equal(normalized.site_organization, '示例路站、南湖专职队');
  assert.equal(normalized.whether_test_sign, true);
  assert.equal(normalized.detachment_id, 'det-example-01');

  const mergedText = buildRawMergedText(raw, normalized);
  assert.equal(mergedText.includes('扩展字段(dispatch_time)'), false);
  assert.equal(mergedText.includes('扩展字段(siteVehicle)'), false);
  assert.equal(mergedText.includes('扩展字段(siteOrganization)'), false);
  assert.equal(mergedText.includes('扩展字段(whetherTestSign)'), false);
  assert.equal(mergedText.includes('扩展字段(detachmentOrgId)'), false);
});

test('cleanIncidentEvent 接警套话、重复地址与尾部派警时间线清洗', () => {
  const { cleanIncidentEvent } = require('../src/external-incident-organizer');

  assert.equal(
    cleanIncidentEvent({
      incident_type: '火灾扑救',
      crime_address: '示例省示例市示例县示范路16号',
      incident_describe: '2026年11月13日22时45分，示例县大队指挥中心接警称：（位于）上述地址：示例县示范路16号沿街餐饮店厨房油烟管道起火，无人员被困。接到报警后，示例路站出动2车（水罐车）14人前往处置。',
    }),
    '沿街餐饮店厨房油烟管道起火',
  );

  assert.equal(
    cleanIncidentEvent({
      incident_type: '抢险救援',
      crime_address: '示例省示例市示例县示范路88号',
      incident_describe: '00时26分，示例市支队指挥中心接到110转警称：上址：位于示范路88号两车追尾，1人被困，南湖专职队出动1车（抢险救援车）7人赶赴现场',
    }),
    '两车追尾，1人被困',
  );

  assert.equal(
    cleanIncidentEvent({
      incident_type: '火灾扑救',
      crime_address: '示例县文化路1号',
      incident_describe: '示例县文化路1号起火',
    }),
    '示例县文化路1号起火',
  );

  assert.equal(
    cleanIncidentEvent({
      incident_type: '火灾扑救',
      crime_address: '示例县工业路9号',
      incident_describe: '19时15分许，接报警称：化工原料仓库冒烟，示例产业园出动1车（泡沫车）5人',
    }),
    '化工原料仓库冒烟',
  );
});

test('parseStructuredForces 括号车型、前导动词剥离与产业园提取', () => {
  const { parseStructuredForces } = require('../src/external-incident-organizer');

  const forces = parseStructuredForces({
    incident_describe: '接到报警后，调派示例路站出动1车（抢险救援车）7人，增派南湖专职队出动2车(水罐车、泡沫车)10人，由示例化工园出动1车（防化车）5人，指令示例产业园出动1车，另示例集聚区出动1车（高喷车）6人',
  });
  const byName = Object.fromEntries(forces.map((f) => [f.station_name, f]));
  assert.deepEqual(Object.keys(byName), ['示例路站', '南湖专职队', '示例化工园', '示例产业园', '示例集聚区']);
  assert.equal(byName['示例路站'].vehicle_count, 1);
  assert.equal(byName['示例路站'].personnel_count, 7);
  assert.equal(byName['南湖专职队'].vehicle_count, 2);
  assert.equal(byName['南湖专职队'].personnel_count, 10);
  assert.equal(byName['示例化工园'].vehicle_count, 1);
  assert.equal(byName['示例化工园'].personnel_count, 5);
  assert.equal(byName['示例产业园'].vehicle_count, 1);
  assert.equal(byName['示例产业园'].personnel_count, null);
  assert.equal(byName['示例集聚区'].vehicle_count, 1);
  assert.equal(byName['示例集聚区'].personnel_count, 6);

  // 严禁将“3人被困”误识别为消防出动人数
  const trappedGuard = parseStructuredForces({
    incident_describe: '示例路站出动1车 3人被困',
  });
  assert.equal(trappedGuard[0].station_name, '示例路站');
  assert.equal(trappedGuard[0].vehicle_count, 1);
  assert.equal(trappedGuard[0].personnel_count, null);
});

test('extractForcesFromHomeInfo 与 mergeHomeInfoIntoIncident 力量精确解析与回填', () => {
  const {
    extractForcesFromHomeInfo,
    mergeHomeInfoIntoIncident,
    buildRuleFallbackStructured,
  } = require('../src/external-incident-organizer');

  const homeInfo = {
    incidentDescribe: '示例县示范路16号厂房仓库起火，示例路站出动2车11人',
    handleOrganizationVehicleList: [
      { organizationName: '示例路站', vehicleId: 'veh-1', vehicleNumber: '车01', personNumber: '6', vehicleStatusName: '到场' },
      { organizationName: '示例路站', vehicleId: 'veh-1', vehicleNumber: '车01', personNumber: '6', vehicleStatusName: '到场' },
      { organizationName: '示例路站', vehicleId: 'veh-2', vehicleNumber: '车02', personNumber: '5', vehicleStatusName: '途中' },
      { organizationName: '南湖专职队', vehicleId: 'veh-3', vehicleNumber: '车03', personNumber: '6', vehicleStatusName: '出动' },
      { organizationName: '南湖专职队', vehicleId: 'veh-4', vehicleNumber: '车04', personNumber: '0', vehicleStatusName: '待命' },
    ],
    dpqk: [
      { organizationName: '示例化工园', handleBean: { dispatchVehicleNum: 1, handlePersonNum: 0 } },
    ],
    dcqk: [
      { organizationName: '示例化工园', handleBean: { dispatchVehicleNum: 1, handlePersonNum: 6 } },
    ],
    handleShowBeanList: [
      { dispatchOrganizationName: '示例路站' },
      { dispatchOrganizationName: '示例产业园', vehicleList: [{ vehicleId: 'veh-5' }] },
      { dispatchOrganizationName: '支援一站、支援二站', vehicleList: [{ vehicleId: 'veh-6' }] },
    ],
  };

  const extracted = extractForcesFromHomeInfo(homeInfo);
  const byName = Object.fromEntries(extracted.map((f) => [f.station_name, f]));
  assert.equal(byName['示例路站'].vehicle_count, 2);
  assert.equal(byName['示例路站'].personnel_count, 11);
  assert.equal(byName['示例路站'].deployment_status, 'mobilized');

  assert.equal(byName['南湖专职队'].vehicle_count, 2);
  assert.equal(byName['南湖专职队'].personnel_count, null, '存在未填0人时应保持null而非误算为6或0');
  assert.equal(byName['南湖专职队'].deployment_status, 'mobilized');

  assert.equal(byName['示例化工园'].vehicle_count, 1);
  assert.equal(byName['示例化工园'].personnel_count, 6);

  assert.equal(byName['示例产业园'].vehicle_count, 1);
  assert.equal(byName['示例产业园'].personnel_count, null);

  assert.equal(byName['支援一站'].vehicle_count, null);
  assert.equal(byName['支援二站'].vehicle_count, null);

  // 描述为空且仅规则兜底时：回填描述并刷新 event_summary，且保留文本已提炼的正整数人数
  const initialExt = buildRuleFallbackStructured({
    external_id: 'home-merge-1',
    incident_type: '火灾扑救',
    crime_address: '示例县示范路16号',
    dispatch_vehicle: '4',
    dispatch_organization: '2',
    squadron_name: '示例路站',
  });
  const merged = mergeHomeInfoIntoIncident(initialExt, {
    incidentDescribe: '示例县示范路16号厂房仓库起火，南湖专职队出动2车（泡沫车）9人',
    handleOrganizationVehicleList: [
      { organizationName: '示例路站', vehicleId: 'v-a', personNumber: '0', vehicleStatusName: '到场' },
      { organizationName: '南湖专职队', vehicleId: 'v-b', personNumber: '0', vehicleStatusName: '出动' },
      { organizationName: '南湖专职队', vehicleId: 'v-c', personNumber: '0', vehicleStatusName: '出动' },
    ],
  });
  assert.equal(merged.event_summary, '厂房仓库起火');
  const mergedByName = Object.fromEntries(merged.dispatched_forces.map((f) => [f.station_name, f]));
  assert.equal(mergedByName['示例路站'].vehicle_count, 1);
  assert.equal(mergedByName['示例路站'].personnel_count, null);
  assert.equal(mergedByName['南湖专职队'].vehicle_count, 2);
  assert.equal(mergedByName['南湖专职队'].personnel_count, 9, '文本正整数人数应保留');

  // 已有有效 AI event_summary 时应保留
  const aiReadyExt = buildRuleFallbackStructured({
    external_id: 'home-merge-2',
    incident_type: '火灾扑救',
    crime_address: '示例县示范路16号',
    event_summary: 'AI提炼厂房仓库起火事件',
    ai_status: 'ready',
  });
  const mergedAi = mergeHomeInfoIntoIncident(aiReadyExt, homeInfo);
  assert.equal(mergedAi.event_summary, 'AI提炼厂房仓库起火事件');
});

test('fetchIncidentHomeInfo 短路保护与 POST /api/incidents/claim-external 联动 _setHomeInfoUrlForTest', async (t) => {
  // 1. NODE_ENV=test 且未注入 URL 时零外网请求直接返回 null
  policeApiService._resetCacheForTest();
  const shortCircuit = await policeApiService.fetchIncidentHomeInfo('any-offline-id');
  assert.equal(shortCircuit, null);

  // 2. 注入 mock homeinfo 正常补全多站联调参战力量与缺失描述
  const ts = Date.now();
  const extId = `ext-homeinfo-ok-${ts}`;
  const mockHomeServer = http.createServer((req, res) => {
    const reqUrl = new URL(req.url, 'http://127.0.0.1');
    if (reqUrl.pathname === '/homeinfo-ok') {
      assert.equal(reqUrl.searchParams.get('incidentID'), extId);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        errorCode: 0,
        data: {
          incidentDescribe: '示例县示范路88号沿街商铺电线短路起火，无人员被困',
          handleOrganizationVehicleList: [
            { organizationName: '示例路站', vehicleId: 'hv-1', personNumber: '6', vehicleStatusName: '到场' },
            { organizationName: '示例路站', vehicleId: 'hv-2', personNumber: '0', vehicleStatusName: '途中' },
            { organizationName: '南湖专职队', vehicleId: 'hv-3', personNumber: '5', vehicleStatusName: '出动' },
          ],
        },
      }));
      return;
    }
    if (reqUrl.pathname === '/homeinfo-500') {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ errorMessage: 'server error' }));
      return;
    }
    // 延迟模拟超时
    setTimeout(() => {
      if (!res.writableEnded) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ errorCode: 0, data: {} }));
      }
    }, 300);
  });

  await new Promise((resolve) => mockHomeServer.listen(0, '127.0.0.1', resolve));
  const port = mockHomeServer.address().port;
  t.after(() => {
    mockHomeServer.closeAllConnections?.();
    mockHomeServer.close();
    policeApiService._resetCacheForTest();
  });

  policeApiService._setHomeInfoUrlForTest(`http://127.0.0.1:${port}/homeinfo-ok`);
  const okRes = await fetch(`${base}/api/incidents/claim-external`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'device-homeinfo-ok',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
      'X-Op-Id': `claim-homeinfo-ok-${ts}`,
    },
    body: JSON.stringify({
      external_incident: {
        external_id: extId,
        incident_number: `POLICE-HI-${ts}`,
        crime_address: '示例县示范路88号',
        district_name: '示例县',
        incident_type: '火灾扑救',
        dispatch_vehicle: '3',
        dispatch_organization: '2',
        squadron_name: '示例路站',
        register_time: ts - 60000,
      },
      actor_name: '张三',
    }),
  });
  const okBody = await okRes.json();
  assert.equal(okRes.status, 201);
  assert.equal(okBody.title, '沿街商铺电线短路起火');
  assert.equal(okBody.forces.length, 2);
  const forcesByName = Object.fromEntries(okBody.forces.map((f) => [f.station_name, f]));
  assert.equal(forcesByName['示例路站'].vehicle_count, 2);
  assert.equal(Boolean(forcesByName['示例路站'].vehicle_count_known), true);
  assert.equal(Boolean(forcesByName['示例路站'].personnel_count_known), false);
  assert.equal(forcesByName['南湖专职队'].vehicle_count, 1);
  assert.equal(Boolean(forcesByName['南湖专职队'].vehicle_count_known), true);
  assert.equal(forcesByName['南湖专职队'].personnel_count, 5);
  assert.equal(Boolean(forcesByName['南湖专职队'].personnel_count_known), true);

  const cachedStored = await app.externalIncidentOrganizer.getStoredIncident(extId);
  assert.ok(cachedStored);
  assert.equal(cachedStored.dispatched_forces.length, 2);

  // 3. 上游 500 异常与超时静默降级：claim-external 仍正常返回 201
  const timeoutRes = await policeApiService.fetchIncidentHomeInfo(`ext-timeout-${ts}`, {
    homeInfoUrl: `http://127.0.0.1:${port}/homeinfo-slow`,
    timeoutMs: 40,
  });
  assert.equal(timeoutRes, null);

  policeApiService._setHomeInfoUrlForTest(`http://127.0.0.1:${port}/homeinfo-500`);
  const errRes = await fetch(`${base}/api/incidents/claim-external`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'device-homeinfo-err',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
      'X-Op-Id': `claim-homeinfo-500-${ts}`,
    },
    body: JSON.stringify({
      external_incident: {
        external_id: `ext-homeinfo-500-${ts}`,
        incident_number: `POLICE-HI500-${ts}`,
        crime_address: '示例县文化路1号',
        district_name: '示例县',
        incident_type: '抢险救援',
        incident_describe: '道路树木倒伏阻断交通',
        dispatch_vehicle: '2',
        dispatch_organization: '2',
        squadron_name: '示例路站',
        register_time: ts - 60000,
      },
      actor_name: '李四',
    }),
  });
  const errBody = await errRes.json();
  assert.equal(errRes.status, 201, 'homeinfo 500 时应静默降级正常建档');
  assert.equal(errBody.title, '道路树木倒伏阻断交通');
  assert.equal(errBody.forces.length, 1);
  assert.equal(errBody.forces[0].station_name, '示例路站');
  assert.equal(Boolean(errBody.forces[0].vehicle_count_known), false);
});

test('未配置 POLICE_API_* 环境变量时安全降级为空列表，不发起外网请求', async () => {
  const oldQueryUrl = process.env.POLICE_API_QUERYLIST_URL;
  const oldOrgUrl = process.env.POLICE_API_ORGLIST_URL;
  delete process.env.POLICE_API_QUERYLIST_URL;
  delete process.env.POLICE_API_ORGLIST_URL;
  policeApiService._resetCacheForTest();

  try {
    const result = await policeApiService.getExternalIncidents({ forceRefresh: true });
    assert.deepEqual(result.list, []);
    assert.equal(result.cacheHit, false);

    const res = await fetch(`${base}/api/external-incidents`, {
      headers: {
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
      },
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.list, []);
  } finally {
    if (oldQueryUrl) process.env.POLICE_API_QUERYLIST_URL = oldQueryUrl;
    if (oldOrgUrl) process.env.POLICE_API_ORGLIST_URL = oldOrgUrl;
    policeApiService._resetCacheForTest();
  }
});

test('单位级访问授权：未授权单位返回空列表，并拒绝认领与重整，兼容 POLICE_API_ALLOWED_UNIT_IDS', async () => {
  // 1. GET /api/external-incidents: 未授权单位返回空列表
  const getRes = await fetch(`${base}/api/external-incidents`, {
    headers: {
      'X-Unit-Id': 'unauthorized-test-unit',
      'X-Unit-Code': '9999',
    },
  });
  assert.equal(getRes.status, 200);
  const getBody = await getRes.json();
  assert.deepEqual(getBody.list, []);

  // 2. POST /api/external-incidents/reorganize: 未授权单位返回 403
  const reorgRes = await fetch(`${base}/api/external-incidents/reorganize`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'dev-unauth',
      'X-Unit-Id': 'unauthorized-test-unit',
      'X-Unit-Code': '9999',
    },
    body: JSON.stringify({ external_ids: ['ext-1'] }),
  });
  assert.equal(reorgRes.status, 403);
  const reorgBody = await reorgRes.json();
  assert.equal(reorgBody.code, 'UNIT_NOT_AUTHORIZED');

  // 3. POST /api/incidents/claim-external: 未授权单位返回 403
  const claimRes = await fetch(`${base}/api/incidents/claim-external`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'dev-unauth',
      'X-Unit-Id': 'unauthorized-test-unit',
      'X-Unit-Code': '9999',
    },
    body: JSON.stringify({
      external_incident: { external_id: 'ext-unauth-1', incident_number: '20261116001' },
      actor_name: '未授权队员',
    }),
  });
  assert.equal(claimRes.status, 403);
  const claimBody = await claimRes.json();
  assert.equal(claimBody.code, 'UNIT_NOT_AUTHORIZED');

  // 4. POLICE_API_ALLOWED_UNIT_IDS 环境变量生效
  const prevAllowed = process.env.POLICE_API_ALLOWED_UNIT_IDS;
  process.env.POLICE_API_ALLOWED_UNIT_IDS = 'allowed-unit-via-env';
  try {
    const allowedReorg = await fetch(`${base}/api/external-incidents/reorganize`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Id': 'dev-allowed-env',
        'X-Unit-Id': 'allowed-unit-via-env',
        'X-Unit-Code': '1002',
      },
      body: JSON.stringify({ external_ids: [] }),
    });
    assert.equal(allowedReorg.status, 200);

    const oldUnitBlocked = await fetch(`${base}/api/external-incidents/reorganize`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Id': 'dev-blocked-env',
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
      },
      body: JSON.stringify({ external_ids: [] }),
    });
    assert.equal(oldUnitBlocked.status, 403);
  } finally {
    if (prevAllowed !== undefined) process.env.POLICE_API_ALLOWED_UNIT_IDS = prevAllowed;
    else delete process.env.POLICE_API_ALLOWED_UNIT_IDS;
  }
});

test('强制刷新限流（10次/分）与 5s 缓存冷却防击穿', async () => {
  const mockServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      errorCode: 0,
      data: {
        list: [{
          id: 'mock-cooling-1',
          incidentNumber: '20261116001',
          detachmentOrgName: '示例市支队',
          brigadeOrganizationName: '示例县大队',
          crimeAddress: '示例县示范路1号',
          incidentTypeName: '火灾扑救',
          incidentStatusName: '出动',
          dispatchVehicle: '1',
          dispatchOrganization: '1',
          registerIncidentTime: Date.now() - 60000,
        }],
        pagination: { total: 1 },
      },
    }));
  });
  await new Promise((r) => mockServer.listen(0, '127.0.0.1', r));
  const mockUrl = `http://127.0.0.1:${mockServer.address().port}/querylist`;

  const oldUrl = process.env.POLICE_API_QUERYLIST_URL;
  process.env.POLICE_API_QUERYLIST_URL = mockUrl;
  policeApiService._resetCacheForTest();

  try {
    // 1. 验证 5s 缓存冷却：即使 forceRefresh: true，短时间内再次请求依然直接命中缓存
    const firstCall = await policeApiService.getExternalIncidents({ forceRefresh: true });
    assert.equal(firstCall.list.length, 1);
    assert.equal(firstCall.cacheHit, false);

    const secondCall = await policeApiService.getExternalIncidents({ forceRefresh: true });
    assert.equal(secondCall.list.length, 1);
    assert.equal(secondCall.cacheHit, true, '5s 冷却期内 forceRefresh 必须返回内存缓存防击穿');

    // 2. 验证 HTTP GET /api/external-incidents?refresh=true 的 10 次/分限流
    const testDeviceId = `dev-ratelimit-${Date.now()}`;
    let limitedHit = false;
    for (let i = 0; i < 12; i++) {
      const res = await fetch(`${base}/api/external-incidents?refresh=true`, {
        headers: {
          'X-Device-Id': testDeviceId,
          'X-Unit-Id': 'example-county-fire-rescue',
          'X-Unit-Code': '1001',
        },
      });
      if (res.status === 429) {
        limitedHit = true;
        const json = await res.json();
        assert.equal(json.code, 'RATE_LIMITED');
        break;
      }
    }
    assert.equal(limitedHit, true, '超过 10 次/分的刷新请求必须返回 429 RATE_LIMITED');

    // 常规无 refresh=true 的请求不受影响
    const normalRes = await fetch(`${base}/api/external-incidents`, {
      headers: {
        'X-Device-Id': testDeviceId,
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
      },
    });
    assert.equal(normalRes.status, 200);
  } finally {
    mockServer.closeAllConnections?.();
    mockServer.close();
    if (oldUrl) process.env.POLICE_API_QUERYLIST_URL = oldUrl;
    else delete process.env.POLICE_API_QUERYLIST_URL;
    policeApiService._resetCacheForTest();
  }
});

test('外部警情出参最小化裁剪与敏感电话姓名脱敏', async () => {
  const ts = Date.now();
  const rawItem = {
    id: `ext-prune-${ts}`,
    incidentNumber: `INC-PRUNE-${ts}`,
    detachmentOrgName: '示例市支队',
    detachmentOrgId: 'secret-detachment-uuid',
    brigadeOrganizationName: '示例县大队',
    squadronOrganizationName: '示例路站',
    districtName: '示例县',
    incidentTypeName: '火灾扑救',
    incidentStatusName: '出动',
    crimeAddress: '示例县示范路88号',
    alarmPhone: '010-8888999',
    alarmPersonPhone: '13812345678',
    alarmPersonName: '张三丰',
    dispatchVehicle: '2',
    dispatchOrganization: '1',
    registerIncidentTime: ts - 60000,
    raw_payload: { sensitive_internal_key: 'confidential' },
    raw_merged_text: '内部合并全文本',
  };

  const normalized = policeApiService.normalizeExternalIncident(rawItem);
  await app.externalIncidentOrganizer.saveIncident(normalized, ts);

  const mockServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      errorCode: 0,
      data: { list: [rawItem], pagination: { total: 1 } },
    }));
  });
  await new Promise((r) => mockServer.listen(0, '127.0.0.1', r));
  const mockUrl = `http://127.0.0.1:${mockServer.address().port}/querylist`;
  const oldUrl = process.env.POLICE_API_QUERYLIST_URL;
  process.env.POLICE_API_QUERYLIST_URL = mockUrl;
  policeApiService._resetCacheForTest();

  try {
    const res = await fetch(`${base}/api/external-incidents?refresh=true`, {
      headers: {
        'X-Device-Id': `dev-prune-${ts}`,
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
      },
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.ok(Array.isArray(body.list) && body.list.length > 0);
    const target = body.list.find((i) => i.external_id === rawItem.id);
    assert.ok(target);

    // 1. 验证关键内部字段已被裁剪剔除
    assert.equal('raw_payload' in target, false, '禁止下发 raw_payload');
    assert.equal('raw_merged_text' in target, false, '禁止下发 raw_merged_text');
    assert.equal('detachment_id' in target, false, '禁止下发 detachment_id');

    // 2. 验证报警人手机号与姓名已脱敏掩码
    assert.equal(target.alarm_person_phone, '138****5678', '手机号应保留前后位中间掩码');
    assert.equal(target.alarm_phone.includes('****'), true, '座机应包含掩码');
    assert.equal(target.alarm_person_name, '张*丰', '姓名应脱敏');
    if (Array.isArray(target.contacts) && target.contacts.length > 0) {
      assert.equal(target.contacts[0].phone, '138****5678');
      assert.equal(target.contacts[0].name, '张*丰');
    }

    // 3. 验证 POST /api/external-incidents/reorganize 同样裁剪并脱敏
    const reorgRes = await fetch(`${base}/api/external-incidents/reorganize`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Id': `dev-reorg-prune-${ts}`,
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
      },
      body: JSON.stringify({ external_ids: [rawItem.id] }),
    });
    assert.equal(reorgRes.status, 200);
    const reorgBody = await reorgRes.json();
    const reorgTarget = reorgBody.list.find((i) => i.external_id === rawItem.id);
    assert.ok(reorgTarget);
    assert.equal('raw_payload' in reorgTarget, false);
    assert.equal('raw_merged_text' in reorgTarget, false);
    assert.equal('detachment_id' in reorgTarget, false);
    assert.equal(reorgTarget.alarm_person_phone, '138****5678');
  } finally {
    mockServer.closeAllConnections?.();
    mockServer.close();
    if (oldUrl) process.env.POLICE_API_QUERYLIST_URL = oldUrl;
    else delete process.env.POLICE_API_QUERYLIST_URL;
    policeApiService._resetCacheForTest();
  }
});

test('认领警情防客户端篡改：强制采用服务端权威记录建档并填充真实联系人，拒绝伪造ID', async () => {
  const ts = Date.now();
  const extId = `auth-claim-${ts}`;
  const incNumber = `POLICE-AUTH-${ts}`;

  // 1. 服务端保存真实官方权威警情（包含真实地址、出动力量与真实未脱敏联系人）
  const authenticRecord = policeApiService.normalizeExternalIncident({
    id: extId,
    incidentNumber: incNumber,
    detachmentOrgName: '示例市支队',
    brigadeOrganizationName: '示例县大队',
    squadronOrganizationName: '示例路站',
    districtName: '示例县',
    incidentTypeName: '火灾扑救',
    incidentStatusName: '出动',
    crimeAddress: '示例县示范路88号商铺',
    incidentDescribe: '沿街餐饮商铺后厨油烟管道起火',
    dispatchVehicle: '2',
    dispatchOrganization: '1',
    registerIncidentTime: ts - 60000,
    alarmPersonName: '真实报警人',
    alarmPersonPhone: '13912345678',
  });
  await app.externalIncidentOrganizer.saveIncident(authenticRecord, ts);

  // 2. 客户端发起认领请求，但恶意篡改事发地址、事件标题、调派力量和联系人
  const claimRes = await fetch(`${base}/api/incidents/claim-external`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'dev-attacker',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
      'X-Op-Id': `claim-tamper-${ts}`,
    },
    body: JSON.stringify({
      external_incident: {
        external_id: extId,
        incident_number: incNumber,
        event_summary: '恶意黑客篡改的假灾情标题',
        crime_address: '虚假篡改地址999号',
        dispatched_forces: [
          { station_name: '假消防站', vehicle_count: 999, personnel_count: 999 },
        ],
        contacts: [
          { name: '假联系人', phone: '13000000000', role: '报警人' },
        ],
      },
      actor_name: '认领测试员',
    }),
  });

  assert.equal(claimRes.status, 201);
  const claimedBody = await claimRes.json();

  // 3. 验证服务端建档以服务端权威记录为准，忽略客户端篡改
  assert.equal(claimedBody.title, '沿街餐饮商铺后厨油烟管道起火', '主标题必须来自服务端权威提炼，忽略客户端篡改');
  assert.equal(claimedBody.info.event_summary, '沿街餐饮商铺后厨油烟管道起火');
  assert.equal(claimedBody.info.location, '示例县示范路88号商铺', '事发地点必须来自权威记录');

  // 验证出动力量为服务端真实的示例路站，而非假消防站
  assert.equal(claimedBody.forces.length, 1);
  assert.equal(claimedBody.forces[0].station_name, '示例路站');
  assert.equal(claimedBody.forces[0].vehicle_count, 2);

  // 4. 验证 incident_details 中完整填充了服务端保存的真实未脱敏联系人与派车统计
  const savedDetails = app._getLocalIncidentDetailsForTest(claimedBody.id);
  assert.ok(savedDetails, '认领建档后必须写入 incident_details');
  assert.deepEqual(savedDetails.contacts, [
    { role: '报警人', name: '真实报警人', phone: '13912345678' },
  ], '建档详情必须保留服务端真实未脱敏联系人，严禁丢失或被伪造覆盖');
  assert.equal(savedDetails.dispatch_vehicles, '2');
  assert.equal(savedDetails.dispatch_stations, '1');

  const detailRes = await fetch(`${base}/api/incidents/${claimedBody.id}`, {
    headers: {
      'X-Device-Id': 'dev-attacker',
      'X-Unit-Id': 'example-county-fire-rescue',
      'X-Unit-Code': '1001',
    },
  });
  assert.equal(detailRes.status, 200);

  // 5. 严格模式下伪造不存在的 external_id 认领必须返回 404
  const prevStrict = process.env.POLICE_API_STRICT_CLAIM;
  process.env.POLICE_API_STRICT_CLAIM = '1';
  try {
    const forgedRes = await fetch(`${base}/api/incidents/claim-external`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-Id': 'dev-forged',
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
        'X-Op-Id': `claim-forged-${ts}`,
      },
      body: JSON.stringify({
        external_incident: {
          external_id: `forged-not-exists-${ts}`,
          incident_number: `FORGED-${ts}`,
          event_summary: '伪造警情',
        },
        actor_name: '伪造攻击者',
      }),
    });
    assert.equal(forgedRes.status, 404);
    const forgedBody = await forgedRes.json();
    assert.equal(forgedBody.code, 'EXTERNAL_INCIDENT_NOT_FOUND');
  } finally {
    if (prevStrict !== undefined) process.env.POLICE_API_STRICT_CLAIM = prevStrict;
    else delete process.env.POLICE_API_STRICT_CLAIM;
  }
});

test('LLM 提示词脱敏：剔除报警人姓名与手机号，防止第三方模型隐私泄漏', async () => {
  const { sanitizePromptTextForLlm, organizeWithDeepSeek } = require('../src/external-incident-organizer');

  const rawMergedText = [
    '警情编号: 202611160088',
    '立案时间: 2026-11-16 10:00:00',
    '所属支队: 示例市支队',
    '行政区域: 示例县',
    '警情描述: 报警人张三（电话13812345678，备用010-8888999）报警称示范路一民房起火，邻居李四（13900001111）在场协助',
    '报警联系: 张三 13812345678',
  ].join('\n');

  // 1. 验证工具函数脱敏逻辑
  const sanitized = sanitizePromptTextForLlm(rawMergedText, {
    alarm_person_name: '张三',
    alarm_person_phone: '13812345678',
  });
  assert.equal(sanitized.includes('报警联系'), false, '报警联系整行必须被彻底剔除');
  assert.equal(sanitized.includes('13812345678'), false, '手机号必须被剥离或替换');
  assert.equal(sanitized.includes('13900001111'), false, '正文出现的手机号必须被脱敏');
  assert.equal(sanitized.includes('010-8888999'), false, '固定电话必须被脱敏');
  assert.equal(sanitized.includes('张三'), false, '报警人姓名必须被剔除');

  // 2. 验证发往 DeepSeek 的实际请求体被严格脱敏
  let capturedBody = null;
  const mockFetch = async (_url, options) => {
    capturedBody = JSON.parse(options.body);
    return {
      ok: true,
      async json() {
        return {
          choices: [{
            message: {
              content: JSON.stringify({
                event_summary: '示范路民房起火',
                disaster_category: 'fire',
                location_display: '示例县示范路',
                situation_detail: '民房起火',
              }),
            },
          }],
        };
      },
    };
  };

  await organizeWithDeepSeek({
    apiKey: 'test-key',
    rawMergedText,
    fallback: {
      alarm_person_name: '张三',
      alarm_person_phone: '13812345678',
      event_summary: '民房起火',
      incident_type: '火灾扑救',
    },
    fetchImpl: mockFetch,
  });

  assert.ok(capturedBody);
  const promptContent = capturedBody.messages[1].content;
  assert.equal(promptContent.includes('13812345678'), false);
  assert.equal(promptContent.includes('13900001111'), false);
  assert.equal(promptContent.includes('010-8888999'), false);
  assert.equal(promptContent.includes('张三'), false);
});

test('fetchFromUpstream 遇非辖区超3天旧记录立即停止翻页，避免多余串行请求', async (t) => {
  const now = Date.now();
  const requestedPages = [];
  const mockServer = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      const parsed = JSON.parse(raw || '{}');
      const page = parsed?.pagination?.page || 1;
      requestedPages.push(page);
      const list = Array.from({ length: 100 }, (_, idx) => {
        if (idx === 0) {
          return {
            id: 'recent-local-1',
            incidentNumber: '202611190001',
            detachmentOrgName: '示例市支队',
            brigadeOrganizationName: '示例县大队',
            crimeAddress: '示例县和平路1号',
            incidentStatusName: '出动',
            dispatchVehicle: '2',
            registerIncidentTime: now - 10 * 60 * 1000,
          };
        }
        return {
          id: `other-city-old-${idx}`,
          incidentNumber: `2026111000${idx}`,
          detachmentOrgName: '异地支队',
          crimeAddress: '异地市甲区旧街道',
          incidentStatusName: '归队',
          registerIncidentTime: now - 5 * 24 * 3600 * 1000,
        };
      });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        errorCode: 0,
        data: { list, pagination: { total: 500 } },
      }));
    });
  });

  await new Promise((resolve) => mockServer.listen(0, '127.0.0.1', resolve));
  const mockUrl = `http://127.0.0.1:${mockServer.address().port}/querylist`;
  t.after(() => {
    mockServer.closeAllConnections?.();
    mockServer.close();
    policeApiService._resetCacheForTest();
  });

  policeApiService._resetCacheForTest();
  const result = await policeApiService.getExternalIncidents({
    forceRefresh: true,
    upstreamUrl: mockUrl,
  });

  assert.deepEqual(requestedPages, [1], '第1页已出现超3天非辖区记录，不应继续请求第2页');
  assert.equal(result.list.length, 1);
  assert.equal(result.list[0].external_id, 'recent-local-1');
});

test('getExternalIncidents SWR：旧内存缓存与持久化兜底立即返回并异步后台刷新', async (t) => {
  const now = Date.now();
  let upstreamHits = 0;
  let releaseUpstream;
  const upstreamGate = new Promise((resolve) => { releaseUpstream = resolve; });

  const mockServer = http.createServer(async (req, res) => {
    upstreamHits++;
    await upstreamGate;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      errorCode: 0,
      data: {
        list: [{
          id: 'fresh-ext-2',
          incidentNumber: '202611190002',
          detachmentOrgName: '示例市支队',
          brigadeOrganizationName: '示例县大队',
          crimeAddress: '示例县新建路8号',
          incidentStatusName: '出动',
          dispatchVehicle: '1',
          registerIncidentTime: now - 60 * 1000,
        }],
        pagination: { total: 1 },
      },
    }));
  });

  await new Promise((resolve) => mockServer.listen(0, '127.0.0.1', resolve));
  const mockUrl = `http://127.0.0.1:${mockServer.address().port}/querylist`;
  t.after(() => {
    releaseUpstream();
    mockServer.closeAllConnections?.();
    mockServer.close();
    policeApiService._resetCacheForTest();
  });

  // 1) 内存旧缓存超过 60s：allowStale=true 立即返回旧缓存，同时触发后台刷新
  policeApiService._resetCacheForTest();
  policeApiService._setCacheForTest({
    data: [{ external_id: 'stale-mem-1', incident_number: '202611180001' }],
    fetchedAt: now - 120 * 1000,
  });

  const t0 = Date.now();
  const staleRes = await policeApiService.getExternalIncidents({
    forceRefresh: false,
    upstreamUrl: mockUrl,
  });
  assert.equal(staleRes.stale, true);
  assert.equal(staleRes.cacheHit, true);
  assert.equal(staleRes.list[0].external_id, 'stale-mem-1');
  assert.ok(Date.now() - t0 < 200, 'SWR 命中旧缓存不应阻塞等待上游响应');

  // 放行上游响应后，缓存更新为最新记录
  releaseUpstream();
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(upstreamHits, 1);
  assert.equal(policeApiService.peekCachedIncidents()[0]?.external_id, 'fresh-ext-2');

  // 2) 容器重启内存为空时，命中 fallbackLoader 立即返回持久化记录并后台刷新
  policeApiService._resetCacheForTest();
  const persistedRes = await policeApiService.getExternalIncidents({
    forceRefresh: false,
    upstreamUrl: mockUrl,
    fallbackLoader: async () => [{ external_id: 'persisted-db-1', incident_number: '202611180099' }],
  });
  assert.equal(persistedRes.stale, true);
  assert.equal(persistedRes.fromPersistedStore, true);
  assert.equal(persistedRes.list[0].external_id, 'persisted-db-1');
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(policeApiService.peekCachedIncidents()[0]?.external_id, 'fresh-ext-2');
});

test('external-incident-organizer syncIncidents 批量 upsert 落库且支持 listRecentStoredIncidents', async () => {
  const { createExternalIncidentOrganizer } = require('../src/external-incident-organizer');
  const upsertCalls = [];
  const fakeRows = new Map();
  const fakeStore = {
    async select(table, opts = {}) {
      if (table !== 'external_incidents') return [];
      let rows = [...fakeRows.values()];
      if (opts.filters?.external_id?.op === 'in') {
        const set = new Set(opts.filters.external_id.value);
        rows = rows.filter((r) => set.has(r.external_id));
      }
      if (opts.filters?.register_time?.op === 'gte') {
        rows = rows.filter((r) => Number(r.register_time) >= Number(opts.filters.register_time.value));
      }
      rows.sort((a, b) => Number(b.register_time) - Number(a.register_time));
      return opts.limit ? rows.slice(0, opts.limit) : rows;
    },
    async upsert(table, rows) {
      upsertCalls.push({ table, count: rows.length });
      for (const row of rows) {
        fakeRows.set(row.external_id, row);
      }
      return rows;
    },
  };

  const organizer = createExternalIncidentOrganizer({
    store: fakeStore,
    syncSupported: () => true,
    getLlmConfig: () => ({}),
  });

  const now = Date.now();
  const batch = [
    {
      external_id: 'batch-1',
      incident_number: '202611191001',
      crime_address: '示例县示例路1号',
      incident_type: '火灾扑救',
      incident_status: '出动',
      register_time: now - 1000,
    },
    {
      external_id: 'batch-2',
      incident_number: '202611191002',
      crime_address: '示例县示例路2号',
      incident_type: '抢险救援',
      incident_status: '到场',
      register_time: now - 2000,
    },
    {
      external_id: 'batch-old',
      incident_number: '202611101003',
      crime_address: '示例县旧路3号',
      incident_type: '社会救助',
      incident_status: '归队',
      register_time: now - 5 * 24 * 3600 * 1000,
    },
  ];

  await organizer.syncIncidents(batch, { awaitAi: false });
  assert.equal(upsertCalls.length, 1, '3 条新增记录应合并为单次批量 upsert');
  assert.equal(upsertCalls[0].count, 3);

  const recent = await organizer.listRecentStoredIncidents({
    sinceMs: now - 3 * 24 * 3600 * 1000,
    limit: 20,
  });
  assert.deepEqual(recent.map((r) => r.external_id), ['batch-1', 'batch-2']);
});
