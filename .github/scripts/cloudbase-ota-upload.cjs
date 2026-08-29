'use strict';

const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const path = require('node:path');

const retryableStatuses = new Set([408, 425, 429, 500, 502, 503, 504]);
const maxResponseBytes = 64 * 1024;
const maxCloudBaseObjectBytes = 100_000_000;

function assertMatches(value, pattern, label) {
  if (typeof value !== 'string' || !pattern.test(value)) {
    throw new Error(`${label} 格式无效`);
  }
}

function encodeObjectPath(objectPath) {
  if (typeof objectPath !== 'string' || objectPath.length === 0) {
    throw new Error('对象路径不能为空');
  }
  if (objectPath.startsWith('/') || objectPath.endsWith('/') || objectPath.includes('//')) {
    throw new Error('对象路径格式无效');
  }
  const segments = objectPath.split('/');
  if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) {
    throw new Error('对象路径包含非法目录段');
  }
  return segments.map(encodeURIComponent).join('/');
}

function buildCloudBaseObjectUrl({ envId, bucketId, objectPath, origin }) {
  assertMatches(envId, /^[A-Za-z0-9][A-Za-z0-9-]{0,62}$/, 'CloudBase 环境 ID');
  assertMatches(bucketId, /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/, 'CloudBase Bucket ID');
  const apiOrigin = origin ?? `https://${envId}.api.tcloudbasegateway.com`;
  const url = new URL(apiOrigin);
  if (url.pathname !== '/' || url.search || url.hash || url.username || url.password) {
    throw new Error('CloudBase API Origin 格式无效');
  }
  url.pathname = `/v1/storages/object/${encodeURIComponent(bucketId)}/${encodeObjectPath(objectPath)}`;
  return url;
}

function responseSummary(body, truncated) {
  const normalized = body.replace(/\s+/g, ' ').trim();
  if (!normalized) return '';
  return `：${normalized}${truncated ? '…' : ''}`;
}

function requestOnce({
  url,
  token,
  filePath,
  contentType,
  cacheControl,
  sizeBytes,
  timeoutMs,
  allowHttpForTests,
}) {
  return new Promise((resolve, reject) => {
    if (url.protocol !== 'https:' && !(allowHttpForTests && url.protocol === 'http:')) {
      reject(new Error('CloudBase 对象上传仅允许 HTTPS'));
      return;
    }

    const transport = url.protocol === 'https:' ? https : http;
    let input;
    let wallTimer;
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(wallTimer);
      callback(value);
    };
    const request = transport.request(
      url,
      {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${token}`,
          'Cache-Control': cacheControl,
          'Content-Length': String(sizeBytes),
          'Content-Type': contentType,
          'User-Agent': 'watchdog-release-ota/1.0',
          'x-upsert': 'true',
        },
      },
      (response) => {
        const chunks = [];
        let capturedBytes = 0;
        let truncated = false;
        response.on('data', (chunk) => {
          if (capturedBytes >= maxResponseBytes) {
            truncated = true;
            return;
          }
          const remaining = maxResponseBytes - capturedBytes;
          chunks.push(chunk.subarray(0, remaining));
          capturedBytes += Math.min(chunk.length, remaining);
          if (chunk.length > remaining) truncated = true;
        });
        response.on('end', () => {
          input?.destroy();
          const body = Buffer.concat(chunks).toString('utf8');
          finish(resolve, {
            statusCode: response.statusCode ?? 0,
            body,
            requestId:
              response.headers['x-request-id'] ??
              response.headers['x-requestid'] ??
              response.headers['x-tcb-request-id'] ??
              '',
            summary: responseSummary(body, truncated),
          });
        });
        response.on('error', (error) => finish(reject, error));
      },
    );

    request.setTimeout(timeoutMs, () => {
      request.destroy(new Error(`CloudBase 对象上传连接空闲超时（${timeoutMs}ms）`));
    });
    wallTimer = setTimeout(() => {
      request.destroy(new Error(`CloudBase 对象上传总时限超时（${timeoutMs}ms）`));
    }, timeoutMs);
    request.on('error', (error) => {
      input?.destroy();
      finish(reject, error);
    });

    input = fs.createReadStream(filePath);
    input.on('error', (error) => request.destroy(error));
    input.pipe(request);
  });
}

async function uploadObject({
  envId,
  bucketId,
  token,
  filePath,
  objectPath,
  contentType,
  cacheControl,
  attempts = 3,
  timeoutMs = 5 * 60 * 1000,
  retryDelayMs = 2000,
  origin,
  allowHttpForTests = false,
}) {
  if (typeof token !== 'string' || token.length === 0 || /[\r\n]/.test(token)) {
    throw new Error('CloudBase API Key 不能为空或包含换行');
  }
  if (typeof contentType !== 'string' || contentType.length === 0 || /[\r\n]/.test(contentType)) {
    throw new Error('Content-Type 不能为空或包含换行');
  }
  if (typeof cacheControl !== 'string' || cacheControl.length === 0 || /[\r\n]/.test(cacheControl)) {
    throw new Error('Cache-Control 不能为空或包含换行');
  }
  if (!Number.isSafeInteger(attempts) || attempts < 1 || attempts > 5) throw new Error('上传重试次数无效');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) throw new Error('上传超时时间无效');

  const resolvedFile = path.resolve(filePath);
  const stat = fs.statSync(resolvedFile);
  if (!stat.isFile() || stat.size < 1) throw new Error('待上传文件不存在或为空');
  if (stat.size > maxCloudBaseObjectBytes) {
    throw new Error(`待上传文件超过 CloudBase 100 MB 单对象上限（${stat.size} bytes）`);
  }
  const url = buildCloudBaseObjectUrl({ envId, bucketId, objectPath, origin });
  const expectedKey = `${bucketId}/${objectPath}`;

  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const startedAt = Date.now();
    try {
      const result = await requestOnce({
        url,
        token,
        filePath: resolvedFile,
        contentType,
        cacheControl,
        sizeBytes: stat.size,
        timeoutMs,
        allowHttpForTests,
      });
      if (result.statusCode >= 200 && result.statusCode < 300) {
        let payload;
        try {
          payload = JSON.parse(result.body);
        } catch {
          payload = null;
        }
        if (
          !payload ||
          typeof payload.Id !== 'string' ||
          payload.Id.length === 0 ||
          payload.Key !== expectedKey
        ) {
          const error = new Error('CloudBase 对象上传响应缺少匹配的 Id/Key');
          error.statusCode = result.statusCode;
          throw error;
        }
        return { ...result, attempt, elapsedMs: Date.now() - startedAt };
      }

      const safeSummary = result.summary.replaceAll(token, 'REDACTED');
      const error = new Error(`CloudBase 对象上传失败（HTTP ${result.statusCode}）${safeSummary}`);
      error.statusCode = result.statusCode;
      throw error;
    } catch (error) {
      lastError = error;
      const retryable = error.statusCode == null || retryableStatuses.has(error.statusCode);
      if (!retryable || attempt === attempts) break;
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs * attempt));
    }
  }
  throw lastError;
}

function parseArguments(argv) {
  const allowed = new Set(['--file', '--object', '--content-type', '--cache-control']);
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(key) || value == null || values[key] != null) {
      throw new Error('参数无效；需要 --file、--object、--content-type、--cache-control');
    }
    values[key] = value;
  }
  for (const key of allowed) {
    if (!values[key]) throw new Error(`缺少参数 ${key}`);
  }
  return values;
}

async function main() {
  const args = parseArguments(process.argv.slice(2));
  const result = await uploadObject({
    envId: process.env.CLOUDBASE_OTA_ENV_ID,
    bucketId: process.env.CLOUDBASE_OTA_BUCKET_ID,
    token: process.env.CLOUDBASE_OTA_API_KEY,
    filePath: args['--file'],
    objectPath: args['--object'],
    contentType: args['--content-type'],
    cacheControl: args['--cache-control'],
  });
  const requestId = result.requestId ? `，requestId=${result.requestId}` : '';
  console.log(
    `CloudBase 对象上传成功：${args['--object']}（第 ${result.attempt} 次，${result.elapsedMs}ms${requestId}）`,
  );
}

module.exports = {
  buildCloudBaseObjectUrl,
  encodeObjectPath,
  maxCloudBaseObjectBytes,
  parseArguments,
  uploadObject,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(`::error::${error.message}`);
    process.exitCode = 1;
  });
}
