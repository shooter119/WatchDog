'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  buildCloudBaseObjectUrl,
  encodeObjectPath,
  maxCloudBaseObjectBytes,
  parseArguments,
  uploadObject,
} = require('./cloudbase-ota-upload.cjs');

async function withServer(handler, action) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  try {
    return await action(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  }
}

function createFixture(content = 'watchdog-ota-test') {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-ota-test-'));
  const filePath = path.join(directory, 'fixture.bin');
  fs.writeFileSync(filePath, content);
  return {
    content: Buffer.from(content),
    filePath,
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
  };
}

test('对象 URL 固定使用 CloudBase API 域名并逐段编码路径', () => {
  const url = buildCloudBaseObjectUrl({
    envId: 'watchdog-prod-123',
    bucketId: 'watchdog-ota',
    objectPath: 'releases/v1.2.3+59/watchdog 正式版.apk',
  });
  assert.equal(url.protocol, 'https:');
  assert.equal(url.hostname, 'watchdog-prod-123.api.tcloudbasegateway.com');
  assert.equal(
    url.pathname,
    '/v1/storages/object/watchdog-ota/releases/v1.2.3%2B59/watchdog%20%E6%AD%A3%E5%BC%8F%E7%89%88.apk',
  );
});

test('拒绝目录穿越、空目录段和不完整 CLI 参数', () => {
  for (const invalid of ['', '/latest.json', 'releases//app.apk', 'releases/../app.apk']) {
    assert.throws(() => encodeObjectPath(invalid));
  }
  assert.throws(() => parseArguments(['--file', 'app.apk']));
  assert.throws(() => parseArguments(['--unknown', 'value']));
});

test('以二进制正文 POST 上传并发送官方契约所需头', async () => {
  const fixture = createFixture();
  try {
    await withServer(
      (request, response) => {
        const chunks = [];
        request.on('data', (chunk) => chunks.push(chunk));
        request.on('end', () => {
          assert.equal(request.method, 'POST');
          assert.equal(request.url, '/v1/storages/object/watchdog-ota/releases/v1.2.3%2B59/app.apk');
          assert.equal(request.headers.authorization, 'Bearer test-service-role-key');
          assert.equal(request.headers['x-upsert'], 'true');
          assert.equal(request.headers['content-type'], 'application/vnd.android.package-archive');
          assert.equal(request.headers['content-length'], String(fixture.content.length));
          assert.equal(request.headers['cache-control'], 'public,max-age=31536000,immutable');
          assert.deepEqual(Buffer.concat(chunks), fixture.content);
          response.writeHead(200, { 'Content-Type': 'application/json' });
          response.end('{"Id":"object-id","Key":"watchdog-ota/releases/v1.2.3+59/app.apk"}');
        });
      },
      async (origin) => {
        const result = await uploadObject({
          envId: 'watchdog-prod-123',
          bucketId: 'watchdog-ota',
          token: 'test-service-role-key',
          filePath: fixture.filePath,
          objectPath: 'releases/v1.2.3+59/app.apk',
          contentType: 'application/vnd.android.package-archive',
          cacheControl: 'public,max-age=31536000,immutable',
          attempts: 1,
          timeoutMs: 2000,
          origin,
          allowHttpForTests: true,
        });
        assert.equal(result.statusCode, 200);
      },
    );
  } finally {
    fixture.cleanup();
  }
});

test('仅重试可恢复错误，且错误信息不包含 API Key', async () => {
  const fixture = createFixture();
  let requests = 0;
  const retryBodies = [];
  try {
    await withServer(
      (request, response) => {
        const chunks = [];
        request.on('data', (chunk) => chunks.push(chunk));
        request.on('end', () => {
          requests += 1;
          retryBodies.push(Buffer.concat(chunks));
          response.writeHead(requests === 1 ? 502 : 200, { 'Content-Type': 'application/json' });
          response.end(
            requests === 1
              ? '{"message":"temporary"}'
              : '{"Id":"object-id","Key":"watchdog-ota/latest.json"}',
          );
        });
      },
      (origin) =>
        uploadObject({
          envId: 'watchdog-prod-123',
          bucketId: 'watchdog-ota',
          token: 'never-print-this-key',
          filePath: fixture.filePath,
          objectPath: 'latest.json',
          contentType: 'application/json; charset=utf-8',
          cacheControl: 'no-cache,max-age=0,must-revalidate',
          attempts: 2,
          retryDelayMs: 0,
          timeoutMs: 2000,
          origin,
          allowHttpForTests: true,
        }),
    );
    assert.equal(requests, 2);
    assert.deepEqual(retryBodies, [fixture.content, fixture.content]);

    let badRequests = 0;
    await assert.rejects(
      withServer(
        (request, response) => {
          request.resume();
          request.on('end', () => {
            badRequests += 1;
            response.writeHead(400, { 'Content-Type': 'application/json' });
            response.end('{"message":"bad request never-print-this-key"}');
          });
        },
        (origin) =>
          uploadObject({
            envId: 'watchdog-prod-123',
            bucketId: 'watchdog-ota',
            token: 'never-print-this-key',
            filePath: fixture.filePath,
            objectPath: 'latest.json',
            contentType: 'application/json; charset=utf-8',
            cacheControl: 'no-cache,max-age=0,must-revalidate',
            attempts: 3,
            retryDelayMs: 0,
            timeoutMs: 2000,
            origin,
            allowHttpForTests: true,
          }),
      ),
      (error) => {
        assert.match(error.message, /HTTP 400/);
        assert.doesNotMatch(error.message, /never-print-this-key/);
        return true;
      },
    );
    assert.equal(badRequests, 1);
  } finally {
    fixture.cleanup();
  }
});

test('2xx 响应缺少匹配的 Id/Key 时仍然失败', async () => {
  const fixture = createFixture();
  try {
    await assert.rejects(
      withServer(
        (request, response) => {
          request.resume();
          request.on('end', () => {
            response.writeHead(200, { 'Content-Type': 'application/json' });
            response.end('{"Id":"object-id","Key":"watchdog-ota/wrong.json"}');
          });
        },
        (origin) =>
          uploadObject({
            envId: 'watchdog-prod-123',
            bucketId: 'watchdog-ota',
            token: 'test-service-role-key',
            filePath: fixture.filePath,
            objectPath: 'latest.json',
            contentType: 'application/json; charset=utf-8',
            cacheControl: 'no-cache,max-age=0,must-revalidate',
            attempts: 3,
            retryDelayMs: 0,
            timeoutMs: 2000,
            origin,
            allowHttpForTests: true,
          }),
      ),
      /缺少匹配的 Id\/Key/,
    );
  } finally {
    fixture.cleanup();
  }
});

test('拒绝超过 CloudBase 单对象上限的文件', async () => {
  const fixture = createFixture();
  try {
    fs.truncateSync(fixture.filePath, maxCloudBaseObjectBytes + 1);
    await assert.rejects(
      uploadObject({
        envId: 'watchdog-prod-123',
        bucketId: 'watchdog-ota',
        token: 'test-service-role-key',
        filePath: fixture.filePath,
        objectPath: 'releases/oversize.apk',
        contentType: 'application/vnd.android.package-archive',
        cacheControl: 'public,max-age=31536000,immutable',
        attempts: 1,
        timeoutMs: 2000,
      }),
      /100 MB/,
    );
  } finally {
    fixture.cleanup();
  }
});
