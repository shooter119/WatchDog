'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { Pool } = require('pg');
const sharp = require('sharp');
const WebSocket = require('ws');

process.env.NODE_ENV = 'test';
process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';

const baseDbUrl = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const adminPool = new Pool({ connectionString: baseDbUrl });
const schema = `note_media_${process.pid}_${Date.now()}`;
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-note-media-'));

let store;
let db;
let serverProc;
let base;
let tokenUnitA;
let tokenUnitB;

const {
  purgeArchivedNoteMedia,
  resolveNoteMediaRoot,
} = require('../src/note-media');

async function startServer() {
  const port = 17000 + Math.floor(Math.random() * 19000);
  serverProc = spawn(process.execPath, ['src/server.js'], {
    cwd: path.join(__dirname, '..'),
    env: {
      ...process.env,
      PORT: String(port),
      API_TOKEN: '',
      WATCHDOG_DATA_DIR: dataDir,
      WATCHDOG_UNIT_AUTH_REQUIRED: '1',
      WATCHDOG_SESSION_AUTH_REQUIRED: '1',
      WATCHDOG_MEMBER_AUTH_REQUIRED: '1',
      WATCHDOG_ENTRY_VERSION_REQUIRED: '0',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let logs = '';
  serverProc.stdout.on('data', (c) => { logs += c.toString(); });
  serverProc.stderr.on('data', (c) => { logs += c.toString(); });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 150; i++) {
    try {
      if ((await fetch(`${url}/api/health`)).ok) return url;
    } catch (_) {}
    if (serverProc.exitCode != null) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`note-media 测试后端未启动: ${logs}`);
}

async function login(unitName, unitCode, realName, deviceId) {
  const res = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-Id': deviceId },
    body: JSON.stringify({
      unit_name: unitName,
      unit_code: unitCode,
      real_name: realName,
      device_name: deviceId,
      platform: 'Android',
    }),
  });
  assert.equal(res.status, 200);
  return (await res.json()).session_token;
}

function fakeMp4Buffer(size = 4096) {
  const buf = Buffer.alloc(size, 0x2a);
  buf.writeUInt32BE(24, 0);
  buf.write('ftypisom', 4, 'ascii');
  buf.writeUInt32BE(512, 12);
  buf.write('isomiso2avc1mp41', 16, 'ascii');
  return buf;
}

before(async () => {
  await adminPool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseDbUrl);
  const existingOptions = url.searchParams.get('options') || '';
  url.searchParams.set('options', `${existingOptions} -c search_path=${schema}`.trim());
  process.env.DATABASE_URL = url.toString();

  db = require('../src/db');
  store = require('../src/postgres-store');
  await db.ready;

  const now = Date.now();
  await store.query(
    "INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES ('u-media-a','示例支队甲站','1001',$1,$1), ('u-media-b','示例支队乙站','1002',$1,$1)",
    [now],
  );
  await store.query(
    `INSERT INTO unit_members(id,unit_id,real_name,role,status,review_status,created_at,updated_at) VALUES
      ('m-a1','u-media-a','张三','member','active','approved',$1,$1),
      ('m-b1','u-media-b','李四','member','active','approved',$1,$1)`,
    [now],
  );

  base = await startServer();
  tokenUnitA = await login('示例支队甲站', '1001', '张三', 'dev-media-a1');
  tokenUnitB = await login('示例支队乙站', '1002', '李四', 'dev-media-b1');
});

after(async () => {
  if (serverProc && serverProc.exitCode == null) {
    serverProc.kill('SIGTERM');
    await new Promise((r) => serverProc.once('exit', r));
  }
  await store?.close();
  await adminPool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await adminPool.end();
  await fsp.rm(dataDir, { recursive: true, force: true }).catch(() => {});
});

test('020 迁移建表、照片上传压缩与幂等重放、实时 note.created 与列表附件透传', async () => {
  const incRes = await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${tokenUnitA}`,
      'X-Op-Id': randomUUID(),
    },
    body: JSON.stringify({ title: '示例路物流仓火灾' }),
  });
  assert.equal(incRes.status, 201);
  const incident = await incRes.json();

  // 订阅实时通道验证 note.created 是否携带 media 字段
  const ws = new WebSocket(`${base.replace('http', 'ws')}/api/realtime`, {
    headers: { Authorization: `Bearer ${tokenUnitA}`, 'X-Device-Id': 'ws-observer' },
  });
  await new Promise((resolve) => ws.once('open', resolve));
  ws.send(JSON.stringify({ type: 'subscribe', incident_id: incident.id, unit_cursor: '0', incident_cursor: '0' }));
  const pushedEvents = [];
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString());
    if (msg.type === 'event') pushedEvents.push(msg);
  });
  await new Promise((r) => setTimeout(r, 150));

  const largePng = await sharp({
    create: { width: 2400, height: 1350, channels: 3, background: { r: 24, g: 96, b: 200 } },
  }).png().toBuffer();

  const opId = `op-photo-${randomUUID()}`;
  const capturedAt = Date.now() - 1000;
  const buildForm = () => {
    const form = new FormData();
    form.set('kind', 'photo');
    form.set('captured_at', String(capturedAt));
    form.set('address', '示例路88号');
    form.set('weather', '晴 20°C');
    form.set('media_ref', 'local-photo-1');
    form.set('file', new Blob([largePng], { type: 'image/png' }), 'photo_wm.png');
    return form;
  };

  const uploadRes = await fetch(`${base}/api/notes/media`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${tokenUnitA}`,
      'X-Incident-Id': incident.id,
      'X-Op-Id': opId,
    },
    body: buildForm(),
  });
  assert.equal(uploadRes.status, 201);
  const created = await uploadRes.json();
  assert.equal(created.text, '现场拍照 · 示例路88号');
  assert.equal(created.category, '其他');
  assert.equal(created.author, '张三');
  assert.equal(created.media.length, 1);

  const media = created.media[0];
  assert.equal(media.kind, 'photo');
  assert.equal(media.mime, 'image/jpeg');
  assert.equal(media.available, true);
  assert.equal(media.width, 1920);
  assert.equal(media.height, 1080);

  // 同 X-Op-Id 重试幂等返回同一条日志且不重复写盘
  const replayRes = await fetch(`${base}/api/notes/media`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${tokenUnitA}`,
      'X-Incident-Id': incident.id,
      'X-Op-Id': opId,
    },
    body: buildForm(),
  });
  assert.equal(replayRes.status, 200);
  const replayed = await replayRes.json();
  assert.equal(replayed.id, created.id);
  assert.equal(replayed.media[0].id, media.id);

  // 等实时事件到达
  for (let i = 0; i < 20 && !pushedEvents.some((e) => e.event_type === 'note.created'); i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  const pushedNote = pushedEvents.find((e) => e.event_type === 'note.created');
  assert.ok(pushedNote);
  assert.equal(pushedNote.payload.media.length, 1);
  assert.equal(pushedNote.payload.media[0].id, media.id);
  ws.close();

  // 列表 / bootstrap 查询包含附件
  const listRes = await fetch(`${base}/api/notes`, {
    headers: { Authorization: `Bearer ${tokenUnitA}`, 'X-Incident-Id': incident.id },
  });
  assert.equal(listRes.status, 200);
  const list = await listRes.json();
  assert.equal(list[0].media[0].id, media.id);

  // 同单位可读原图与缩略图；跨单位与无认证拒绝
  const fileRes = await fetch(`${base}${media.file_url}`, {
    headers: { Authorization: `Bearer ${tokenUnitA}` },
  });
  assert.equal(fileRes.status, 200);
  assert.equal(fileRes.headers.get('content-type'), 'image/jpeg');
  const thumbRes = await fetch(`${base}${media.thumb_url}`, {
    headers: { Authorization: `Bearer ${tokenUnitA}` },
  });
  assert.equal(thumbRes.status, 200);

  const crossUnit = await fetch(`${base}${media.file_url}`, {
    headers: { Authorization: `Bearer ${tokenUnitB}` },
  });
  assert.equal(crossUnit.status, 404);

  const noAuth = await fetch(`${base}${media.file_url}`);
  assert.equal(noAuth.status, 401);
});

test('视频与语音转文字融合入火场日志、同步口述去重、HTTP 206 Range 播放及删日志清磁盘', async () => {
  const incident = await db.createIncident({
    id: `inc-vid-${randomUUID()}`,
    unitId: 'u-media-a',
    title: '示例化工厂区演练',
    createdAt: Date.now() - 120_000,
  });

  const thumbJpg = await sharp({
    create: { width: 640, height: 360, channels: 3, background: { r: 200, g: 60, b: 40 } },
  }).jpeg().toBuffer();
  const mp4 = fakeMp4Buffer(8192);

  const form = new FormData();
  form.set('kind', 'video');
  form.set('text', '北侧车间出水压制火势，暂未发现人员被困');
  form.set('duration_ms', '15000');
  form.set('captured_at', String(Date.now() - 2000));
  form.set('media_ref', 'local-vid-1');
  form.set('sync_observation', '1');
  form.set('file', new Blob([mp4], { type: 'video/mp4' }), 'vid_wm.mp4');
  form.set('thumb', new Blob([thumbJpg], { type: 'image/jpeg' }), 'thumb.jpg');

  const uploadRes = await fetch(`${base}/api/notes/media`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${tokenUnitA}`,
      'X-Incident-Id': incident.id,
      'X-Op-Id': `op-vid-${randomUUID()}`,
    },
    body: form,
  });
  assert.equal(uploadRes.status, 201);
  const note = await uploadRes.json();
  assert.equal(note.text, '北侧车间出水压制火势，暂未发现人员被困');
  assert.equal(note.category, '出水');
  assert.equal(note.media[0].kind, 'video');
  assert.equal(note.media[0].mime, 'video/mp4');
  assert.equal(note.media[0].duration_ms, 15000);
  assert.ok(note.media[0].thumb_url);

  // 口述已自动同步至 incident_observations
  const obsRes = await fetch(`${base}/api/incident-observations`, {
    headers: { Authorization: `Bearer ${tokenUnitA}`, 'X-Incident-Id': incident.id },
  });
  const obsList = await obsRes.json();
  assert.equal(obsList.length, 1);
  assert.equal(obsList[0].media_ref, 'local-vid-1');
  assert.equal(obsList[0].transcript, '北侧车间出水压制火势，暂未发现人员被困');

  // HTTP Range 206 Partial Content 流式播放支持
  const rangeRes = await fetch(`${base}${note.media[0].file_url}`, {
    headers: { Authorization: `Bearer ${tokenUnitA}`, Range: 'bytes=0-127' },
  });
  assert.equal(rangeRes.status, 206);
  assert.equal(rangeRes.headers.get('content-range'), `bytes 0-127/${mp4.length}`);
  const chunk = Buffer.from(await rangeRes.arrayBuffer());
  assert.equal(chunk.length, 128);
  assert.equal(Buffer.compare(chunk, mp4.subarray(0, 128)), 0);

  // 磁盘目录存在；删除日志后磁盘目录被一并清理
  const mediaRoot = resolveNoteMediaRoot(path.join(dataDir, 'note-media'));
  const mediaDir = path.join(mediaRoot, note.media[0].id);
  assert.equal(fs.existsSync(mediaDir), true);

  const delRes = await fetch(`${base}/api/notes/${note.id}`, {
    method: 'DELETE',
    headers: {
      Authorization: `Bearer ${tokenUnitA}`,
      'X-Incident-Id': incident.id,
      'X-Op-Id': randomUUID(),
    },
  });
  assert.equal(delRes.status, 200);
  assert.equal(fs.existsSync(mediaDir), false);
});

test('归档媒体 90 天与 5GB 容量清理：处置中警情绝不清理，已清理返回 410 且文字日志永久保留', async () => {
  const createInc = async (title) => db.createIncident({
    id: `inc-purge-${randomUUID()}`,
    unitId: 'u-media-a',
    title,
    createdAt: Date.now() - 120_000,
  });
  const uploadVid = async (incidentId, size, text) => {
    const form = new FormData();
    form.set('kind', 'video');
    form.set('text', text);
    form.set('file', new Blob([fakeMp4Buffer(size)], { type: 'video/mp4' }), 'v.mp4');
    const res = await fetch(`${base}/api/notes/media`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${tokenUnitA}`,
        'X-Incident-Id': incidentId,
        'X-Op-Id': randomUUID(),
      },
      body: form,
    });
    assert.equal(res.status, 201);
    return res.json();
  };

  const activeInc = await createInc('处置中长期扑救');
  const archivedInc = await createInc('已归档旧警情');
  const noteActive = await uploadVid(activeInc.id, 4096, '处置中视频不能被清理');
  const noteExpired = await uploadVid(archivedInc.id, 4096, '90天过期归档视频');
  const noteQuota = await uploadVid(archivedInc.id, 5120, '超限配额归档视频');

  // 将 archivedInc 设为 archived，并把两个媒体创建时间调旧（其中第一个超过 90 天）
  await store.query("UPDATE incidents SET status = 'archived', archived_at = 1 WHERE id = $1", [archivedInc.id]);
  const now = Date.now();
  await store.query('UPDATE note_media SET created_at = $1 WHERE id = $2', [now - 100 * 24 * 3600 * 1000, noteExpired.media[0].id]);
  await store.query('UPDATE note_media SET created_at = $1 WHERE id = $2', [now - 10 * 24 * 3600 * 1000, noteQuota.media[0].id]);
  await store.query('UPDATE note_media SET created_at = $1 WHERE id = $2', [now - 120 * 24 * 3600 * 1000, noteActive.media[0].id]);

  // 设总上限为 4500 字节：noteExpired 因超 90 天先清理，剩余 active(4096)+quota(5120)=9216 > 4500 -> quota 再被淘汰；active 超过 120 天依然豁免！
  const summary = await purgeArchivedNoteMedia(store, {
    rootDir: resolveNoteMediaRoot(path.join(dataDir, 'note-media')),
    retentionDays: 90,
    maxTotalBytes: 4500,
    now,
  });
  assert.equal(summary.expiredCount, 1);
  assert.equal(summary.quotaCount, 1);

  // 已清理媒体返回 410，文字日志依然完整保留
  const goneRes = await fetch(`${base}${noteExpired.media[0].file_url}`, {
    headers: { Authorization: `Bearer ${tokenUnitA}` },
  });
  assert.equal(goneRes.status, 410);

  const archivedNotesRes = await fetch(`${base}/api/notes`, {
    headers: { Authorization: `Bearer ${tokenUnitA}`, 'X-Incident-Id': archivedInc.id },
  });
  const archivedNotes = await archivedNotesRes.json();
  assert.equal(archivedNotes.length, 2);
  assert.equal(archivedNotes[0].media[0].available, false);
  assert.ok(archivedNotes[0].media[0].purged_at > 0);

  // 处置中警情媒体完全不受影响
  const stillAliveRes = await fetch(`${base}${noteActive.media[0].file_url}`, {
    headers: { Authorization: `Bearer ${tokenUnitA}` },
  });
  assert.equal(stillAliveRes.status, 200);
});
