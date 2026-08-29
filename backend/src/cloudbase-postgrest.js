const DEFAULT_TIMEOUT_MS = 10000;
const { parseAllowedHosts, isHostAllowed } = require('./network-policy');

class CloudBasePostgrestError extends Error {
  constructor(message, { status = 500, details = null, body = null } = {}) {
    super(message);
    this.name = 'CloudBasePostgrestError';
    this.status = status;
    this.details = details;
    this.body = body;
  }
}

function requiredEnv(name, value) {
  if (!value) throw new Error(`未配置 ${name}`);
  return value;
}

function assertHttpsUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch (_) {
    throw new Error('CLOUDBASE_REST_BASE_URL 无效');
  }
  if (url.protocol !== 'https:') {
    throw new Error('CLOUDBASE_REST_BASE_URL 必须使用 HTTPS');
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error('CLOUDBASE_REST_BASE_URL 不得包含用户信息、查询参数或片段');
  }
}

function assertProductionHost({ url, envId, hasExplicitBaseUrl, allowedHostsValue }) {
  const parsedUrl = url instanceof URL ? url : new URL(url);
  const configuredHosts = parseAllowedHosts(allowedHostsValue);
  if (configuredHosts.length > 0) {
    if (!isHostAllowed(parsedUrl, configuredHosts)) {
      throw new Error('生产环境 CLOUDBASE_REST_BASE_URL 主机不在 CLOUDBASE_REST_ALLOWED_HOSTS 允许列表');
    }
    return;
  }
  if (hasExplicitBaseUrl) {
    throw new Error('生产环境使用自定义 CLOUDBASE_REST_BASE_URL 时必须配置 CLOUDBASE_REST_ALLOWED_HOSTS');
  }
  const expectedHost = `${envId}.api.tcloudbasegateway.com`;
  if (!isHostAllowed(parsedUrl, [expectedHost])) {
    throw new Error('生产环境 CloudBase REST 主机与 CLOUDBASE_ENV_ID 不匹配');
  }
}

function encodeFilter(op, value) {
  if (op === 'is') return `is.${value}`;
  if (op === 'in') return `in.(${value.map((item) => String(item).replace(/[(),]/g, '')).join(',')})`;
  return `${op}.${String(value)}`;
}

function normalizeFilter(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return encodeFilter(value.op || 'eq', value.value);
  }
  return encodeFilter('eq', value);
}

function parseResponseBody(text) {
  if (!text) return null;
  try { return JSON.parse(text); } catch { return text; }
}

function errorMessage(body, status) {
  if (typeof body === 'string') return body.slice(0, 500);
  if (body && typeof body === 'object') {
    return String(body.message || body.error_description || body.error || body.details || `HTTP ${status}`).slice(0, 500);
  }
  return `HTTP ${status}`;
}

class CloudBasePostgrestClient {
  constructor({
    envId = process.env.CLOUDBASE_ENV_ID || process.env.CLOUDBASE_ENV || '',
    apiKey = process.env.CLOUDBASE_API_KEY || process.env.CLOUDBASE_APIKEY || process.env.CLOUDBASE_SERVICE_ROLE_KEY || '',
    baseUrl,
    timeoutMs = Number(process.env.CLOUDBASE_REST_TIMEOUT_MS || DEFAULT_TIMEOUT_MS),
    fetchImpl = global.fetch,
  } = {}) {
    this.envId = envId;
    this.apiKey = apiKey;
    const configuredBaseUrl = String(baseUrl ?? process.env.CLOUDBASE_REST_BASE_URL ?? '').trim();
    this.hasExplicitBaseUrl = configuredBaseUrl.length > 0;
    this.baseUrl = String(configuredBaseUrl || (envId ? `https://${envId}.api.tcloudbasegateway.com/v1/rdb/rest` : '')).replace(/\/$/, '');
    this.timeoutMs = Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS;
    this.fetchImpl = fetchImpl;
  }

  assertConfigured() {
    requiredEnv('CLOUDBASE_ENV_ID 或 CLOUDBASE_REST_BASE_URL', this.baseUrl);
    requiredEnv('CLOUDBASE_API_KEY', this.apiKey);
    assertHttpsUrl(this.baseUrl);
    if (process.env.NODE_ENV === 'production') {
      assertProductionHost({
        url: this.baseUrl,
        envId: this.envId,
        hasExplicitBaseUrl: this.hasExplicitBaseUrl,
        allowedHostsValue: process.env.CLOUDBASE_REST_ALLOWED_HOSTS,
      });
    }
    if (typeof this.fetchImpl !== 'function') throw new Error('当前 Node.js 运行时缺少 fetch');
  }

  async request(path, {
    method = 'GET',
    query = {},
    body,
    prefer = null,
    retry = method === 'GET',
  } = {}) {
    this.assertConfigured();
    const url = new URL(`${this.baseUrl}/${String(path).replace(/^\//, '')}`);
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
    }
    const headers = {
      Accept: 'application/json',
      Authorization: `Bearer ${this.apiKey}`,
    };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (prefer) headers.Prefer = prefer;

    const maxAttempts = retry ? Math.max(0, Number(process.env.CLOUDBASE_REST_MAX_RETRIES || 2)) : 0;
    for (let attempt = 0; ; attempt++) {
      let response;
      try {
        response = await this.fetchImpl(url, {
          method,
          redirect: 'error',
          headers,
          body: body === undefined ? undefined : JSON.stringify(body),
          signal: AbortSignal.timeout(this.timeoutMs),
        });
      } catch (error) {
        if (attempt >= maxAttempts) throw error;
        await this.delay(attempt);
        continue;
      }

      const parsed = parseResponseBody(await response.text());
      if (response.ok) {
        return {
          data: parsed,
          count: this.parseCount(response.headers),
          status: response.status,
        };
      }

      const retryableStatus = response.status === 408 || response.status === 429 || response.status >= 500;
      if (retryableStatus && attempt < maxAttempts) {
        await this.delay(attempt, response.headers.get('retry-after'));
        continue;
      }
      const message = errorMessage(parsed, response.status);
      const unique = /duplicate key|already exists|unique constraint|violates unique/i.test(message);
      throw new CloudBasePostgrestError(unique ? `UNIQUE constraint violation: ${message}` : message, {
        status: response.status,
        details: parsed?.details,
        body: parsed,
      });
    }
  }

  async delay(attempt, retryAfter = null) {
    const retrySeconds = Number(retryAfter);
    const ms = Number.isFinite(retrySeconds) && retrySeconds > 0
      ? Math.min(retrySeconds * 1000, 5000)
      : Math.min(250 * 2 ** attempt, 2000);
    await new Promise((resolve) => setTimeout(resolve, ms));
  }

  parseCount(headers) {
    const range = headers.get('content-range');
    if (!range) return null;
    const total = range.split('/')[1];
    const count = Number(total);
    return Number.isFinite(count) ? count : null;
  }

  filters(filters = {}) {
    return Object.fromEntries(Object.entries(filters).map(([column, value]) => [column, normalizeFilter(value)]));
  }

  async select(table, {
    select = '*',
    filters = {},
    order = null,
    limit = null,
    offset = null,
    single = false,
    rawQuery = {},
  } = {}) {
    const query = { select, ...this.filters(filters), ...rawQuery };
    if (order) query.order = order;
    if (limit != null) query.limit = limit;
    if (offset != null) query.offset = offset;
    const result = await this.request(table, {
      query,
      prefer: single ? 'count=exact' : null,
    });
    const rows = Array.isArray(result.data) ? result.data : [];
    return single ? rows[0] : rows;
  }

  async insert(table, row, { select = '*', onConflict = null, ignoreDuplicates = false } = {}) {
    const query = { select };
    if (onConflict) query.on_conflict = onConflict;
    const prefer = [
      'return=representation',
      onConflict ? `resolution=${ignoreDuplicates ? 'ignore' : 'merge'}-duplicates` : null,
    ].filter(Boolean).join(',');
    const result = await this.request(table, { method: 'POST', query, body: row, prefer, retry: false });
    return Array.isArray(result.data) ? result.data : [];
  }

  async update(table, filters, values, { select = '*', allowEmpty = false } = {}) {
    const result = await this.request(table, {
      method: 'PATCH',
      query: { select, ...this.filters(filters) },
      body: values,
      prefer: 'return=representation',
      retry: false,
    });
    const rows = Array.isArray(result.data) ? result.data : [];
    if (!allowEmpty && rows.length === 0) return { rows, changes: 0 };
    return { rows, changes: rows.length };
  }

  async remove(table, filters) {
    const result = await this.request(table, {
      method: 'DELETE',
      query: { ...this.filters(filters) },
      prefer: 'return=representation',
      retry: false,
    });
    const rows = Array.isArray(result.data) ? result.data : [];
    return { rows, changes: rows.length };
  }

  async upsert(table, row, { onConflict, select = '*', ignoreDuplicates = false } = {}) {
    return this.insert(table, row, { onConflict, select, ignoreDuplicates });
  }

  async rpc(functionName, args = {}, { get = false } = {}) {
    const result = await this.request(`rpc/${functionName}`, {
      method: 'POST',
      body: args,
      prefer: 'return=representation',
      retry: false,
    });
    if (get) return Array.isArray(result.data) ? result.data[0] : result.data;
    return Array.isArray(result.data) ? result.data : [];
  }
}

module.exports = { CloudBasePostgrestClient, CloudBasePostgrestError, normalizeFilter, assertProductionHost };
