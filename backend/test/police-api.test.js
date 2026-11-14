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
  server = app.listen(0, '127.0.0.1');
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
            id: 'mock-qz-recent',
            incidentNumber: '20261107001',
            detachmentOrgName: '衢州支队',
            brigadeOrganizationName: '柯城大队',
            crimeAddress: '柯城区三江路10号',
            incidentTypeName: '抢险救援',
            incidentStatusName: '出动',
            dispatchVehicle: '2',
            dispatchOrganization: '1',
            registerIncidentTime: now - 3600 * 1000,
          },
          {
            id: 'mock-qz-filing-only',
            incidentNumber: '20261107003',
            detachmentOrgName: '衢州支队',
            brigadeOrganizationName: '柯城大队',
            crimeAddress: '柯城区示例街道18号',
            incidentTypeName: '火灾扑救',
            incidentStatusName: '立案',
            dispatchVehicle: '0',
            dispatchOrganization: '0',
            registerIncidentTime: now - 1800 * 1000,
          },
          {
            id: 'mock-qz-old',
            incidentNumber: '20261101002',
            detachmentOrgName: '衢州支队',
            crimeAddress: '超过3天的旧警情',
            incidentStatusName: '归队',
            registerIncidentTime: now - 5 * 24 * 3600 * 1000,
          },
          {
            id: 'mock-other-city',
            incidentNumber: '20261107999',
            detachmentOrgName: '宁波支队',
            crimeAddress: '宁波市海曙区',
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
    assert.equal(body1.title, '商铺电线短路起火', '认领后主标题应为提炼后的灾情事件而非地址');
    assert.equal(body1.info.event_summary, '商铺电线短路起火');
    assert.equal(body1.info.disaster_category, 'fire');
    assert.equal(body1.info.latitude, '28.8693');
    assert.equal(body1.info.longitude, '118.9805');
    assert.equal(body1.info.dispatch_summary, '4车 2站 (主调: 双塔站)');
    assert.equal(body1.forces.length, 1);
    assert.equal(body1.forces[0].station_name, '双塔站');
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
  await new Promise((resolve) => mockUpstream.listen(0, '127.0.0.1', resolve));
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
    body: JSON.stringify({ external_ids: ['mock-qz-recent'] }),
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
  t.after(() => {
    mockQueryServer.close();
    policeApiService._resetCacheForTest();
  });

  policeApiService._resetCacheForTest();
  await policeApiService.getQuzhouIncidents({ forceRefresh: true, upstreamUrl: mockUrl });

  assert.equal(capturedMethod, 'POST');
  assert.equal(capturedBody.whetherPage, true);
  assert.equal(capturedBody.scopeType, 1);
  assert.equal(typeof capturedBody.scopeSquadronId, 'string');
  assert.ok(capturedBody.scopeSquadronId.length > 0);
  assert.deepEqual(capturedBody.squadronIds, []);
  assert.ok(Number(capturedBody.startTime) > 0);
  assert.ok(Number(capturedBody.endTime) > Number(capturedBody.startTime));
  assert.deepEqual(capturedBody.pagination, { page: 1, size: 100 });
  assert.ok(policeApiService.DEFAULT_QUERYLIST_URL.endsWith('/disater/querylist'));
  assert.ok(policeApiService.DEFAULT_HOMEINFO_URL.endsWith('/home/homeinfo'));

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
