export const ERROR_MESSAGES = {
  ADMIN_SESSION_INVALID: '后台会话已失效，请重新扫码登录',
  ADMIN_CSRF_INVALID: '安全校验已过期，请刷新页面后重试',
  ADMIN_ORIGIN_INVALID: '当前访问域名未获后台授权，请核对访问地址',
  ADMIN_FORBIDDEN: '当前账号无权执行此操作',
  ADMIN_CHALLENGE_INVALID: '二维码已过期或被取消，请重新生成',
  ADMIN_RATE_LIMITED: '操作过于频繁，请稍后再试',
  ADMIN_ROLE_INVALID: '管理员角色参数无效',
  ADMIN_MEMBER_INVALID: '该成员状态不符合授权要求',
  ADMIN_LAST_PLATFORM: '至少需保留一位平台管理员',
  KEY_SITE_CONFLICT: '草稿已被其他会话更新，请刷新后重试',
  KEY_SITE_BUSY: '服务器正在处理其他文件，请稍后重试',
  KEY_SITE_UPLOAD_LIMIT: '文件超过上传大小或数量限制',
  KEY_SITE_SOURCE_INVALID: '关联的附件或页码无效，请重新核对',
  KEY_SITE_QUOTA_EXCEEDED: '单位附件存储配额已满',
  KEY_SITE_PROCESS_TIMEOUT: '附件处理超时，可尝试重新处理',
  KEY_SITE_ENCRYPTED: '文档已加密，请解密后再上传',
  KEY_SITE_CONVERT_FAILED: '文档或图片转换失败，请检查文件格式',
  HAZMAT_FILE_TOO_LARGE: '上传文件超过 10MB 限制',
  HAZMAT_IMPORT_TOO_MANY_ROWS: '单次导入行数超过上限',
  SESSION_REQUIRED: '会话已失效，请重新登录',
  UNIT_FORBIDDEN: '无权访问或修改其他单位的水源数据',
  WATER_SOURCE_NOT_FOUND: '未找到对应的水源记录',
  INVALID_CATEGORY: '水源类别参数无效',
  INVALID_STATUS: '水源可用状态参数无效',
  INVALID_INTAKE_METHODS: '天然水源至少需选择一种取水方式，非天然水源不可设置取水方式',
  INVALID_COORDINATES: '经纬度坐标超出有效范围（纬度 3~55，经度 73~136）',
  INVALID_NAME: '水源名称不能为空且不能超过 120 个字符',
  INVALID_NOTE: '备注长度不能超过 500 个字符',
  RESTORE_WINDOW_EXPIRED: '已超过撤销时限，请联系管理员在回收站恢复',
  WATER_SOURCE_LIMIT_REACHED: '当前单位活跃水源数量已达 5000 条上限',
};

export function mapErrorMessage(code, fallback = '请求处理失败') {
  if (code && ERROR_MESSAGES[code]) return ERROR_MESSAGES[code];
  return fallback || '请求处理失败';
}

export class ApiError extends Error {
  constructor(message, { status = 0, code = '', data = null } = {}) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.data = data;
  }
}

let csrfToken = '';
let authGeneration = 0;
let unauthorizedHandler = null;

export function setApiCsrf(token) {
  csrfToken = String(token || '');
}

export function getApiCsrf() {
  return csrfToken;
}

export function bumpAuthGeneration() {
  authGeneration += 1;
  return authGeneration;
}

export function getAuthGeneration() {
  return authGeneration;
}

export function onApiUnauthorized(handler) {
  unauthorizedHandler = handler;
}

async function parseResponsePayload(response) {
  const text = await response.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    return { _rawText: text };
  }
}

export async function apiRequest(path, {
  method = 'GET',
  body = undefined,
  poll = false,
  signal = undefined,
  suppressUnauthorized = false,
} = {}) {
  const epoch = authGeneration;
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (method !== 'GET' && method !== 'HEAD' && csrfToken) headers['X-CSRF-Token'] = csrfToken;
  if (poll) headers['X-Admin-Poll'] = '1';

  let response;
  try {
    response = await fetch(`/api/admin${path}`, {
      method,
      credentials: 'same-origin',
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal,
    });
  } catch (err) {
    if (err?.name === 'AbortError') throw err;
    throw new ApiError('网络连接异常，请检查网络后重试', { status: 0, code: 'NETWORK_ERROR' });
  }

  const data = await parseResponsePayload(response);
  if (epoch !== authGeneration && !path.startsWith('/login/')) {
    throw new ApiError('会话状态已切换', { status: 0, code: 'SESSION_EPOCH_CHANGED' });
  }

  if (response.status === 401 && !suppressUnauthorized && !path.startsWith('/login/')) {
    unauthorizedHandler?.(mapErrorMessage(data.code, '后台会话已失效，请重新扫码登录'));
    throw new ApiError(mapErrorMessage(data.code, '后台会话已失效，请重新扫码登录'), {
      status: 401,
      code: data.code || 'ADMIN_SESSION_INVALID',
      data,
    });
  }

  if (!response.ok) {
    const rawMsg = typeof data.error === 'string' && data.error !== data.code ? data.error : '';
    const message = rawMsg || mapErrorMessage(data.code, `请求失败（HTTP ${response.status}）`);
    throw new ApiError(message, { status: response.status, code: data.code || '', data });
  }

  return { status: response.status, data };
}

export async function apiUpload(path, formData, { signal = undefined } = {}) {
  const epoch = authGeneration;
  const headers = {};
  if (csrfToken) headers['X-CSRF-Token'] = csrfToken;

  let response;
  try {
    response = await fetch(`/api/admin${path}`, {
      method: 'POST',
      credentials: 'same-origin',
      headers,
      body: formData,
      signal,
    });
  } catch (err) {
    if (err?.name === 'AbortError') throw err;
    throw new ApiError('文件上传连接中断，请重试', { status: 0, code: 'NETWORK_ERROR' });
  }

  const data = await parseResponsePayload(response);
  if (epoch !== authGeneration) {
    throw new ApiError('会话状态已切换', { status: 0, code: 'SESSION_EPOCH_CHANGED' });
  }

  if (response.status === 401) {
    unauthorizedHandler?.(mapErrorMessage(data.code, '后台会话已失效，请重新扫码登录'));
    throw new ApiError(mapErrorMessage(data.code, '后台会话已失效，请重新扫码登录'), {
      status: 401,
      code: data.code || 'ADMIN_SESSION_INVALID',
      data,
    });
  }

  if (!response.ok) {
    const rawMsg = typeof data.error === 'string' && data.error !== data.code ? data.error : '';
    const fallback = response.status === 413 ? '上传文件超过服务器大小限制' : `上传失败（HTTP ${response.status}）`;
    const message = rawMsg || mapErrorMessage(data.code, fallback);
    throw new ApiError(message, { status: response.status, code: data.code || '', data });
  }

  return data;
}

export async function apiDownload(path, fallbackFilename = 'download') {
  const epoch = authGeneration;
  let response;
  try {
    response = await fetch(`/api/admin${path}`, {
      method: 'GET',
      credentials: 'same-origin',
    });
  } catch {
    throw new ApiError('下载连接异常，请稍后重试', { status: 0, code: 'NETWORK_ERROR' });
  }

  if (epoch !== authGeneration) {
    throw new ApiError('会话状态已切换', { status: 0, code: 'SESSION_EPOCH_CHANGED' });
  }

  if (response.status === 401) {
    const data = await parseResponsePayload(response);
    unauthorizedHandler?.(mapErrorMessage(data.code, '后台会话已失效，请重新扫码登录'));
    throw new ApiError(mapErrorMessage(data.code, '后台会话已失效，请重新扫码登录'), {
      status: 401,
      code: data.code || 'ADMIN_SESSION_INVALID',
    });
  }

  if (!response.ok) {
    const data = await parseResponsePayload(response);
    const rawMsg = typeof data.error === 'string' && data.error !== data.code ? data.error : '';
    throw new ApiError(rawMsg || mapErrorMessage(data.code, `下载失败（HTTP ${response.status}）`), {
      status: response.status,
      code: data.code || '',
    });
  }

  const blob = await response.blob();
  const disposition = response.headers.get('content-disposition') || '';
  const match = disposition.match(/filename\*?=(?:UTF-8''|")?([^";\n]+)/i);
  const filename = match ? decodeURIComponent(match[1].replace(/"/g, '').trim()) : fallbackFilename;

  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
